// ActiveTick — a playback-agnostic conditional ticker for SwiftUI views.
//
// `onActiveTick(isActive:every:_:)` runs a `Timer.publish` cadence ONLY while
// `isActive` is true and tears it down when false, so a view that merely needs to
// refresh a displayed value while *something* is active (e.g. playback) spends
// ≈0% CPU when idle instead of waking the run loop forever. On the active→inactive
// edge it delivers exactly ONE final "flush" tick, so a value driven by the ticker
// (an elapsed-time read-out, a lyric-line highlight) lands on its final value.
//
// The enable/flush decision is factored into `TickPolicy` — a pure, SwiftUI-free
// type — so it can be unit-tested with no SwiftUI host and no wall-clock timing.
// DesignSystem stays playback-agnostic: no player types cross this seam, only a
// `Bool` (is-active) and a closure. Callers pass their own `isActive` source.
import Combine
import SwiftUI

/// Pure, SwiftUI-free decision logic for a conditional ticker.
///
/// A caseless-enum namespace (SwiftUI-free) so the enable/flush rules can be
/// unit-tested directly — no SwiftUI host, no timing. The modifier is a thin
/// wrapper over it.
public enum TickPolicy {
    /// Whether the periodic ticker should be running for a given active state.
    public static func shouldRun(isActive: Bool) -> Bool {
        isActive
    }

    /// Whether a single "flush" tick should be delivered as the active state
    /// changes — `true` ONLY for the active→inactive (`true`→`false`) edge, so a
    /// ticker-driven display settles on its final value when activity stops.
    public static func shouldFlush(from oldValue: Bool, to newValue: Bool) -> Bool {
        oldValue && !newValue
    }
}

public extension View {
    /// Runs `action` every `interval` seconds ONLY while `isActive` is true.
    ///
    /// The underlying `Timer.publish(...).autoconnect()` subscription exists only
    /// while `isActive == true` and is torn down when it becomes false, so an idle
    /// view does no periodic work. Exactly one final tick is delivered on the
    /// active→inactive edge (see ``TickPolicy/shouldFlush(from:to:)``) so a value
    /// driven by `action` settles on its final value.
    ///
    /// Playback-agnostic by design: the caller supplies its own `isActive` source.
    func onActiveTick(
        isActive: Bool,
        every interval: TimeInterval,
        _ action: @escaping () -> Void
    ) -> some View {
        modifier(ActiveTickModifier(isActive: isActive, interval: interval, action: action))
    }
}

/// Drives a `Timer.publish` cadence only while active, per ``TickPolicy``.
private struct ActiveTickModifier: ViewModifier {
    let isActive: Bool
    let interval: TimeInterval
    let action: () -> Void

    @State private var cancellable: AnyCancellable?

    func body(content: Content) -> some View {
        content
            .onAppear { sync(from: false, to: isActive) }
            .onChange(of: isActive) { oldValue, newValue in
                sync(from: oldValue, to: newValue)
            }
            .onDisappear(perform: teardown)
    }

    /// Applies the ``TickPolicy`` decision for one active-state edge.
    private func sync(from oldValue: Bool, to newValue: Bool) {
        if TickPolicy.shouldRun(isActive: newValue) {
            start()
        } else {
            teardown()
            if TickPolicy.shouldFlush(from: oldValue, to: newValue) {
                action()
            }
        }
    }

    private func start() {
        guard cancellable == nil else { return }
        cancellable = Timer.publish(every: interval, on: .main, in: .common)
            .autoconnect()
            .sink { _ in action() }
    }

    private func teardown() {
        cancellable?.cancel()
        cancellable = nil
    }
}
