import Foundation
import Services

/// A ``LyricsSweeping`` that records its control calls and never touches the
/// database, the filesystem, or the network.
@MainActor
public final class FakeLyricsSweeper: LyricsSweeping {
    public var onDidCacheLyrics: (@Sendable () -> Void)?

    /// How many times ``start()`` was called (the composition root must call it once).
    public private(set) var startCount = 0
    /// How many times ``cancel()`` was called.
    public private(set) var cancelCount = 0

    public init() {}

    /// Fires the wired signal, standing in for a pass that cached a document.
    public func emitDidCacheLyrics() {
        onDidCacheLyrics?()
    }

    public func start() {
        startCount += 1
    }

    public func cancel() {
        cancelCount += 1
    }
}
