// PlayEventTransitionTests — queue-row removal and the load-failure cascade.
//
// The cascade is the reason emission is guarded by a CONSUMED flag rather than a
// per-site list: `activateManual`'s catch does not stop the engine, so the
// automatic advance it triggers reaches `activate`'s own emit point while the
// outgoing track is still rendering. Only a flag that survives the failure can
// keep that to one event.
import AudioEngine
import Foundation
@testable import Services
import Testing

@MainActor
@Suite(.serialized)
struct PlayEventTransitionTests {
    @Test("(j) removing the CURRENT row with a successor emits one .jump")
    func removeCurrentWithSuccessor() throws {
        let harness = PlayEventHarness()
        harness.coordinator.setQueue([.fixture("a"), .fixture("b")], startingAt: 0)
        harness.coordinator.seek(to: 9)

        harness.coordinator.remove(at: 0)

        let signal = try #require(harness.events.signals.first)
        #expect(harness.events.reasons == [.jump])
        #expect(signal.title == "a")
        #expect(signal.elapsedSeconds == 9)
        #expect(harness.coordinator.current?.title == "b")
    }

    @Test("(j) removing the CURRENT row with no successor emits one .stopped")
    func removeCurrentWithoutSuccessor() throws {
        let harness = PlayEventHarness()
        harness.coordinator.setQueue([.fixture("only")], startingAt: 0)
        harness.coordinator.seek(to: 4)

        harness.coordinator.remove(at: 0)

        let signal = try #require(harness.events.signals.first)
        #expect(harness.events.reasons == [.stopped])
        #expect(signal.title == "only")
        #expect(signal.elapsedSeconds == 4)
        #expect(harness.coordinator.current == nil)
    }

    @Test("(j) removing a row that is not current emits nothing")
    func removeOtherRowIsSilent() {
        let harness = PlayEventHarness()
        harness.coordinator.setQueue([.fixture("a"), .fixture("b")], startingAt: 0)

        harness.coordinator.remove(at: 1)

        #expect(harness.events.signals.isEmpty)
    }

    @Test("(k)(o) a manual load failure cascading onto a successor emits exactly one event")
    func loadFailureCascadeEmitsOnce() throws {
        let harness = PlayEventHarness(allowFailingLoads: true)
        harness.coordinator.setQueue([.fixture("a"), .fixture("successor")], startingAt: 0)
        harness.coordinator.seek(to: 15)
        harness.coordinator.enqueueManual(PlayEventHarness.failingTrack("broken"))

        harness.coordinator.playManual(at: 0)

        let signal = try #require(harness.events.signals.first)
        #expect(harness.events.reasons == [.jump])
        #expect(signal.title == "a")
        #expect(signal.elapsedSeconds == 15)
        #expect(harness.coordinator.current?.title == "successor")
    }

    @Test("(k) a transition AFTER a cascade still emits — the flag is not latched")
    func transitionAfterCascadeStillEmits() {
        let harness = PlayEventHarness(allowFailingLoads: true)
        harness.coordinator.setQueue([.fixture("a"), .fixture("successor")], startingAt: 0)
        harness.coordinator.enqueueManual(PlayEventHarness.failingTrack("broken"))
        harness.coordinator.playManual(at: 0)

        harness.coordinator.seek(to: 8)
        harness.coordinator.stop()

        #expect(harness.events.reasons == [.jump, .stopped])
    }

    @Test("(k) a FULLY failed cascade terminates in a stop that resets the flag")
    func fullyFailedCascadeResetsAtTeardown() {
        let harness = PlayEventHarness(allowFailingLoads: true)
        harness.coordinator.setQueue(
            [.fixture("a"), PlayEventHarness.failingTrack("alsoBroken")],
            startingAt: 0
        )
        harness.coordinator.enqueueManual(PlayEventHarness.failingTrack("broken"))
        harness.coordinator.playManual(at: 0)
        #expect(harness.events.reasons == [.jump])
        #expect(harness.coordinator.state.playback == .stopped)

        harness.coordinator.setQueue([.fixture("later")], startingAt: 0)
        harness.coordinator.seek(to: 6)
        harness.coordinator.next()

        #expect(harness.events.reasons == [.jump, .userNext])
    }

    @Test("a natural end that advances onto a successor still emits exactly one event")
    func naturalEndAdvanceDoesNotDoubleEmit() {
        let harness = PlayEventHarness()
        harness.coordinator.setQueue([.fixture("a"), .fixture("b"), .fixture("c")], startingAt: 0)

        harness.coordinator.handleTrackDidFinish()
        harness.coordinator.handleTrackDidFinish()

        #expect(harness.events.reasons == [.natural, .natural])
        #expect(harness.coordinator.current?.title == "c")
    }
}
