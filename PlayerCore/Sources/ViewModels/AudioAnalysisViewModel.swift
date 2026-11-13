// AudioAnalysisViewModel — the @Observable projection of the audio-feature pass.
//
// The ``EnrichmentViewModel`` shape: the engine stays a plain `@MainActor`
// service with an `onChange` callback, and this type is the only thing the
// Observation runtime tracks. It owns no analysis logic — every control call is
// forwarded verbatim.
//
// One fact it does own: ``analyzedFraction``. That is a LIBRARY-WIDE coverage
// ratio and is deliberately NOT derived from ``AudioAnalyzing/progress``.
// `progress.total` counts only the tracks found stale when the pass began, so it
// reports `(0, 0)` on a fully analysed library and can be exceeded by `completed`
// when a library scan lands mid-pass. Answering "34% analyzed" from it would be
// wrong in both directions; the ratio comes from its own bounded `COUNT(*)` pair
// instead.
import Foundation
import Observation
import Persistence
import Services

/// Observable state for the opt-in library audio-analysis pass.
@MainActor
@Observable
public final class AudioAnalysisViewModel {
    /// `true` between ``start()`` and the pass finishing or being stopped.
    public private(set) var isRunning = false

    /// `true` while a running pass is suspended.
    public private(set) var isPaused = false

    /// Completed over total for the CURRENT pass, in `0...1`.
    ///
    /// Clamped rather than divided raw: `progress.total` is a start-of-pass
    /// snapshot, so a library scan that lands mid-pass can push `completed`
    /// past it.
    public private(set) var progressFraction: Double = 0

    /// `"<completed> / <total>"` for the current pass.
    public private(set) var progressText: String = ""

    /// Title (or file name) of the track being analysed, if any.
    public private(set) var currentTrack: String?

    /// Tracks this pass attempted and could not analyse.
    ///
    /// A permanently undecodable file is retried by every future pass — there is
    /// no negative-result sentinel — so a library containing one keeps a non-zero
    /// count here and ``analyzedFraction`` below `1`. UI copy must not promise
    /// "100%".
    public private(set) var failedCount = 0

    /// Fraction of the present library carrying current analysis, in `0...1`.
    ///
    /// Refreshed on ``refreshAnalyzedFraction()``, once from `init`, and
    /// automatically whenever a pass finishes. Independent of
    /// ``progressFraction``: that one describes a pass, this one describes the
    /// library.
    ///
    /// READ IT WITH ``hasMeasuredCoverage``. Until the first read lands this is
    /// `0`, which is indistinguishable from a genuinely unanalysed library.
    public private(set) var analyzedFraction: Double = 0

    /// Whether ``analyzedFraction`` has ever been filled from the database.
    ///
    /// The coverage read is asynchronous, so between `init` and its completion
    /// ``analyzedFraction`` still holds its `0` default — indistinguishable from
    /// a genuinely unanalysed library. A surface built inside that window (a
    /// `.contextMenu` body, evaluated once and not rebuilt by a later
    /// Observation change) then keeps the wrong answer for the whole session.
    ///
    /// Callers that REFUSE an action on low coverage must therefore treat
    /// `false` as "not known yet" and allow it.
    public private(set) var hasMeasuredCoverage = false

    /// Present tracks carrying current analysis — the numerator behind
    /// ``analyzedFraction``, for copy like "340 of 1,000".
    public private(set) var analyzedTrackCount = 0

    /// Present tracks in the library — the denominator behind
    /// ``analyzedFraction``.
    public private(set) var analyzableTrackCount = 0

    @ObservationIgnored private let service: any AudioAnalyzing
    @ObservationIgnored private let database: AppDatabase

    /// - Parameters:
    ///   - service: The pass to mirror and forward to.
    ///   - database: The library, read off-main for the coverage ratio only.
    public init(service: any AudioAnalyzing, database: AppDatabase) {
        self.service = service
        self.database = database
        service.onChange = { [weak self] in
            self?.sync()
        }
        sync()
        refreshCoverageInBackground()
    }
}

// MARK: - Control surface

public extension AudioAnalysisViewModel {
    /// Starts a pass over the stale tracks.
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

    /// Discards every cached analysis row and re-analyses the whole library.
    ///
    /// Destructive of DERIVED data only, and long-running on a large library —
    /// callers must confirm with the listener first. Progress, pause, resume and
    /// stop behave exactly as they do for ``start()``.
    func reanalyzeAll() {
        service.startFullReanalysis()
    }

    /// Re-reads library-wide coverage off the main actor.
    ///
    /// Two `COUNT(*)`s over indexed columns — no row is materialised, so this is
    /// safe to call on a 100k library whenever a view appears.
    func refreshAnalyzedFraction() async {
        let version = AudioAnalysisService.analysisVersion
        let coverage = try? await database.writer.read { db in
            try AudioFeatureCoverageReader.libraryCoverage(db, analysisVersion: version)
        }
        guard let coverage else { return }
        apply(coverage)
    }
}

// MARK: - Mirroring

private extension AudioAnalysisViewModel {
    /// Copies the service's state onto the observable properties.
    ///
    /// Every write is equality-guarded because this runs once per analysed track:
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

    func apply(_ coverage: AudioFeatureCoverage) {
        if analyzedTrackCount != coverage.analyzed { analyzedTrackCount = coverage.analyzed }
        if analyzableTrackCount != coverage.total { analyzableTrackCount = coverage.total }
        if analyzedFraction != coverage.fraction { analyzedFraction = coverage.fraction }
        if !hasMeasuredCoverage { hasMeasuredCoverage = true }
    }

    func refreshCoverageInBackground() {
        Task { [weak self] in
            await self?.refreshAnalyzedFraction()
        }
    }

    /// `completed / total` in `0...1`, and `0` for a pass with nothing to do.
    static func clampedFraction(completed: Int, total: Int) -> Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(completed) / Double(total)))
    }
}
