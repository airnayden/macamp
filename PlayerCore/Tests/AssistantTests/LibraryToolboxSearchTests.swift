import Foundation
@testable import Services
import Testing

/// `search_tracks` and `list_genres` over the real FTS5 index and the real
/// visibility predicate.
@Suite("LibraryToolbox search")
struct LibraryToolboxSearchTests {
    @Test("a search renders the matching track exactly")
    func searchesTheLibrary() async throws {
        let database = try ToolboxFixtures.makeLibrary()
        let toolbox = ToolboxFixtures.makeToolbox(database)
        let result = try await toolbox.execute("search_tracks", arguments: ToolArguments([
            "query": .string("Aurora"),
        ]))
        #expect(result.renderedText(profile: .cloud) == """
        1 track matching "Aurora".
        #1 Aurora Drift — Nova Field · Northern Lights (2001)
        """)
    }

    @Test("a search honours its limit")
    func honoursTheLimit() async throws {
        let database = try ToolboxFixtures.makeLibrary()
        let toolbox = ToolboxFixtures.makeToolbox(database)
        let result = try await toolbox.execute("search_tracks", arguments: ToolArguments([
            "query": .string("Fillerton"),
            "limit": .int(4),
        ]))
        #expect(result.rows.count == 4)
        #expect(result.summary == "4 tracks matching \"Fillerton\".")
    }

    @Test("a search that matches nothing says so instead of returning an empty list")
    func emptySearch() async throws {
        let database = try ToolboxFixtures.makeLibrary()
        let toolbox = ToolboxFixtures.makeToolbox(database)
        let result = try await toolbox.execute("search_tracks", arguments: ToolArguments([
            "query": .string("Zeppelin"),
        ]))
        #expect(result.rows.isEmpty)
        #expect(result.renderedText(profile: .onDevice) == "No tracks match \"Zeppelin\".")
    }

    @Test("another profile's track is invisible, even by exact title")
    func visibilityScopesTheSearch() async throws {
        let database = try ToolboxFixtures.makeLibrary()
        let mine = ToolboxFixtures.makeToolbox(database)
        let theirs = ToolboxFixtures.makeToolbox(database, profileId: ToolboxFixtures.otherProfileID)

        let hiddenFromMe = try await mine.execute("search_tracks", arguments: ToolArguments([
            "query": .string("Hidden"),
        ]))
        let visibleToThem = try await theirs.execute("search_tracks", arguments: ToolArguments([
            "query": .string("Hidden"),
        ]))

        #expect(hiddenFromMe.rows.isEmpty)
        #expect(visibleToThem.rows.count == 1)
    }

    @Test("a missing query is refused with the model-actionable sentence")
    func missingQueryIsRefused() async throws {
        let database = try ToolboxFixtures.makeLibrary()
        let toolbox = ToolboxFixtures.makeToolbox(database)
        await #expect(throws: ToolArgumentError.missing(argument: "query")) {
            try await toolbox.execute("search_tracks")
        }
        let rendered = await toolbox.run("search_tracks", profile: .onDevice)
        #expect(rendered == "Argument \"query\" is required.")
    }

    @Test("an out-of-range limit is refused before the database is touched")
    func outOfRangeLimitIsRefused() async throws {
        let database = try ToolboxFixtures.makeLibrary()
        let toolbox = ToolboxFixtures.makeToolbox(database)
        let rendered = await toolbox.run("search_tracks", arguments: ToolArguments([
            "query": .string("Aurora"),
            "limit": .int(10000),
        ]), profile: .cloud)
        #expect(rendered == "Argument \"limit\" must be between 1 and \(ToolResultBudget.fetchLimit).")
    }

    @Test("more rows than the tier renders are dropped and counted")
    func capEnforcementTruncates() async throws {
        let database = try ToolboxFixtures.makeLibrary()
        let toolbox = ToolboxFixtures.makeToolbox(database)
        let result = try await toolbox.execute("search_tracks", arguments: ToolArguments([
            "query": .string("Fillerton"),
        ]))
        #expect(result.rows.count == LibraryToolbox.defaultSearchLimit)

        let rendered = result.renderedText(profile: .onDevice)
        let lines = rendered.split(separator: "\n").map(String.init)
        #expect(rendered.count <= ToolProfile.onDevice.characterLimit)
        #expect(rendered.contains("more — refine your query"))
        #expect(lines.count <= 2 + ToolResultBudget.onDeviceRowLimit)

        let full = result.renderedText(profile: .cloud)
        #expect(!full.contains("more — refine your query"))
    }
}

// MARK: - Genres

@Suite("LibraryToolbox genres")
struct LibraryToolboxGenreTests {
    @Test("genres render busiest first, with the untagged bucket named")
    func listsGenresWithCounts() async throws {
        let database = try ToolboxFixtures.makeLibrary()
        let toolbox = ToolboxFixtures.makeToolbox(database)
        let result = try await toolbox.execute("list_genres")
        #expect(result.renderedText(profile: .cloud) == """
        4 genres in this listener's library.
        Filler — \(ToolboxFixtures.fillerCount) tracks
        Electronic — 2 tracks
        (no genre) — 1 track
        Ambient — 1 track
        Jazz — 1 track
        """)
    }

    @Test("the other profile sees only the genre it owns")
    func genresAreProfileScoped() async throws {
        let database = try ToolboxFixtures.makeLibrary()
        let toolbox = ToolboxFixtures.makeToolbox(database, profileId: ToolboxFixtures.otherProfileID)
        let result = try await toolbox.execute("list_genres")
        let names = result.rows.compactMap { $0.payload.objectValue?["genre"]?.stringValue }
        #expect(names.contains("Rock"))
    }

    @Test("list_genres takes no arguments and ignores any that are sent")
    func genresTakeNoArguments() async throws {
        let database = try ToolboxFixtures.makeLibrary()
        let toolbox = ToolboxFixtures.makeToolbox(database)
        let bare = try await toolbox.execute("list_genres")
        let noisy = try await toolbox.execute("list_genres", arguments: ToolArguments(["junk": .bool(true)]))
        #expect(bare.renderedText(profile: .cloud) == noisy.renderedText(profile: .cloud))
    }
}
