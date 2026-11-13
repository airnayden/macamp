import Foundation
import Services

/// A recording ``PlayEventRecording`` for shells and composition-level tests.
///
/// Writes nothing: it captures the calls so a caller can assert what the wiring
/// forwarded (which signals arrived, whether the profile-switch rescope ran, that
/// the quit path awaited a flush). ``onFlush`` is the barrier the termination
/// tests park on — assign it to a closure that blocks until the test releases it,
/// and ``flushAndWait()`` will not return until then.
@MainActor
public final class FakePlayEventRecorder: PlayEventRecording {
    /// Every signal handed to ``record(_:)``, in arrival order.
    public private(set) var signals: [PlayEventSignal] = []
    /// How many times ``trackDidStart()`` fired.
    public private(set) var trackStartCount = 0
    /// Every profile id handed to ``rescope(to:)``, in call order.
    public private(set) var rescopedProfileIds: [Int64] = []
    /// How many times ``flushAndWait()`` was entered.
    public private(set) var flushCount = 0
    /// Awaited inside ``flushAndWait()``. Use it to gate the quit path in a test.
    public var onFlush: (() async -> Void)?

    public init() {}

    public func trackDidStart() {
        trackStartCount += 1
    }

    public func record(_ signal: PlayEventSignal) {
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
