// FakeKaraokeRenderer — an in-memory ``KaraokeRendering`` double.
//
// A deterministic stand-in for `KaraokeRenderService`: it records the enabled flag
// and every render request (cumulatively, in order), models a live queue
// (`currentURL` + `pendingURLs` + `isPaused`) that mirrors the real service's
// snapshot behavior, and lets a test push progress through ``emit(_:)``, advance the
// queue through ``startNext()``, and complete through ``finish(_:result:)`` as if a
// background separation reported it. It performs no actual separation. `@MainActor`,
// mirroring the protocol's isolation and the `FakePlaybackEngine`/`FakeProfileService`
// style.
import Foundation
import Separation

/// An in-memory ``KaraokeRendering`` for hermetic tests and previews.
@MainActor
public final class FakeKaraokeRenderer: KaraokeRendering {
    public private(set) var isEnabled = false
    public private(set) var requestedURLs: [URL] = []
    public private(set) var setEnabledCallCount = 0
    public private(set) var requestRenderCallCount = 0
    public private(set) var cancelAllCallCount = 0
    public private(set) var pauseCallCount = 0
    public private(set) var resumeCallCount = 0
    public private(set) var startNowCallCount = 0
    public private(set) var stopCurrentCallCount = 0
    public private(set) var isPaused = false
    public private(set) var currentURL: URL?
    public private(set) var pendingURLs: [URL] = []
    public var onProgress: (@Sendable (KaraokePrewarmProgress) -> Void)?
    public var onFinished: (@Sendable (URL, KaraokeRenderResult) -> Void)?
    public var onQueueChanged: (@Sendable (KaraokeQueueSnapshot) -> Void)?

    public init() {}

    public func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        setEnabledCallCount += 1
        guard !enabled else { return }
        currentURL = nil
        pendingURLs.removeAll()
        emitQueueChanged()
    }

    public func requestRender(_ url: URL) {
        requestedURLs.append(url)
        pendingURLs.append(url)
        requestRenderCallCount += 1
        emitQueueChanged()
    }

    public func cancelAll() {
        cancelAllCallCount += 1
        currentURL = nil
        pendingURLs.removeAll()
        emitQueueChanged()
    }

    public func pause() {
        pauseCallCount += 1
        pauseAndRequeueCurrent()
    }

    public func resume() {
        resumeCallCount += 1
        isPaused = false
        emitQueueChanged()
    }

    public func removePending(_ url: URL) {
        guard let index = pendingURLs.firstIndex(of: url) else { return }
        pendingURLs.remove(at: index)
        emitQueueChanged()
    }

    public func movePending(_ url: URL, to index: Int) {
        guard let from = pendingURLs.firstIndex(of: url) else { return }
        let target = min(max(index, 0), pendingURLs.count - 1)
        guard target != from else { return }
        pendingURLs.remove(at: from)
        pendingURLs.insert(url, at: target)
        emitQueueChanged()
    }

    public func startNow(_ url: URL) {
        startNowCallCount += 1
        let wasPaused = isPaused
        isPaused = false
        if currentURL == url {
            if wasPaused { emitQueueChanged() }
            return
        }
        pendingURLs.removeAll { $0 == url }
        if let current = currentURL {
            pendingURLs.insert(current, at: 0)
        }
        currentURL = url
        emitQueueChanged()
    }

    public func stopCurrent() {
        stopCurrentCallCount += 1
        pauseAndRequeueCurrent()
    }

    private func pauseAndRequeueCurrent() {
        if let current = currentURL {
            currentURL = nil
            pendingURLs.insert(current, at: 0)
        }
        isPaused = true
        emitQueueChanged()
    }

    /// Test helper: simulates the driver picking up the next pending item.
    public func startNext() {
        guard !pendingURLs.isEmpty else { return }
        currentURL = pendingURLs.removeFirst()
        emitQueueChanged()
    }

    /// Test helper: fires ``onProgress`` with `progress`, as a background task would.
    public func emit(_ progress: KaraokePrewarmProgress) {
        onProgress?(progress)
    }

    /// Test helper: fires ``onFinished`` for `url`, as a completed render would; clears
    /// `currentURL` (firing the queue seam) when it is the in-flight item.
    public func finish(_ url: URL, result: KaraokeRenderResult) {
        if currentURL == url {
            currentURL = nil
            emitQueueChanged()
        }
        onFinished?(url, result)
    }

    private func emitQueueChanged() {
        onQueueChanged?(KaraokeQueueSnapshot(
            currentURL: currentURL,
            pendingURLs: pendingURLs,
            isPaused: isPaused
        ))
    }
}
