import Foundation

/// Abstraction over MIDI file playback.
///
/// This protocol lets the app shell and the test suite swap a real
/// `AVAudioUnitSampler`-backed engine (`MIDIPlayer`) for a deterministic
/// in-memory fake (`FakeMIDIPlayer`) without dragging AVFoundation into
/// pure-logic call sites.
///
/// Implementations route their audio through the shared `AVAudioEngine`
/// main-mixer graph so EQ, the DSP visualizer, and now-playing metadata
/// observe MIDI output exactly like decoded-file output.
///
/// `@MainActor`-isolated to match ``PlaybackEngine``: the UI drives the
/// transport, and the real conformer owns a non-`Sendable` `AVAudioEngine`.
@MainActor
public protocol MIDIPlaying: AnyObject {
    /// Whether a MIDI sequence is currently loaded and ready to play.
    var isLoaded: Bool { get }

    /// Whether playback is currently running.
    var isPlaying: Bool { get }

    /// Total duration of the loaded sequence in seconds. Zero when nothing is loaded.
    var duration: TimeInterval { get }

    /// Current playhead position in seconds. Setting it seeks.
    var currentTime: TimeInterval { get set }

    /// Load a `.mid` / `.midi` file from disk. Throws on parse/IO failure.
    func load(url: URL) throws

    /// Start (or resume) playback from the current playhead.
    func play() throws

    /// Pause playback, keeping the playhead in place.
    func pause()

    /// Stop playback and reset the playhead to zero.
    func stop()

    /// Seek to an absolute position in seconds (clamped to `0...duration`).
    func seek(to time: TimeInterval)
}

/// Deterministic in-memory `MIDIPlaying` for tests and previews.
///
/// Models the observable transport state machine without touching audio
/// hardware, so call sites that only care about play/pause/seek semantics
/// can be exercised offline.
@MainActor
public final class FakeMIDIPlayer: MIDIPlaying {
    public private(set) var isLoaded = false
    public private(set) var isPlaying = false
    public var duration: TimeInterval = 0

    private var playhead: TimeInterval = 0
    public var currentTime: TimeInterval {
        get { playhead }
        set { playhead = clamp(newValue) }
    }

    /// URL passed to the most recent successful `load(url:)`.
    public private(set) var loadedURL: URL?
    /// Injectable failure for `load(url:)`.
    public var loadError: Error?
    /// Injectable failure for `play()`.
    public var playError: Error?
    /// Duration assigned on load when `duration` is still zero.
    public var defaultDuration: TimeInterval = 10

    public init() {}

    public func load(url: URL) throws {
        if let loadError { throw loadError }
        loadedURL = url
        isLoaded = true
        isPlaying = false
        playhead = 0
        if duration == 0 { duration = defaultDuration }
    }

    public func play() throws {
        if let playError { throw playError }
        guard isLoaded else { return }
        isPlaying = true
    }

    public func pause() {
        isPlaying = false
    }

    public func stop() {
        isPlaying = false
        playhead = 0
    }

    public func seek(to time: TimeInterval) {
        playhead = clamp(time)
    }

    private func clamp(_ time: TimeInterval) -> TimeInterval {
        guard duration > 0 else { return max(0, time) }
        return min(max(0, time), duration)
    }
}
