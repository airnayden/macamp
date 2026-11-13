//
//  LoudnessScanning.swift
//  MacAMP PlayerCore — Services
//
//  The control surface of the library-wide loudness pass.
//
//  The shape deliberately mirrors ``AudioAnalyzing`` (which in turn mirrors
//  ``EnrichmentService``): a plain `@MainActor` engine with an `onChange`
//  callback rather than an `@Observable` type, so the observable projection is a
//  separate view model and the engine itself stays testable without the
//  Observation runtime.
//
//  The pass is OPT-IN. Constructing a conformer starts nothing — only an explicit
//  ``start()`` walks the library. Nothing in PlayerCore calls ``start()``; that is
//  a deliberate user gesture the shell wires to a button.
//
//  PlayerCore portability: no imports at all — the surface is stdlib types only.
//

/// A pausable, resumable pass that fills `trackLoudness` for the library and
/// pools album gain once every member of an album has been measured.
///
/// Conformers are profile-INDEPENDENT: integrated loudness and true peak
/// describe the FILE, not anyone's relationship to it, so one scanned track
/// serves every profile and a second profile re-scans nothing.
@MainActor
public protocol LoudnessScanning: AnyObject {
    /// `true` between ``start()`` and the run finishing / ``stop()``.
    var isRunning: Bool { get }

    /// `true` when a running pass is suspended (``pause()``).
    var isPaused: Bool { get }

    /// Tracks processed so far vs the number found stale when the pass began.
    ///
    /// `total` counts only STALE tracks — a library that is already fully
    /// scanned reports `(0, 0)`, not `(0, libraryCount)`.
    ///
    /// `completed` counts every track the pass ATTEMPTED, successes and failures
    /// alike, so a pass with failures still reaches `completed == total` instead
    /// of stalling a progress bar short of the end.
    var progress: (completed: Int, total: Int) { get }

    /// How many of the ``progress`` completions threw instead of writing a row.
    ///
    /// A failure is load-bearing beyond the tally: it leaves the track with NO
    /// `trackLoudness` row, which keeps its album group incomplete and therefore
    /// unpooled. That is the fail-closed denominator — a failed member is never
    /// filtered out of the group it belongs to. Reset by each ``start()``; a pass
    /// cancelled through ``stop()`` never contributes.
    var failedCount: Int { get }

    /// Title (or file name) of the track currently being scanned, if any.
    var currentTrack: String? { get }

    /// Invoked on the main actor after any state mutation so an observable
    /// projection can mirror it. The conformer itself is not `@Observable`.
    var onChange: (@MainActor () -> Void)? { get set }

    /// Starts a pass over the stale tracks. A no-op while already running.
    func start()

    /// Discards every cached loudness row, then runs an ordinary pass over the
    /// whole library. A no-op while already running.
    ///
    /// ``start()`` is fingerprint-driven and therefore correctly does nothing on
    /// a fully scanned library, which leaves no way to recover from a scan that
    /// is wrong for a reason the fingerprint cannot see — a file rewritten with
    /// an identical size and mtime, or a run interrupted by a bug. This is that
    /// escape hatch, and it is destructive of DERIVED data only: `trackLoudness`
    /// holds nothing that cannot be recomputed from the files themselves.
    func startFullReanalysis()

    /// Suspends a running pass at the next track boundary.
    func pause()

    /// Resumes a paused pass from the cursor it stopped at.
    func resume()

    /// Cancels the pass. Cancellation-safe: rows written so far stay committed.
    func stop()
}
