// LibraryChatAppendTargetCompositionTests — the read recorder, and the fact that the
// composed toolbox really reaches it.
//
// A view-model test can prove the precedence rule over a fake drain; it cannot prove
// that the shell installed a recorder at all, or that `get_playlist` running through
// the REAL registry over REAL repositories lands in the one the chat view model
// drains. Those are composition claims, so they are made here — the same split
// `LibraryChatCorrectiveWiringTests` records for the corrective flag.
//
// A NEW FILE rather than more cases on `LibraryChatCompositionTests`: that suite sits
// at SwiftLint's `type_body_length` ceiling already, and a `*Tests.swift` per
// composition claim is this target's own convention.
//
// Nothing here reaches a provider, the Keychain or the network.
import Foundation
@testable import MacAMP
import Persistence
import Services
import Testing
import ViewModels

@Suite("Library chat append-target composition", .serialized)
@MainActor
struct LibraryChatAppendTargetCompositionTests {
    // MARK: The recorder's own contract

    @Test("the recorder records every report in call order, and drain clears it")
    func theRecorderDrainsOncePerRead() async {
        let recorder = LibraryChatPlaylistContextRecorder()

        await recorder.playlistWasRead(id: 5, profileId: 1)
        await recorder.playlistWasRead(id: 9, profileId: 77)

        let drained = recorder.drain()
        #expect(drained.map(\.playlistId) == [5, 9])
        #expect(drained.map(\.profileId) == [1, 77])
        // Drained once and never again — the same contract the proposal filer holds,
        // and what stops a read reaching the turn after the one that caused it.
        #expect(recorder.drain().isEmpty)
    }

    // MARK: The wiring

    @Test("the toolbox the shell composes for chat really carries a read observer")
    func theChatToolboxCarriesAnObserver() throws {
        let database = try AppDatabase.makeEmpty()
        let recorder = LibraryChatPlaylistContextRecorder()
        let observed = AppEnvironment.makeLibraryToolbox(
            database: database,
            profileId: ProfileRecord.guestID,
            proposals: LibraryChatProposalFiler(store: ProposalStore()),
            playlistReads: recorder
        )
        let unobserved = AppEnvironment.makeLibraryToolbox(
            database: database,
            profileId: ProfileRecord.guestID,
            proposals: LibraryChatProposalFiler(store: ProposalStore())
        )

        #expect(observed.context.playlistReadObserver != nil)
        // Defaulted to none, so the MCP composition keeps exactly the toolbox it
        // built before this seam existed.
        #expect(unobserved.context.playlistReadObserver == nil)
        // Installing one gates nothing: the published registry is the same either way.
        #expect(observed.allTools.map(\.name) == unobserved.allTools.map(\.name))
    }

    @Test("get_playlist through the REAL composed toolbox lands in the recorder the chat drains")
    func aRealPlaylistReadReachesTheRecorder() async throws {
        let database = try AppDatabase.makeEmpty()
        let playlist = try await PlaylistRepository(database)
            .create(named: "Evening Set", profileId: ProfileRecord.guestID)
        let playlistId = try #require(playlist.id)
        let recorder = LibraryChatPlaylistContextRecorder()
        let toolbox = AppEnvironment.makeLibraryToolbox(
            database: database,
            profileId: ProfileRecord.guestID,
            proposals: LibraryChatProposalFiler(store: ProposalStore()),
            playlistReads: recorder
        )

        _ = try await toolbox.execute(
            "get_playlist",
            arguments: ToolArguments(["playlist_id": .int(playlistId)])
        )

        let drained = recorder.drain()
        #expect(drained.count == 1)
        #expect(drained.first?.playlistId == playlistId)
        #expect(drained.first?.profileId == ProfileRecord.guestID)
    }

    @Test("a playlist id the profile cannot see reports NOTHING to the recorder")
    func aRefusedReadReachesNobody() async throws {
        let database = try AppDatabase.makeEmpty()
        let recorder = LibraryChatPlaylistContextRecorder()
        let toolbox = AppEnvironment.makeLibraryToolbox(
            database: database,
            profileId: ProfileRecord.guestID,
            proposals: LibraryChatProposalFiler(store: ProposalStore()),
            playlistReads: recorder
        )

        _ = await toolbox.run(
            "get_playlist",
            arguments: ToolArguments(["playlist_id": .int(4242)]),
            profile: .cloud
        )

        #expect(recorder.drain().isEmpty)
    }

    // MARK: The chat surface consumes it

    @Test("the AI graph still builds with the recorder wired into it, and starts naming nothing")
    func theGraphBuildsWithTheRecorderWired() {
        let environment = AppEnvironment.preview()
        environment.connectAI(settings: Self.settings(#function))

        // `makeLibraryChat` is where the recorder is minted, handed to the toolbox AND
        // handed to the view model's drain. Building the real graph is what proves all
        // three happened; before a turn has run it names nothing, as it must.
        #expect(environment.intelligence?.chat.isEmpty == true)
        #expect(environment.intelligence?.chat.messages.compactMap(\.appendTarget).isEmpty == true)
    }

    // MARK: Helpers

    private static let suitePrefix = "com.example.macamp.tests.libraryChatAppendTarget"

    private static func settings(_ function: String) -> AppSettings {
        let name = "\(suitePrefix).\(function)"
        guard let store = UserDefaults(suiteName: name) else { return AppSettings(defaults: .standard) }
        store.removePersistentDomain(forName: name)
        return AppSettings(defaults: store)
    }
}
