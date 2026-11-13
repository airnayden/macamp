// AudioAnalysisService — the opt-in, resumable library-wide audio-feature pass.
//
// Control surface and run loop are modelled directly on ``EnrichmentService``:
// a plain `@MainActor` engine, an `onChange` callback, start/pause/resume/stop,
// and an `id`-keyset cursor. There is deliberately NO marker table — the
// DATABASE is the progress record. A track stops being a candidate the instant
// its `trackAudioFeature` row lands, so an interrupted pass resumes simply by
// asking the same question again, and a pass over an already-analysed library
// costs one COUNT and one empty page.
//
// PROFILE-INDEPENDENT by design. `trackAudioFeature` has no `profileId` column
// because tempo, energy and brightness describe the FILE, not anyone's
// relationship to it. This service therefore takes no profile, applies no
// `LibraryVisibility` scoping, and every profile reads the same rows.
//
// OPT-IN. Nothing here runs until an explicit ``start()``; merely constructing
// the service reads nothing and schedules nothing.
//
// PlayerCore portability: Foundation + GRDB through Persistence + Decoding.
import Decoding
import Foundation
import GRDB
import Persistence

/// Fills `trackAudioFeature` for every present track whose analysis is missing
/// or stale, one bounded `id`-keyset page at a time.
@MainActor
public final class AudioAnalysisService: AudioAnalyzing {
    /// Schema version stamped onto every row this pass writes.
    ///
    /// Bump it whenever the extractor's numbers change meaning: rows carrying an
    /// older version are treated exactly like a stale fingerprint and recomputed,
    /// so no migration is needed to invalidate a cache of derived values.
    ///
    /// `nonisolated` because it is a schema constant, not engine state: callers
    /// that never touch the main actor (a migration check, a repository query)
    /// must be able to read it.
    public nonisolated static let analysisVersion = 1

    /// How many extractions a page runs at once.
    ///
    /// `activeProcessorCount - 2` leaves headroom for the render thread and the
    /// main actor: analysis is a background nicety that must never starve
    /// playback or the UI. `2` is the floor, so even a dual-core machine overlaps
    /// one file's decode with another's FFT instead of running strictly serially.
    public nonisolated static let concurrencyCap = max(2, ProcessInfo.processInfo.activeProcessorCount - 2)

    public private(set) var isRunning = false
    public private(set) var isPaused = false
    /// `internal(set)` because the page pipeline in `AudioAnalysisService+Page.swift`
    /// books every completion — the ``PlaybackCoordinator/state`` precedent for a
    /// publicly read-only property a sibling extension file writes.
    public internal(set) var progress: (completed: Int, total: Int) = (0, 0)
    public internal(set) var failedCount = 0
    public internal(set) var currentTrack: String?

    /// Whether the one-shot decoder warm-up has completed successfully.
    ///
    /// Set only after ``warmUpOpen`` returns without throwing on an MPEG-family
    /// candidate — see `AudioAnalysisService+Page.swift`. `internal(set)` for the
    /// same reason as ``progress``: the page pipeline is a sibling extension file.
    public internal(set) var didWarmUpDecoder = false

    public var onChange: (@MainActor () -> Void)?

    private let database: AppDatabase
    let extractor: any AudioFeatureExtracting
    private let now: @Sendable () -> Date
    private let pageSize: Int
    let warmUpOpen: @Sendable (URL) async throws -> Void
    private var task: Task<Void, Never>?

    /// When ``notifyCoalesced()`` last forwarded, and whether it has withheld a
    /// notification since. Together they are the whole coalescing state.
    var lastNotifiedAt: ContinuousClock.Instant?
    var hasWithheldNotification = false

    /// - Parameters:
    ///   - database: The library. Read and written off the main actor.
    ///   - extractor: The offline DSP seam. Its own conformer moves the decode
    ///     off this actor, so awaiting it here never blocks the UI.
    ///   - now: Clock seam stamped into `computedAt`, injected so a test asserts
    ///     an exact value instead of a wall-clock approximation.
    ///   - pageSize: Rows per keyset page, free so a test can prove the result
    ///     does not depend on it.
    ///   - warmUpOpen: The one-shot decoder warm-up, defaulting to
    ///     ``liveWarmUpOpen``. Injected so a suite can observe which candidate
    ///     the page picked, and make the open fail on demand.
    public init(
        database: AppDatabase,
        extractor: any AudioFeatureExtracting,
        now: @escaping @Sendable () -> Date = { Date() },
        pageSize: Int = 50,
        warmUpOpen: @escaping @Sendable (URL) async throws -> Void = AudioAnalysisService.liveWarmUpOpen
    ) {
        self.database = database
        self.extractor = extractor
        self.now = now
        self.pageSize = max(1, pageSize)
        self.warmUpOpen = warmUpOpen
    }

    /// The production warm-up: builds and immediately drops ONE real decoder
    /// through ``DecoderOpenGate/shared``, and touches SFB's format registry.
    ///
    /// Both are process-global one-time initialisations — mpg123's
    /// `INT123_frame_init_par` and the registry's `dispatch_once` — and running
    /// them here, serially, is what stops the page's fan-out from reaching them
    /// on several threads at once. It also covers the paths the gate deliberately
    /// does not: the playback engine opens its decoders on the main actor and can
    /// never suspend behind the gate, so a warm process is its only protection.
    ///
    /// `nonisolated` so it can be named as a default argument and called off the
    /// main actor, matching ``analysisVersion`` and ``concurrencyCap``.
    public nonisolated static let liveWarmUpOpen: @Sendable (URL) async throws -> Void = { url in
        _ = SFBDecoderProvider.supportedPathExtensions
        _ = try await DecoderOpenGate.shared.open(url, with: SFBDecoderProvider())
    }
}

// MARK: - Control surface

public extension AudioAnalysisService {
    /// Starts a pass over the stale tracks. A no-op while already running.
    func start() {
        guard !isRunning else { return }
        beginPass()
        task = Task { [weak self] in
            await self?.run()
        }
    }

    /// Discards every cached analysis row, then runs an ordinary pass.
    ///
    /// The delete is the whole of the "force" mode: with no row left, every
    /// present track is stale by ``staleFingerprintClause`` and the unchanged
    /// run loop re-analyses the library. Adding a `force` flag to the SQL would
    /// have meant two staleness definitions to keep in step with
    /// ``AudioFeatureCoverageReader``'s positive twin instead of one.
    func startFullReanalysis() {
        guard !isRunning else { return }
        beginPass()
        task = Task { [weak self] in
            await self?.discardAllFeatures()
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

extension AudioAnalysisService {
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
        var lastID: Int64?
        while !Task.isCancelled {
            await waitWhilePaused()
            if Task.isCancelled { break }
            let page = await nextStalePage(afterID: lastID)
            guard !page.isEmpty else { break }
            await processPage(page)
            lastID = page.last?.id
            guard lastID != nil else { break }
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

extension AudioAnalysisService {
    func staleTrackCount() async -> Int {
        let sql = Self.staleCountSQL
        let version = Self.analysisVersion
        let count = try? await database.writer.read { db -> Int in
            let arguments: StatementArguments = [Availability.present.rawValue, version]
            return try Int.fetchOne(db, sql: sql, arguments: arguments) ?? 0
        }
        return count ?? 0
    }

    /// Empties `trackAudioFeature` in one statement.
    ///
    /// Unbounded by design and safe to be: this is a `DELETE` with no `WHERE`,
    /// which SQLite answers with the truncate optimisation — it drops pages
    /// rather than materialising rows, so a 100k library costs no more memory
    /// than an empty one.
    func discardAllFeatures() async {
        try? await database.writer.write { db in
            try db.execute(sql: "DELETE FROM trackAudioFeature")
        }
    }

    func nextStalePage(afterID lastID: Int64?) async -> [TrackRecord] {
        let sql = Self.stalePageSQL
        let version = Self.analysisVersion
        let anchor = lastID ?? 0
        let limit = pageSize
        let page = try? await database.writer.read { db -> [TrackRecord] in
            let arguments: StatementArguments = [Availability.present.rawValue, anchor, version, limit]
            return try TrackRecord.fetchAll(db, sql: sql, arguments: arguments)
        }
        return page ?? []
    }

    /// Writes the analysis, fingerprinted against the track row that produced it.
    ///
    /// `upsert` rather than `insert`: the key is the caller-supplied `trackId`, so
    /// re-analysing a changed file must overwrite its previous row in place —
    /// the same shape ``ProfilePlaybackStateRepository`` uses for the other
    /// single-column caller-keyed table.
    func commit(_ features: AudioFeatureResult, for track: TrackRecord, trackId: Int64) async {
        let record = TrackAudioFeatureRecord(
            trackId: trackId,
            fileSize: track.fileSize ?? 0,
            mtime: track.mtime ?? 0,
            bpm: features.bpm,
            energy: features.energy,
            brightness: features.brightness,
            analysisVersion: Self.analysisVersion,
            computedAt: now().timeIntervalSince1970
        )
        try? await database.writer.write { db in
            try record.upsert(db)
        }
    }
}

// MARK: - Staleness (SQL)

private extension AudioAnalysisService {
    /// A track is a candidate while NO `trackAudioFeature` row matches both the
    /// current ``analysisVersion`` and the file's `(fileSize, mtime)` fingerprint.
    /// One clause therefore covers all three reasons to analyse: never analysed,
    /// the file changed since, and analysed by an older extractor.
    ///
    /// `COALESCE(…, 0)` is what makes a track with no recorded fingerprint
    /// TERMINATE. `track.fileSize`/`track.mtime` are nullable, and a bare
    /// comparison against NULL is never true, so such a track would look stale on
    /// every future pass and be re-analysed forever. The writer stamps the same
    /// `0` sentinel, so instead it is analysed exactly once — and re-analysed the
    /// moment a re-scan gives it a real fingerprint.
    static var staleFingerprintClause: String {
        """
        NOT EXISTS (
          SELECT 1 FROM trackAudioFeature
          WHERE trackAudioFeature.trackId = track.id
            AND trackAudioFeature.analysisVersion = ?
            AND trackAudioFeature.fileSize = COALESCE(track.fileSize, 0)
            AND trackAudioFeature.mtime = COALESCE(track.mtime, 0)
        )
        """
    }

    /// One bounded page of stale tracks. `track.id` is a rowid alias starting at
    /// 1, so a `0` anchor selects the whole table and the cursor needs no
    /// conditional SQL — the ``TrackRepository/filePathsWithoutLyricsProbe``
    /// precedent.
    ///
    /// Argument order is the `?` order in the final string:
    /// availability, cursor, analysis version, limit.
    static var stalePageSQL: String {
        """
        SELECT track.* FROM track
        WHERE track.availability = ? AND track.id > ? AND \(staleFingerprintClause)
        ORDER BY track.id ASC
        LIMIT ?
        """
    }

    /// The pass total, counted once at start. Arguments: availability, version.
    static var staleCountSQL: String {
        """
        SELECT COUNT(*) FROM track
        WHERE track.availability = ? AND \(staleFingerprintClause)
        """
    }
}
