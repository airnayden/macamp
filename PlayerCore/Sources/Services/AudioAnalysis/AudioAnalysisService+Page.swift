// AudioAnalysisService+Page — the bounded-parallel page pipeline.
//
// Split out of `AudioAnalysisService.swift` for the same reason
// ``LibraryScanner`` splits `+Chunk` off: the run loop is one concern and the
// bounded fan-out over its rows is another, and together they exceed the file
// budget.
//
// THE ISOLATION CONTRACT, which is the whole point of this file's shape:
// ``AudioAnalysisService`` is `@MainActor`, so `withTaskGroup`'s body inherits
// that isolation and the accumulation loop may touch service state freely. The
// CHILD tasks do not — they are non-isolated `@Sendable` closures that capture
// nothing but the extractor, a URL and an index, and hand back a value. Every
// mutation (`progress`, `failedCount`, `currentTrack`, the commit, the
// notification) is therefore applied in one place, on one actor. Swift 6 makes
// the alternative a compile error; scattering per-child `await MainActor.run`
// hops to work around it would trade that guarantee for interleaving bugs.
//
// PlayerCore portability: Foundation + GRDB through Persistence.
import Foundation
import Persistence

// MARK: - Bounded fan-out

extension AudioAnalysisService {
    /// Analyses one page with up to ``concurrencyCap`` extractions in flight.
    ///
    /// The shape is the scanner's ``LibraryScanner/readMetadata(for:)``: pre-spawn
    /// up to the cap, then add exactly one replacement per completion.
    func processPage(_ page: [TrackRecord]) async {
        let candidates = page.compactMap(Candidate.init)
        // Unreachable through ``stalePageSQL`` — it selects present rows only, and
        // a fetched record always carries its rowid — but a defensive skip must
        // still be counted or `progress.completed` could never reach `total`.
        progress.completed += page.count - candidates.count
        guard !candidates.isEmpty else { return }
        await warmUpDecoderIfNeeded(with: candidates)
        let cap = min(Self.concurrencyCap, candidates.count)

        await withTaskGroup(of: PageOutcome.self) { group in
            var next = 0
            while next < cap {
                guard await readyToSpawn() else { break }
                spawn(candidates[next], at: next, into: &group)
                next += 1
            }
            while let outcome = await group.next() {
                await apply(outcome, to: candidates)
                guard next < candidates.count, await readyToSpawn() else { continue }
                spawn(candidates[next], at: next, into: &group)
                next += 1
            }
        }
        flushNotification()
    }

    /// Builds and drops ONE decoder, serially, before the page fans out.
    ///
    /// Several codec backends do process-global first-time initialisation the
    /// first time a decoder of their family is built, and mpg123's is not
    /// thread-safe: `concurrencyCap` extractions reaching it together fault with
    /// SIGBUS. Doing it once here, awaited, means the fan-out only ever meets an
    /// already-initialised library. This is the PRIMARY mechanism —
    /// ``DecoderOpenGate`` is defence in depth, and cannot cover the playback
    /// engine, which opens on the main actor and must never suspend.
    ///
    /// The open runs on a detached utility task: this actor is the main one, and
    /// file I/O has no business on it.
    ///
    /// FAILURE SEMANTICS. The error is caught and dropped — an unreadable file
    /// is the extraction's problem to tally, not the warm-up's — and
    /// ``didWarmUpDecoder`` is set ONLY after a successful MPEG-family open, so
    /// a corrupt first MP3 leaves a later page free to try again. Setting the
    /// flag regardless would mark the warm-up done WITHOUT having initialised
    /// mpg123, silently disabling the fix for the rest of the run.
    private func warmUpDecoderIfNeeded(with candidates: [Candidate]) async {
        guard !didWarmUpDecoder, let target = Self.warmUpTarget(in: candidates) else { return }
        let open = warmUpOpen
        let url = target.url
        let opened = await Task.detached(priority: .utility) { () -> Bool in
            do {
                try await open(url)
                return true
            } catch {
                return false
            }
        }.value
        if opened, target.initialisesMPEG { didWarmUpDecoder = true }
    }

    /// Waits out a pause, then reports whether a new extraction may start.
    ///
    /// The gate is per-SPAWN, never mid-flight: a pause lets the extractions
    /// already running finish and only holds back the ones not started yet.
    func readyToSpawn() async -> Bool {
        await waitWhilePaused()
        return !Task.isCancelled
    }
}

// MARK: - Per-track analysis

private extension AudioAnalysisService {
    /// One page row reduced to what the extraction and the commit need, so a
    /// child task captures `Sendable` values and never the record itself.
    struct Candidate {
        let track: TrackRecord
        let trackId: Int64
        let url: URL
        let displayName: String

        /// `nil` for a row that cannot be analysed at all.
        init?(_ track: TrackRecord) {
            guard track.availability == .present, let trackId = track.id else { return nil }
            self.track = track
            self.trackId = trackId
            url = URL(fileURLWithPath: track.filePath)
            displayName = track.title ?? url.lastPathComponent
        }
    }

    /// Path extensions decoded by mpg123, whose first-time initialisation is the
    /// one that faults. Opening a FLAC or an M4A warms a different backend
    /// entirely, which is why the selection below cannot simply take the first
    /// candidate.
    static let mpegPathExtensions: Set<String> = ["mp3", "mp2", "mp1"]

    /// The candidate to warm up on, and whether opening it would initialise
    /// mpg123 — which is what decides whether the one-shot is spent.
    ///
    /// A page with no MPEG file still warms (`candidates.first`, which trips the
    /// format registry and whatever backend that file uses) but reports `false`,
    /// so the next page carrying an MP3 still gets its turn.
    static func warmUpTarget(in candidates: [Candidate]) -> (url: URL, initialisesMPEG: Bool)? {
        if let mpeg = candidates.first(where: { mpegPathExtensions.contains($0.url.pathExtension.lowercased()) }) {
            return (mpeg.url, true)
        }
        return candidates.first.map { ($0.url, false) }
    }

    /// What one child extraction produced. The error is deliberately dropped: the
    /// only distinction the accumulation loop draws is committed versus tallied.
    enum AnalysisOutcome {
        case analysed(AudioFeatureResult)
        case failed
    }

    /// A finished extraction, tagged with its index into the page's candidates.
    typealias PageOutcome = (Int, AnalysisOutcome)

    /// Starts `candidate` and names it as the track being analysed.
    ///
    /// Under parallelism ``currentTrack`` is DEFINED as the most recently STARTED
    /// track, so the UI names one of the extractions in flight rather than all of
    /// them. It is set here, on this actor — the child never touches it.
    func spawn(_ candidate: Candidate, at index: Int, into group: inout TaskGroup<PageOutcome>) {
        currentTrack = candidate.displayName
        notifyCoalesced()
        let extractor = extractor
        let url = candidate.url
        group.addTask {
            do {
                let features = try await extractor.extractFeatures(from: url)
                return (index, .analysed(features))
            } catch {
                return (index, .failed)
            }
        }
    }

    /// Books one finished extraction: the commit, the failure tally, the tick.
    func apply(_ outcome: PageOutcome, to candidates: [Candidate]) async {
        switch outcome.1 {
        case let .analysed(features):
            let candidate = candidates[outcome.0]
            await commit(features, for: candidate.track, trackId: candidate.trackId)
        case .failed:
            // One unreadable file must never abort a library-wide pass, so the
            // failure is counted and the walk continues. A CANCELLED pass is not
            // a failed track, though: `stop()` propagates into every in-flight
            // extraction, and counting those would make the tally lie every time
            // the user stops.
            if !Task.isCancelled { failedCount += 1 }
        }
        progress.completed += 1
        notifyCoalesced()
    }
}

// MARK: - Coalesced change notification

private extension AudioAnalysisService {
    /// Shortest spacing between progress notifications while a page runs.
    static let notifyInterval = Duration.milliseconds(100)

    /// Forwards ``onChange`` at most once per ``notifyInterval``.
    ///
    /// Under ``concurrencyCap`` parallel extractions completions arrive in bursts,
    /// and an observing view cannot show more than one of them per frame anyway.
    /// A withheld notification is never lost: ``flushNotification()`` emits it
    /// when the page ends, and every transition the listener acts on — `beginPass`,
    /// `pause`, `resume`, `finish` — still notifies unconditionally.
    func notifyCoalesced() {
        let instant = ContinuousClock.now
        if let lastNotifiedAt, instant - lastNotifiedAt < Self.notifyInterval {
            hasWithheldNotification = true
            return
        }
        lastNotifiedAt = instant
        hasWithheldNotification = false
        notify()
    }

    /// Emits the notification the coalescer withheld, if there is one.
    func flushNotification() {
        guard hasWithheldNotification else { return }
        lastNotifiedAt = ContinuousClock.now
        hasWithheldNotification = false
        notify()
    }
}
