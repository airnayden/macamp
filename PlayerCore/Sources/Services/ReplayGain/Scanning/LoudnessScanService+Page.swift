//
//  LoudnessScanService+Page.swift
//  MacAMP PlayerCore — Services
//
//  The bounded-parallel page pipeline, split out of `LoudnessScanService.swift`
//  for the reason ``AudioAnalysisService`` splits its own `+Page` off: the run
//  loop is one concern and the bounded fan-out over its rows is another, and
//  together they exceed the file budget.
//
//  THE ISOLATION CONTRACT, which is the whole point of this file's shape:
//  ``LoudnessScanService`` is `@MainActor`, so `withTaskGroup`'s body inherits
//  that isolation and the accumulation loop may touch service state freely. The
//  CHILD tasks do not — they are non-isolated `@Sendable` closures that capture
//  nothing but the scanner, a URL and an index, and hand back a value. Every
//  mutation (`progress`, `failedCount`, `currentTrack`, the commit, the
//  notification) is therefore applied in one place, on one actor.
//
//  FAILURE SEMANTICS, which the album pass depends on: a failed scan writes NO
//  row. That absence is what keeps the failed track's album group incomplete and
//  therefore unpooled — the fail-closed denominator. Tallying the failure and
//  moving on is the whole of the handling; nothing is written to stand in for it.
//
//  PlayerCore portability: Foundation + GRDB through Persistence.
//

import Foundation
import Persistence

// MARK: - Bounded fan-out

extension LoudnessScanService {
    /// Scans one page with up to ``LoudnessScanService/concurrencyCap`` decodes
    /// in flight, then pools every album group the page touched.
    ///
    /// The shape is ``AudioAnalysisService/processPage(_:)``: pre-spawn up to the
    /// cap, then add exactly one replacement per completion.
    func processPage(_ page: [TrackRecord]) async {
        let candidates = page.compactMap(Candidate.init)
        // Unreachable through the repository's stale page (it selects present
        // rows only, and a fetched record always carries its rowid) — but a
        // defensive skip must still be counted or `progress.completed` could
        // never reach `total`.
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
        await poolAlbums(touchedBy: candidates)
        flushNotification()
    }

    /// Builds and drops ONE decoder, serially, before the page fans out.
    ///
    /// Several codec backends do process-global first-time initialisation the
    /// first time a decoder of their family is built, and mpg123's is not
    /// thread-safe: `concurrencyCap` decodes reaching it together fault with
    /// SIGBUS. Doing it once here, awaited, means the fan-out only ever meets an
    /// already-initialised library. ``DecoderOpenGate`` is defence in depth.
    ///
    /// FAILURE SEMANTICS. The error is caught and dropped — an unreadable file is
    /// the scan's problem to tally, not the warm-up's — and ``didWarmUpDecoder``
    /// is set ONLY after a successful MPEG-family open, so a corrupt first MP3
    /// leaves a later page free to try again.
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

    /// Waits out a pause, then reports whether a new scan may start.
    ///
    /// The gate is per-SPAWN, never mid-flight: a pause lets the scans already
    /// running finish and only holds back the ones not started yet.
    func readyToSpawn() async -> Bool {
        await waitWhilePaused()
        return !Task.isCancelled
    }
}

// MARK: - Per-track scan

extension LoudnessScanService {
    /// One page row reduced to what the scan and the commit need, so a child task
    /// captures `Sendable` values and never the record itself.
    struct Candidate {
        let track: TrackRecord
        let trackId: Int64
        let albumId: Int64?
        let url: URL
        let displayName: String

        /// `nil` for a row that cannot be scanned at all.
        init?(_ track: TrackRecord) {
            guard track.availability == .present, let trackId = track.id else { return nil }
            self.track = track
            self.trackId = trackId
            albumId = track.albumId
            url = URL(fileURLWithPath: track.filePath)
            displayName = track.title ?? url.lastPathComponent
        }
    }

    /// Path extensions decoded by mpg123, whose first-time initialisation is the
    /// one that faults. Opening a FLAC or an M4A warms a different backend
    /// entirely, which is why the selection below cannot simply take the first
    /// candidate.
    private static let mpegPathExtensions: Set<String> = ["mp3", "mp2", "mp1"]

    /// The candidate to warm up on, and whether opening it would initialise
    /// mpg123 — which is what decides whether the one-shot is spent.
    private static func warmUpTarget(in candidates: [Candidate]) -> (url: URL, initialisesMPEG: Bool)? {
        if let mpeg = candidates.first(where: { mpegPathExtensions.contains($0.url.pathExtension.lowercased()) }) {
            return (mpeg.url, true)
        }
        return candidates.first.map { ($0.url, false) }
    }

    /// What one child scan produced. The error is deliberately dropped: the only
    /// distinction the accumulation loop draws is committed versus tallied.
    enum ScanOutcome {
        case measured(LoudnessScanResult)
        case failed
    }

    /// A finished scan, tagged with its index into the page's candidates.
    typealias PageOutcome = (Int, ScanOutcome)

    /// Starts `candidate` and names it as the track being scanned.
    ///
    /// Under parallelism ``LoudnessScanService/currentTrack`` is DEFINED as the
    /// most recently STARTED track, so the UI names one of the scans in flight
    /// rather than all of them. It is set here, on this actor — the child never
    /// touches it.
    private func spawn(_ candidate: Candidate, at index: Int, into group: inout TaskGroup<PageOutcome>) {
        currentTrack = candidate.displayName
        notifyCoalesced()
        let scanner = scanner
        let url = candidate.url
        group.addTask {
            do {
                let result = try await scanner.measureLoudness(of: url)
                return (index, .measured(result))
            } catch {
                return (index, .failed)
            }
        }
    }

    /// Books one finished scan: the commit, the failure tally, the tick.
    private func apply(_ outcome: PageOutcome, to candidates: [Candidate]) async {
        switch outcome.1 {
        case let .measured(result):
            let candidate = candidates[outcome.0]
            await commit(result, for: candidate.track, trackId: candidate.trackId)
        case .failed:
            // One unreadable file must never abort a library-wide pass, so the
            // failure is counted and the walk continues. A CANCELLED pass is not
            // a failed track, though: `stop()` propagates into every in-flight
            // scan, and counting those would make the tally lie every time the
            // user stops.
            if !Task.isCancelled { failedCount += 1 }
        }
        progress.completed += 1
        notifyCoalesced()
    }
}

// MARK: - Coalesced change notification

extension LoudnessScanService {
    /// Shortest spacing between progress notifications while a page runs.
    private static let notifyInterval = Duration.milliseconds(100)

    /// Forwards ``LoudnessScanService/onChange`` at most once per
    /// ``notifyInterval``.
    ///
    /// Under ``LoudnessScanService/concurrencyCap`` parallel scans completions
    /// arrive in bursts, and an observing view cannot show more than one of them
    /// per frame anyway. A withheld notification is never lost:
    /// ``flushNotification()`` emits it when the page ends, and every transition
    /// the listener acts on still notifies unconditionally.
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
