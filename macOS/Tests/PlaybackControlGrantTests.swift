// PlaybackControlGrantTests — the two grants, their DEFAULTS, and the composition
// that reads them.
//
// The defaults are the whole point and they deliberately disagree: the in-app one
// ships ON, the external one ships OFF. That asymmetry is a decision someone will
// eventually try to "fix" for consistency, so it is asserted directly and with the
// reasoning attached — a listener typing "play it" into their own player has given
// the instruction, while an unnamed program on the machine has not.
//
// The keys are asserted too. Both live under the existing
// `com.example.macamp.settings.ai.` namespace, and a key that collided with a
// neighbour would silently make one switch move the other.
import Foundation
@testable import MacAMP
import Persistence
import Services
import Testing
import ViewModels

@Suite("Playback control grants")
@MainActor
struct PlaybackControlGrantTests {
    // MARK: The defaults

    @Test("a fresh install lets the in-app assistant control playback")
    func theInAppGrantDefaultsOn() {
        let settings = AppSettings(defaults: Self.store(named: "\(Self.suitePrefix).inApp"))
        #expect(settings.assistantPlaybackControlEnabled)
    }

    @Test("a fresh install does NOT let an external program control playback")
    func theExternalGrantDefaultsOff() {
        let settings = AppSettings(defaults: Self.store(named: "\(Self.suitePrefix).external"))
        #expect(!settings.externalAccessControlEnabled)
        #expect(!settings.externalAccessEnabled)
        #expect(!settings.externalAccessConsented)
    }

    @Test("each grant owns its own key and neither moves the other")
    func theGrantsAreIndependent() {
        let name = "\(Self.suitePrefix).independence"
        let store = Self.store(named: name)
        let settings = AppSettings(defaults: store)

        settings.assistantPlaybackControlEnabled = false
        settings.externalAccessControlEnabled = true

        let reloaded = AppSettings(defaults: store)
        #expect(!reloaded.assistantPlaybackControlEnabled)
        #expect(reloaded.externalAccessControlEnabled)
        // The neighbours in the same namespace are untouched.
        #expect(!reloaded.externalAccessEnabled)
        #expect(reloaded.intelligenceEnabled)
    }

    @Test("the stored keys are the documented ones")
    func theStoredKeysAreStable() {
        let name = "\(Self.suitePrefix).keys"
        let store = Self.store(named: name)
        let settings = AppSettings(defaults: store)
        settings.assistantPlaybackControlEnabled = false
        settings.externalAccessControlEnabled = true

        #expect(store.object(forKey: "com.example.macamp.settings.ai.assistant.playbackControlEnabled") as? Bool
            == false)
        #expect(store.object(forKey: "com.example.macamp.settings.ai.externalAccess.controlEnabled") as? Bool
            == true)
    }

    // MARK: The composition

    @Test("the chat toolbox publishes control tools only while the in-app grant is on")
    func theChatGrantDecidesTheChatRegistry() {
        let environment = AppEnvironment.preview()
        let filer = LibraryChatProposalFiler(store: ProposalStore())
        let granted = AppEnvironment.makeLibraryToolbox(
            database: environment.database,
            profileId: ProfileRecord.guestID,
            proposals: filer,
            playback: environment.playbackControl
        )
        let ungranted = AppEnvironment.makeLibraryToolbox(
            database: environment.database,
            profileId: ProfileRecord.guestID,
            proposals: filer
        )

        #expect(Set(granted.allTools.map(\.name)).isSuperset(of: Set(LibraryToolbox.controlToolNames)))
        #expect(Set(ungranted.allTools.map(\.name)).isDisjoint(with: Set(LibraryToolbox.controlToolNames)))
        #expect(granted.allTools.count == ungranted.allTools.count + LibraryToolbox.controlToolNames.count)
    }

    @Test("the in-app grant is graph SHAPE: flipping it rebuilds the chat")
    func flippingTheInAppGrantRebuildsTheGraph() async {
        let environment = AppEnvironment.preview()
        let settings = AppSettings(defaults: Self.store(named: "\(Self.suitePrefix).rebuild"))
        settings.intelligenceEnabled = true
        environment.connectAI(settings: settings)

        let before = environment.intelligence?.chat
        settings.assistantPlaybackControlEnabled = false
        // The rebuild hops through `withObservationTracking`'s main-actor task, the
        // same shape `AIGatingWiringTests` waits on for the master switch.
        await Task.yield()
        await Task.yield()

        let after = environment.intelligence?.chat
        #expect(before !== after, "the conversation must be rebuilt — FM attaches tools at init")
    }

    // MARK: The witness

    @Test("the witness reports an idle player without inventing a position")
    func theWitnessReportsAnIdlePlayer() async {
        let environment = AppEnvironment.preview()
        let snapshot = await environment.playbackControl.playbackSnapshot(upNextLimit: 10)
        #expect(snapshot.activity == .stopped)
        #expect(snapshot.current == nil)
        #expect(snapshot.upNext.isEmpty)
        #expect(snapshot.upNextTotal == 0)
    }

    @Test("a transport press reaches the real coordinator")
    func theWitnessDrivesTheCoordinator() async {
        let environment = AppEnvironment.preview()
        _ = await environment.playbackControl.perform(.pause)
        _ = await environment.playbackControl.perform(.stop)
        // The preview coordinator has an empty queue, so the observable outcome is
        // that it is still stopped and still answers — not a crash on an empty player.
        let snapshot = await environment.playbackControl.playbackSnapshot(upNextLimit: 10)
        #expect(snapshot.activity == .stopped)
    }

    // MARK: Helpers

    private static let suitePrefix = "com.example.macamp.tests.playbackControl"

    private static func store(named name: String) -> UserDefaults {
        guard let store = UserDefaults(suiteName: name) else { return .standard }
        store.removePersistentDomain(forName: name)
        return store
    }
}
