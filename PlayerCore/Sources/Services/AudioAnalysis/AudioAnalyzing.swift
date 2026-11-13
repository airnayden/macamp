// AudioAnalyzing — the control surface of the library-wide audio-feature pass.
//
// The shape deliberately mirrors ``EnrichmentService``: a plain `@MainActor`
// engine with an `onChange` callback rather than an `@Observable` type, so the
// observable projection is a separate view model and the engine itself stays
// testable without the Observation runtime.
//
// The pass is OPT-IN. Constructing a conformer starts nothing — only an explicit
// ``start()`` walks the library. Nothing in PlayerCore calls ``start()``; that is
// a deliberate user gesture the shell wires to a button.
//
// PlayerCore portability: no imports at all — the surface is stdlib types only.

/// A pausable, resumable pass that fills `trackAudioFeature` for the library.
///
/// Conformers are profile-INDEPENDENT: tempo, energy and brightness describe the
/// file, not anyone's relationship to it, so one analysed track serves every
/// profile and a second profile re-analyses nothing.
@MainActor
public protocol AudioAnalyzing: AnyObject {
    /// `true` between ``start()`` and the run finishing / ``stop()``.
    var isRunning: Bool { get }

    /// `true` when a running pass is suspended (``pause()``).
    var isPaused: Bool { get }

    /// Tracks processed so far vs the number found stale when the pass began.
    ///
    /// `total` counts only STALE tracks — a library that is already fully
    /// analysed reports `(0, 0)`, not `(0, libraryCount)`.
    ///
    /// `completed` counts every track the pass ATTEMPTED, successes and failures
    /// alike, so a pass with failures still reaches `completed == total` instead
    /// of stalling a progress bar short of the end. The failures are reported
    /// separately by ``failedCount``.
    var progress: (completed: Int, total: Int) { get }

    /// How many of the ``progress`` completions threw instead of writing a row.
    ///
    /// Deliberately distinct from `progress.completed`: a corrupt or unreadable
    /// file must not abort the pass, so it is counted here and skipped. Reset by
    /// each ``start()``. A pass cancelled through ``stop()`` never contributes.
    var failedCount: Int { get }

    /// Title (or file name) of the track currently being analysed, if any.
    var currentTrack: String? { get }

    /// Invoked on the main actor after any state mutation so an observable
    /// projection can mirror it. The conformer itself is not `@Observable`.
    var onChange: (@MainActor () -> Void)? { get set }

    /// Starts a pass over the stale tracks. A no-op while already running.
    func start()

    /// Discards every cached analysis row, then runs an ordinary pass over the
    /// whole library. A no-op while already running.
    ///
    /// ``start()`` is fingerprint-driven and therefore correctly does nothing on
    /// a fully analysed library, which leaves no way to recover from an analysis
    /// that is wrong for a reason the fingerprint cannot see — a file rewritten
    /// with an identical size and mtime, or a run interrupted by a bug. This is
    /// that escape hatch, and it is destructive of DERIVED data only:
    /// `trackAudioFeature` holds nothing that cannot be recomputed from the
    /// files themselves.
    ///
    /// Deletion happens INSIDE the pass rather than in the caller, so the rows
    /// and the walk that refills them can never disagree, and so pause / resume
    /// / stop govern the whole operation exactly as they govern ``start()``.
    func startFullReanalysis()

    /// Suspends a running pass at the next track boundary.
    func pause()

    /// Resumes a paused pass from the cursor it stopped at.
    func resume()

    /// Cancels the pass. Cancellation-safe: rows written so far stay committed.
    func stop()
}
