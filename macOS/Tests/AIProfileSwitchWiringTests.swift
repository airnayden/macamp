// AIProfileSwitchWiringTests — the AI graph really is re-seated on a profile switch.
//
// `AIGatingWiringTests` proves the shell declines to BUILD the graph when the master
// toggle is off. This suite proves the other half of the composition contract: that
// the graph the shell built for one listener never serves the next one.
//
// The switch is driven through the REAL seam — `ProfileService.switchTo` — rather than
// by poking `onActiveProfileChanged` directly, because the thing under test is the
// CHAINING. `wireProfileSwitch(environment:)` claims that single-owner slot from
// `init`, so an AI reseat that OVERWROTE it instead of chaining onto it would still
// pass a direct invocation while silently disabling every other switch effect in
// production.
//
// Two claims are separable and both matter:
//
//  * PROFILE-SCOPED state is REPLACED. A proposal is in-memory and belongs to the
//    listener who asked for it; the incoming profile must never inherit it.
//  * PROFILE-INDEPENDENT work SURVIVES. `trackAudioFeature` carries no `profileId`, so
//    an analysis pass reads the same files whoever is listening — ending it would throw
//    away real work for no reason. It is the one member the rescope carries across.
import Foundation
@testable import MacAMP
import Persistence
import Testing
import ViewModels

@Suite("AI profile-switch composition", .serialized)
@MainActor
struct AIProfileSwitchWiringTests {
    @Test("A profile switch re-seats the profile-scoped half of the graph")
    func switchingRescopesTheGraph() throws {
        let fixture = try Fixture()
        let before = try #require(fixture.environment.intelligence)

        try fixture.switchToSecondProfile()

        let after = try #require(fixture.environment.intelligence)
        #expect(after.assistant !== before.assistant)
        #expect(after.generatedPlaylists !== before.generatedPlaylists)
    }

    @Test("The incoming profile never sees the outgoing profile's proposals")
    func proposalsDoNotCrossProfiles() throws {
        let fixture = try Fixture()
        let before = try #require(fixture.environment.intelligence)
        before.proposals.add(Fixture.proposal(profileId: ProfileRecord.guestID))
        #expect(before.proposals.proposals.count == 1)

        try fixture.switchToSecondProfile()

        let after = try #require(fixture.environment.intelligence)
        #expect(after.proposals !== before.proposals)
        #expect(after.proposals.isEmpty)
        // The OUTGOING store is untouched — it is simply no longer reachable. Clearing
        // it would be a write the listener never asked for.
        #expect(before.proposals.proposals.count == 1)
    }

    @Test("The audio-analysis pass survives a profile switch")
    func theAnalysisPassSurvives() throws {
        let fixture = try Fixture()
        let before = try #require(fixture.environment.intelligence)

        try fixture.switchToSecondProfile()

        let after = try #require(fixture.environment.intelligence)
        // IDENTITY, not equality: a freshly built view model reports the same idle
        // state, so only the object itself distinguishes "carried over" from "rebuilt".
        #expect(after.audioAnalysis === before.audioAnalysis)
    }

    @Test("Switching with the master toggle off still builds nothing")
    func aSwitchDoesNotResurrectADisabledGraph() throws {
        let fixture = try Fixture(intelligenceEnabled: false)
        #expect(fixture.environment.intelligence == nil)

        try fixture.switchToSecondProfile()

        #expect(fixture.environment.intelligence == nil)
    }

    @Test("The reseat chains onto the switch orchestrator instead of replacing it")
    func theReseatChainsRatherThanReplaces() throws {
        let fixture = try Fixture()

        try fixture.switchToSecondProfile()

        // The orchestrator re-points every profile-owned reader; had `connectAI`
        // overwritten the slot rather than chaining onto it, none of this would move.
        #expect(fixture.environment.library.activeProfileId == fixture.secondProfileId)
        #expect(fixture.environment.search.activeProfileId == fixture.secondProfileId)
        #expect(fixture.environment.playlists.activeProfileId == fixture.secondProfileId)
    }

    // MARK: Fixture

    /// A `preview()` environment (empty in-memory database, fakes throughout) plus a
    /// second real profile to switch into.
    @MainActor
    private struct Fixture {
        let environment: AppEnvironment
        let settings: AppSettings
        let secondProfileId: Int64

        init(intelligenceEnabled: Bool = true, function: String = #function) throws {
            let name = "com.example.macamp.tests.aiswitch.\(function)"
            let store = UserDefaults(suiteName: name) ?? .standard
            store.removePersistentDomain(forName: name)
            settings = AppSettings(defaults: store)
            settings.intelligenceEnabled = intelligenceEnabled
            environment = AppEnvironment.preview()
            let created = try environment.profileService.create(ProfileRecord(name: "Second"))
            secondProfileId = try #require(created.id)
            environment.connectAI(settings: settings)
        }

        func switchToSecondProfile() throws {
            try environment.profileService.switchTo(profileId: secondProfileId, pin: nil)
        }

        /// The cheapest real proposal: a rename needs no draft and no repository.
        static func proposal(profileId: Int64) -> AIProposal {
            AIProposal(profileId: profileId, kind: .rename(playlistId: 1, name: "Renamed"))
        }
    }
}
