// Locks the pure enable/flush decision logic of the conditional ticker (Task 6).
//
// `TickPolicy` is deliberately a SwiftUI-free namespace so its truth table can be
// asserted directly — no SwiftUI host, no `Timer`, no wall-clock timing. The
// `ActiveTickModifier` is a thin wrapper over these two functions; locking the
// policy here locks the behaviour every gated timer site depends on.
import DesignSystem
import Testing

@Suite("TickPolicyTests")
struct TickPolicyTests {
    @Test("shouldRun mirrors the active flag")
    func shouldRunMirrorsActiveFlag() {
        #expect(TickPolicy.shouldRun(isActive: true) == true)
        #expect(TickPolicy.shouldRun(isActive: false) == false)
    }

    @Test("shouldFlush fires ONLY on the active→inactive edge (all 4 combinations)")
    func shouldFlushOnlyOnDeactivateEdge() {
        // The one edge that flushes: was active, now inactive.
        #expect(TickPolicy.shouldFlush(from: true, to: false) == true)
        // Every other transition must NOT flush.
        #expect(TickPolicy.shouldFlush(from: false, to: true) == false)
        #expect(TickPolicy.shouldFlush(from: true, to: true) == false)
        #expect(TickPolicy.shouldFlush(from: false, to: false) == false)
    }
}
