// FakeAudioAnalysisService — a control-surface double for the audio-feature pass.
//
// Records every control call and lets a test drive the published state directly,
// so a consumer (the view model that mirrors this surface, or a composition root
// asserting the pass is never auto-started) can be exercised without a database,
// a decoder, or a background Task.
//
// Style mirrors ``FakeLyricsSweeper``: the protocol is `@MainActor`, so the
// double needs no lock.
import Services

/// A canned ``AudioAnalyzing`` that analyses nothing and remembers everything.
@MainActor
public final class FakeAudioAnalysisService: AudioAnalyzing {
    public private(set) var isRunning = false
    public private(set) var isPaused = false
    public private(set) var progress: (completed: Int, total: Int) = (0, 0)
    public private(set) var failedCount = 0
    public private(set) var currentTrack: String?

    public var onChange: (@MainActor () -> Void)?

    /// How many times ``start()`` was called — `0` proves an opt-in pass was
    /// never auto-started.
    public private(set) var startCount = 0
    /// How many times ``startFullReanalysis()`` was called. Counted separately
    /// from ``startCount`` so a test can prove a confirmation dialog routed to
    /// the destructive pass rather than to the incremental one.
    public private(set) var fullReanalysisCount = 0
    /// How many times ``pause()`` was called.
    public private(set) var pauseCount = 0
    /// How many times ``resume()`` was called.
    public private(set) var resumeCount = 0
    /// How many times ``stop()`` was called.
    public private(set) var stopCount = 0

    public init() {}

    public func start() {
        startCount += 1
        begin()
    }

    public func startFullReanalysis() {
        fullReanalysisCount += 1
        begin()
    }

    private func begin() {
        guard !isRunning else { return }
        isRunning = true
        isPaused = false
        currentTrack = nil
        progress = (0, 0)
        failedCount = 0
        onChange?()
    }

    public func pause() {
        pauseCount += 1
        guard isRunning, !isPaused else { return }
        isPaused = true
        onChange?()
    }

    public func resume() {
        resumeCount += 1
        guard isRunning, isPaused else { return }
        isPaused = false
        onChange?()
    }

    public func stop() {
        stopCount += 1
        isRunning = false
        isPaused = false
        currentTrack = nil
        onChange?()
    }
}

// MARK: - Driving the published state

public extension FakeAudioAnalysisService {
    /// Publishes a mid-pass state, standing in for the real run loop.
    func simulateProgress(
        completed: Int,
        total: Int,
        currentTrack: String? = nil,
        failedCount: Int = 0
    ) {
        isRunning = true
        progress = (completed, total)
        self.currentTrack = currentTrack
        self.failedCount = failedCount
        onChange?()
    }

    /// Publishes the terminal state a completed pass leaves behind.
    func simulateFinish() {
        isRunning = false
        isPaused = false
        currentTrack = nil
        onChange?()
    }
}
