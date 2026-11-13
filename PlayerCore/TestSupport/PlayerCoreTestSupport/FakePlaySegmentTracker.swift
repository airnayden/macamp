import Foundation
import Services

/// A recording ``PlaySegmentTracking`` for shells and composition-level tests.
///
/// Writes nothing: it captures the calls so a caller can assert what the wiring
/// forwarded (that the track-start fan-out reached it, that seeks and signals
/// arrived, that a profile switch rescoped it, that the quit path awaited it).
/// ``onFlush`` is the barrier a termination test parks on — assign it to a closure
/// that blocks until the test releases it, and ``flushAndWait()`` will not return
/// until then.
@MainActor
public final class FakePlaySegmentTracker: PlaySegmentTracking {
    /// Every `(trackRef, profileId)` handed to ``beginTrack(trackRef:profileId:)``.
    public private(set) var begunTracks: [(track: TrackRef, profileId: Int64)] = []
    /// Every sample handed to ``ingest(sample:)``, in arrival order.
    public private(set) var samples: [PlayheadSample] = []
    /// Every `(from, to)` handed to ``noteSeek(from:to:)``, in arrival order.
    public private(set) var seeks: [(from: TimeInterval, target: TimeInterval)] = []
    /// Every playing/not-playing transition handed to ``playbackStateDidChange(isPlaying:)``.
    public private(set) var playbackStates: [Bool] = []
    /// Every signal handed to ``flush(signal:)``, in arrival order.
    public private(set) var signals: [PlayEventSignal] = []
    /// Every profile id handed to ``rescope(to:)``, in call order.
    public private(set) var rescopedProfileIds: [Int64] = []
    /// How many times ``flushAndWait()`` was entered.
    public private(set) var flushCount = 0
    /// Awaited inside ``flushAndWait()``. Use it to gate the quit path in a test.
    public var onFlush: (() async -> Void)?

    public init() {}

    public func beginTrack(trackRef: TrackRef, profileId: Int64) {
        begunTracks.append((trackRef, profileId))
    }

    public func ingest(sample: PlayheadSample) {
        samples.append(sample)
    }

    public func noteSeek(from origin: TimeInterval, to target: TimeInterval) {
        seeks.append((origin, target))
    }

    public func playbackStateDidChange(isPlaying: Bool) {
        playbackStates.append(isPlaying)
    }

    public func flush(signal: PlayEventSignal) {
        signals.append(signal)
    }

    public func rescope(to profileId: Int64) {
        rescopedProfileIds.append(profileId)
    }

    public func flushAndWait() async {
        flushCount += 1
        await onFlush?()
    }
}
