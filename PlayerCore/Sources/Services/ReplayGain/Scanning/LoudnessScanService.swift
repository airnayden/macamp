//
//  LoudnessScanService.swift
//  MacAMP PlayerCore — Services
//
//  The opt-in, resumable library-wide loudness pass.
//
//  Control surface and run loop are ``AudioAnalysisService``'s, deliberately:
//  a plain `@MainActor` engine, an `onChange` callback, start/pause/resume/stop,
//  and an `id`-keyset cursor. There is NO marker table — the DATABASE is the
//  progress record. A track stops being a candidate the instant its
//  `trackLoudness` row lands, so an interrupted pass resumes simply by asking the
//  same question again, and a pass over an already-scanned library costs one
//  COUNT and one empty page.
//
//  PROFILE-INDEPENDENT by design. `trackLoudness` has no `profileId` column
//  because integrated loudness and true peak describe the FILE, not anyone's
//  relationship to it. This service therefore takes no profile, applies no
//  `LibraryVisibility` scoping, and every profile reads the same rows.
//
//  OPT-IN. Nothing here runs until an explicit ``start()``; merely constructing
//  the service reads nothing and schedules nothing.
//
//  PlayerCore portability: Foundation + GRDB through Persistence + Decoding.
//

import Decoding
import Foundation
import Persistence

/// Fills `trackLoudness` for every present track whose scan is missing or stale,
/// one bounded `id`-keyset page at a time, and pools album gain for each complete
/// album group the page touches.
@MainActor
public final class LoudnessScanService: LoudnessScanning {
    /// Schema version stamped onto every row this pass writes.
    ///
    /// Bump it whenever the measurement's numbers change meaning: rows carrying
    /// an older version are treated exactly like a stale fingerprint and
    /// recomputed, so no migration is needed to invalidate a cache of derived
    /// values.
    ///
    /// `nonisolated` because it is a schema constant, not engine state: callers
    /// that never touch the main actor (a coverage query, a repository read)
    /// must be able to read it.
    public nonisolated static let analysisVersion = 1

    /// How many scans a page runs at once.
    ///
    /// `activeProcessorCount - 2` leaves headroom for the render thread and the
    /// main actor: a loudness sweep is a background nicety that must never
    /// starve playback or the UI. `2` is the floor, so even a dual-core machine
    /// overlaps one file's decode with another's K-weighting.
    public nonisolated static let concurrencyCap = max(2, ProcessInfo.processInfo.activeProcessorCount - 2)

    public private(set) var isRunning = false
    public private(set) var isPaused = false
    /// `internal(set)` because the page pipeline in `LoudnessScanService+Page.swift`
    /// books every completion — the ``AudioAnalysisService`` precedent for a
    /// publicly read-only property a sibling extension file writes.
    public internal(set) var progress: (completed: Int, total: Int) = (0, 0)
    public internal(set) var failedCount = 0
    public internal(set) var currentTrack: String?

    /// Whether the one-shot decoder warm-up has completed successfully.
    public internal(set) var didWarmUpDecoder = false

    public var onChange: (@MainActor () -> Void)?

    /// Held for the album-membership query only — every loudness read and write
    /// goes through ``repository``, so there is exactly one definition of
    /// staleness and one of the write shape.
    let database: AppDatabase
    let repository: any TrackLoudnessRepositoryProviding
    let scanner: any LoudnessMeasuring
    let pageSize: Int
    let warmUpOpen: @Sendable (URL) async throws -> Void
    private let now: @Sendable () -> Date
    private var task: Task<Void, Never>?

    /// When ``notifyCoalesced()`` last forwarded, and whether it has withheld a
    /// notification since. Together they are the whole coalescing state.
    var lastNotifiedAt: ContinuousClock.Instant?
    var hasWithheldNotification = false

    /// - Parameters:
    ///   - database: The library. Read and written off the main actor.
    ///   - scanner: The offline DSP seam. Its own conformer moves the decode off
    ///     this actor, so awaiting it here never blocks the UI.
    ///   - now: Clock seam stamped into `computedAt`, injected so a test asserts
    ///     an exact value instead of a wall-clock approximation.
    ///   - pageSize: Rows per keyset page, free so a test can split an album
    ///     across batches deliberately.
    ///   - warmUpOpen: The one-shot decoder warm-up. Defaults to
    ///     ``AudioAnalysisService/liveWarmUpOpen`` rather than a private copy:
    ///     what it initialises (mpg123's `INT123_frame_init_par`, SFB's format
    ///     registry) is PROCESS-global, so two passes must share one definition
    ///     of it or the second would re-derive a subtly different warm-up for the
    ///     same one-time hazard.
    public init(
        database: AppDatabase,
        scanner: any LoudnessMeasuring,
        now: @escaping @Sendable () -> Date = { Date() },
        pageSize: Int = 50,
        warmUpOpen: @escaping @Sendable (URL) async throws -> Void = AudioAnalysisService.liveWarmUpOpen
    ) {
        self.database = database
        repository = TrackLoudnessRepository(database)
        self.scanner = scanner
        self.now = now
        self.pageSize = max(1, pageSize)
        self.warmUpOpen = warmUpOpen
    }
}

// MARK: - Control surface

public extension LoudnessScanService {
    /// Starts a pass over the stale tracks. A no-op while already running.
    func start() {
        guard !isRunning else { return }
        beginPass()
        task = Task { [weak self] in
            await self?.run()
        }
    }

    /// Discards every cached loudness row, then runs an ordinary pass.
    ///
    /// The delete is the whole of the "force" mode: with no row left, every
    /// present track is stale by the repository's fingerprint clause and the
    /// unchanged run loop re-scans the library. Adding a `force` flag to the SQL
    /// would have meant two staleness definitions to keep in step instead of one.
    func startFullReanalysis() {
        guard !isRunning else { return }
        beginPass()
        task = Task { [weak self] in
            await self?.discardAllLoudness()
            await self?.run()
        }
    }

    /// Suspends a running pass at the next track boundary.
    func pause() {
        guard isRunning, !isPaused else { return }
        isPaused = true
        notify()
    }

    /// Resumes a paused pass from the cursor it stopped at.
    func resume() {
        guard isRunning, isPaused else { return }
        isPaused = false
        notify()
    }

    /// Cancels the pass. Cancellation-safe: rows written so far stay committed,
    /// and the interrupted track is simply still stale on the next pass.
    func stop() {
        task?.cancel()
        task = nil
        finish()
    }
}

// MARK: - Run loop

extension LoudnessScanService {
    func beginPass() {
        isRunning = true
        isPaused = false
        currentTrack = nil
        progress = (0, 0)
        failedCount = 0
        notify()
    }

    func run() async {
        let total = await staleTrackCount()
        progress = (0, total)
        notify()
        var cursor: PageCursor<Int64>?
        while !Task.isCancelled {
            await waitWhilePaused()
            if Task.isCancelled { break }
            let page = await nextStalePage(after: cursor)
            guard !page.items.isEmpty else { break }
            await processPage(page.items)
            guard let next = page.nextCursor else { break }
            cursor = next
        }
        finish()
    }

    func waitWhilePaused() async {
        while isPaused, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    func finish() {
        isRunning = false
        isPaused = false
        currentTrack = nil
        notify()
    }

    func notify() {
        onChange?()
    }
}

// MARK: - Bounded, off-main database access (id-keyset)

extension LoudnessScanService {
    func staleTrackCount() async -> Int {
        let count = try? await repository.staleCandidateCount(analysisVersion: Self.analysisVersion)
        return count ?? 0
    }

    func nextStalePage(after cursor: PageCursor<Int64>?) async -> Page<TrackRecord, Int64> {
        let page = try? await repository.staleCandidates(
            analysisVersion: Self.analysisVersion,
            after: cursor,
            limit: pageSize
        )
        return page ?? Page(items: [], nextCursor: nil)
    }

    func discardAllLoudness() async {
        try? await repository.deleteAll()
    }

    /// Writes the measurement, fingerprinted against the track row that produced
    /// it — including that row's OWN cue bounds. Stamping the whole-file sentinel
    /// instead would leave every cue segment permanently stale, because the
    /// staleness clause compares the stored bounds against `track.cueStartFrame` /
    /// `track.cueEndFrame` rather than against a literal.
    ///
    /// Album fields are written as `nil` on purpose: an upsert REPLACES the row,
    /// and a re-scanned track's old album figure describes a pooling that no
    /// longer includes this measurement. The album pass that follows this page
    /// re-pools the group and writes the fresh figure back to every member, so
    /// the window in which they are absent closes within the same page.
    func commit(_ result: LoudnessScanResult, for track: TrackRecord, trackId: Int64) async {
        let histogram = try? BlockLoudnessHistogram.encode(blockLoudness: result.gatedBlockLoudness)
        let record = TrackLoudnessRecord(
            trackId: trackId,
            integratedLUFS: result.integratedLUFS,
            truePeak: result.truePeak,
            blockPowersHistogram: histogram,
            analysisVersion: Self.analysisVersion,
            fingerprint: TrackLoudnessFingerprint(
                fileSize: track.fileSize ?? 0,
                mtime: track.mtime ?? 0,
                cueStartFrame: track.cueStartFrame,
                cueEndFrame: track.cueEndFrame
            ),
            computedAt: now().timeIntervalSince1970
        )
        try? await repository.upsert(record)
    }
}
