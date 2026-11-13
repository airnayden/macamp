// PlayEventCompactionTriggerTests — proof that the shells' launch hook is not a
// dead seam.
//
// A compactor nobody calls is indistinguishable from no compactor at all, and the
// symptom (history that quietly grows forever) would take two years to notice. These
// tests pin the one behaviour the composition roots depend on: `start()` really does
// reach a `PlayEventCompacting`, exactly once per launch, off the main actor.
import Foundation
import PlayerCoreTestSupport
@testable import Services
import Testing

private struct CompactionFailure: Error {}

@Suite("PlayEventCompactionTrigger — the launch/idle driver")
@MainActor
struct PlayEventCompactionTriggerTests {
    private func makeTrigger(_ compactor: FakePlayEventCompactor) -> PlayEventCompactionTrigger {
        PlayEventCompactionTrigger(compactor: compactor, startDelay: .zero)
    }

    @Test("start() actually reaches the compactor")
    func startInvokesTheCompactor() async {
        let compactor = FakePlayEventCompactor()
        let trigger = makeTrigger(compactor)

        trigger.start()
        await trigger.waitForCompletion()

        let count = await compactor.compactCallCount
        #expect(count == 1)
        #expect(trigger.hasStarted)
    }

    @Test("nothing runs until start() is called")
    func nothingRunsBeforeStart() async {
        let compactor = FakePlayEventCompactor()
        let trigger = makeTrigger(compactor)

        await trigger.waitForCompletion()

        let count = await compactor.compactCallCount
        #expect(count == 0)
        #expect(!trigger.hasStarted)
    }

    @Test("start() latches, so a repeatedly-fired composition hook still runs one pass")
    func startIsIdempotent() async {
        let compactor = FakePlayEventCompactor()
        let trigger = makeTrigger(compactor)

        trigger.start()
        trigger.start()
        trigger.start()
        await trigger.waitForCompletion()

        let count = await compactor.compactCallCount
        #expect(count == 1)
    }

    @Test("a throwing pass is absorbed — a failed compaction never surfaces at launch")
    func failingPassIsAbsorbed() async {
        let compactor = FakePlayEventCompactor()
        await compactor.setFailure(CompactionFailure())
        let trigger = makeTrigger(compactor)

        trigger.start()
        await trigger.waitForCompletion()

        let count = await compactor.compactCallCount
        #expect(count == 1)
    }

    @Test("cancel() before the delay elapses runs no pass")
    func cancelPreventsThePass() async {
        let compactor = FakePlayEventCompactor()
        let trigger = PlayEventCompactionTrigger(compactor: compactor, startDelay: .seconds(30))

        trigger.start()
        trigger.cancel()
        await trigger.waitForCompletion()

        let count = await compactor.compactCallCount
        #expect(count == 0)
    }
}
