import Foundation
@testable import Services
import Testing

/// `list_playlists` and `get_playlist`, including the ownership check that stops a
/// model-supplied id reaching another profile's list.
@Suite("LibraryToolbox playlists")
struct LibraryToolboxPlaylistTests {
    @Test("only this profile's playlists are listed")
    func listsOwnPlaylistsOnly() async throws {
        let database = try ToolboxFixtures.makeLibrary()
        let toolbox = ToolboxFixtures.makeToolbox(database)
        let result = try await toolbox.execute("list_playlists")
        #expect(result.renderedText(profile: .cloud) == """
        1 playlist.
        #\(ToolboxFixtures.playlistID) Evening Set — 3 tracks
        """)
    }

    @Test("a profile with no playlists is told so")
    func emptyPlaylistList() async throws {
        let database = try ToolboxFixtures.makeLibrary()
        let toolbox = ToolboxFixtures.makeToolbox(database, profileId: 99)
        let result = try await toolbox.execute("list_playlists")
        #expect(result.renderedText(profile: .onDevice) == "This listener has no playlists yet.")
    }

    @Test("a playlist reads back in PLAYING order, not library order")
    func readsPlayingOrder() async throws {
        let database = try ToolboxFixtures.makeLibrary()
        let toolbox = ToolboxFixtures.makeToolbox(database)
        let result = try await toolbox.execute("get_playlist", arguments: ToolArguments([
            "playlist_id": .int(ToolboxFixtures.playlistID),
        ]))
        #expect(result.renderedText(profile: .cloud) == """
        "Evening Set" — 3 tracks.
        #3 Ember Waltz — Paper Lanterns · Slow Burn (1995)
        #1 Aurora Drift — Nova Field · Northern Lights (2001)
        #5 Golden Hour — Paper Lanterns · Slow Burn (2008)
        """)
    }

    @Test("the limit bounds the membership page")
    func limitBoundsThePage() async throws {
        let database = try ToolboxFixtures.makeLibrary()
        let toolbox = ToolboxFixtures.makeToolbox(database)
        let result = try await toolbox.execute("get_playlist", arguments: ToolArguments([
            "playlist_id": .int(ToolboxFixtures.playlistID),
            "limit": .int(1),
        ]))
        #expect(result.rows.map(\.text) == ["#3 Ember Waltz — Paper Lanterns · Slow Burn (1995)"])
    }

    @Test("another profile's playlist reads as not found, never as forbidden")
    func foreignPlaylistIsNotFound() async throws {
        let database = try ToolboxFixtures.makeLibrary()
        let toolbox = ToolboxFixtures.makeToolbox(database)
        await #expect(throws: LibraryToolError.notFound(
            what: "playlist",
            id: ToolboxFixtures.otherPlaylistID
        )) {
            try await toolbox.execute("get_playlist", arguments: ToolArguments([
                "playlist_id": .int(ToolboxFixtures.otherPlaylistID),
            ]))
        }
        let rendered = await toolbox.run("get_playlist", arguments: ToolArguments([
            "playlist_id": .int(ToolboxFixtures.otherPlaylistID),
        ]), profile: .cloud)
        #expect(rendered == "No playlist with id \(ToolboxFixtures.otherPlaylistID) is available to this listener.")
    }

    @Test("a playlist id that does not exist reads the same as one that is not yours")
    func unknownPlaylistIsIndistinguishable() async throws {
        let database = try ToolboxFixtures.makeLibrary()
        let toolbox = ToolboxFixtures.makeToolbox(database)
        let unknown = await toolbox.run("get_playlist", arguments: ToolArguments([
            "playlist_id": .int(4242),
        ]), profile: .cloud)
        #expect(unknown == "No playlist with id 4242 is available to this listener.")
    }

    @Test("a missing playlist id is refused before any read")
    func missingIdIsRefused() async throws {
        let database = try ToolboxFixtures.makeLibrary()
        let toolbox = ToolboxFixtures.makeToolbox(database)
        await #expect(throws: ToolArgumentError.missing(argument: "playlist_id")) {
            try await toolbox.execute("get_playlist")
        }
    }
}
