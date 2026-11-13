// LoudnessScanViewModel — the @Observable projection of the BS.1770-4 loudness pass.
//
// ``AudioAnalysisViewModel``'s twin, over ``LoudnessScanning`` instead of
// ``AudioAnalyzing``: the engine stays a plain `@MainActor` service with an
// `onChange` callback, and this type is the only thing the Observation runtime
// tracks. It owns no analysis logic — every control call is forwarded verbatim.
//
// ``analyzedFraction`` is a LIBRARY-WIDE coverage ratio and is deliberately NOT
// derived from ``LoudnessScanning/progress``: that tuple's `total` counts only
// the tracks found stale when the pass began, so it reports `(0, 0)` on a fully
// analysed library and can be exceeded by `completed` when a library scan lands
// mid-pass. The ratio comes from its own bounded conditional-aggregate read.
//
// NOTHING HERE STARTS ON ITS OWN. `init` reads coverage and nothing else; a pass
// runs only from ``start()``, ``rescanAll()`` or ``analyze(trackIds:)``, each of
// which is reachable only from an explicit user action. An import must never
// trigger a scan.
import Foundation
import Observation
import Persistence
import Services

/// Observable state for the library loudness pass.
@MainActor
@Observable
public final class LoudnessScanViewModel {
    /// `true` between a start and the pass finishing or being stopped.
    public private(set) var isRunning = false

    /// `true` while a running pass is suspended.
    public private(set) var isPaused = false

    /// Completed over total for the CURRENT pass, in `0...1`.
    ///
    /// Clamped rather than divided raw: `progress.total` is a start-of-pass
    /// snapshot, so a library scan landing mid-pass can push `completed` past it.
    public private(set) var progressFraction: Double = 0

    /// `"<completed> / <total>"` for the current pass.
    public private(set) var progressText: String = ""

    /// Title (or file name) of the track being measured, if any.
    public private(set) var currentTrack: String?

    /// Tracks this pass attempted and could not measure.
    ///
    /// A permanently undecodable file is retried by every future pass — there is
    /// no negative-result sentinel — so a library containing one keeps a non-zero
    /// count here and ``analyzedFraction`` below `1`. UI copy must not promise
    /// "100%".
    public private(set) var failedCount = 0

    /// Fraction of the present library carrying current loudness, in `0...1`.
    ///
    /// READ IT WITH ``hasMeasuredCoverage``: until the first read lands this is
    /// `0`, which is indistinguishable from a genuinely unanalysed library.
    public private(set) var analyzedFraction: Double = 0

    /// Whether ``analyzedFraction`` has ever been filled from the database.
    ///
    /// The coverage read is asynchronous, so a surface built inside the window
    /// between `init` and its completion — a `.contextMenu` body, evaluated once
    /// and not rebuilt by a later Observation change — would otherwise keep the
    /// wrong answer for the whole session. Callers that REFUSE an action on low
    /// coverage must treat `false` as "not known yet" and allow it.
    public private(set) var hasMeasuredCoverage = false

    /// Present tracks carrying current loudness — the numerator behind
    /// ``analyzedFraction``, for copy like "340 of 1,000".
    public private(set) var analyzedTrackCount = 0

    /// Present tracks in the library — the denominator behind
    /// ``analyzedFraction``.
    public private(set) var analyzableTrackCount = 0

    @ObservationIgnored private let service: any LoudnessScanning
    @ObservationIgnored private let database: AppDatabase
    @ObservationIgnored private let invalidator: any TrackLoudnessInvalidating

    /// - Parameters:
    ///   - service: The pass to mirror and forward to.
    ///   - database: The library, read off-main for the coverage ratio only.
    ///   - invalidator: The seam ``analyze(trackIds:)`` discards rows through.
    ///     Defaults to a repository over `database`; injected by tests.
    public init(
        service: any LoudnessScanning,
        database: AppDatabase,
        invalidator: (any TrackLoudnessInvalidating)? = nil
    ) {
        self.service = service
        self.database = database
        self.invalidator = invalidator ?? TrackLoudnessRepository(database)
        service.onChange = { [weak self] in
            self?.sync()
        }
        sync()
        refreshCoverageInBackground()
    }
}

// MARK: - Control surface

public extension LoudnessScanViewModel {
    /// Measures every present track whose loudness is missing or stale.
    func start() {
        service.start()
    }

    /// Suspends a running pass at the next track boundary.
    func pause() {
        service.pause()
    }

    /// Resumes a paused pass from the cursor it stopped at.
    func resume() {
        service.resume()
    }

    /// Cancels the pass, keeping every row written so far.
    func stop() {
        service.stop()
    }

    /// Discards every cached loudness row and measures the whole library again.
    ///
    /// Destructive of DERIVED data only, and long-running on a large library —
    /// callers must confirm with the listener first.
    func rescanAll() {
        service.startFullReanalysis()
    }

    /// Measures exactly `trackIds`, whatever their cached rows say.
    ///
    /// The selection-scoped twin of ``rescanAll()``, and it works the same way:
    /// discard those rows, then run the ordinary pass. With no row left each
    /// selected track is stale by the repository's own clause, so the unchanged
    /// run loop measures it — and the pass's per-page ALBUM POOLING still runs
    /// over it. A bespoke targeted analyser would have to restate both the commit
    /// and the pooling, and would leave every album it touched un-pooled.
    ///
    /// Exactly the selection is discarded: ids are de-duplicated, keep the order
    /// the listener sees, and non-positive ids (the "not a library track"
    /// sentinel `TrackRef` carries) are dropped before the seam is reached.
    ///
    /// The pass that follows also picks up anything else already stale. That is
    /// the same bargain ``rescanAll()`` makes and the reason the action is worded
    /// as analysing the selection rather than only the selection.
    func analyze(trackIds: [Int64]) async {
        let targets = Self.analysisTargets(trackIds)
        guard !targets.isEmpty else { return }
        try? await invalidator.deleteLoudness(forTrackIds: targets)
        service.start()
    }

    /// Re-reads library-wide coverage off the main actor.
    ///
    /// One conditional-aggregate pass over indexed columns — no row is
    /// materialised, so this is safe to call on a 100k library whenever a view
    /// appears.
    func refreshCoverage() async {
        let version = LoudnessScanService.analysisVersion
        let coverage = try? await database.writer.read { db in
            try TrackLoudnessCoverageReader.libraryCoverage(db, analysisVersion: version)
        }
        guard let coverage else { return }
        apply(coverage)
    }
}

// MARK: - Selection normalisation (pure)

public extension LoudnessScanViewModel {
    /// `trackIds` de-duplicated, order-preserved, with non-positive ids dropped.
    ///
    /// `track.id` is a rowid alias starting at 1, so `0` is the "not a library
    /// track" sentinel and must never reach a `DELETE … WHERE trackId IN (…)`.
    static func analysisTargets(_ trackIds: [Int64]) -> [Int64] {
        var seen = Set<Int64>()
        return trackIds.filter { trackId in
            trackId > 0 && seen.insert(trackId).inserted
        }
    }
}

// MARK: - Mirroring

private extension LoudnessScanViewModel {
    /// Copies the service's state onto the observable properties.
    ///
    /// Every write is equality-guarded because this runs once per measured track:
    /// `@Observable` notifies on a same-value write, so an unguarded mirror would
    /// invalidate every observing view on every tick even when nothing it reads
    /// changed.
    func sync() {
        let wasRunning = isRunning
        if isRunning != service.isRunning { isRunning = service.isRunning }
        if isPaused != service.isPaused { isPaused = service.isPaused }
        if currentTrack != service.currentTrack { currentTrack = service.currentTrack }
        if failedCount != service.failedCount { failedCount = service.failedCount }
        let (completed, total) = service.progress
        let fraction = Self.clampedFraction(completed: completed, total: total)
        if progressFraction != fraction { progressFraction = fraction }
        let text = "\(completed) / \(total)"
        if progressText != text { progressText = text }
        // A finished pass is the one moment coverage is guaranteed to have moved.
        if wasRunning, !isRunning { refreshCoverageInBackground() }
    }

    func apply(_ coverage: TrackLoudnessCoverage) {
        if analyzedTrackCount != coverage.analyzed { analyzedTrackCount = coverage.analyzed }
        if analyzableTrackCount != coverage.total { analyzableTrackCount = coverage.total }
        if analyzedFraction != coverage.fraction { analyzedFraction = coverage.fraction }
        if !hasMeasuredCoverage { hasMeasuredCoverage = true }
    }

    func refreshCoverageInBackground() {
        Task { [weak self] in
            await self?.refreshCoverage()
        }
    }

    /// `completed / total` in `0...1`, and `0` for a pass with nothing to do.
    static func clampedFraction(completed: Int, total: Int) -> Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(completed) / Double(total)))
    }
}
