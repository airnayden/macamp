// LibraryToolboxProposalTests+Criteria — the CRITERIA half of `propose_playlist`,
// where the app rather than the model picks the tracks.
//
// An extension of the same suite rather than a suite of its own: the two halves
// are one tool's contract and the QA lane filters by that one type name. The split
// is SwiftLint's `file_length`, nothing else.
import Foundation
import Persistence
@testable import Services
import Testing

extension LibraryToolboxProposalTests {
    @Test("a genre plus a target materialises exactly that many ids, and repeats identically")
    func genreCriteriaMaterialisesTheTarget() async throws {
        let database = try ToolboxFixtures.makeLibrary(seedingGenre: "Rock", present: 160)
        let filer = FakeToolboxProposalFiler()
        let toolbox = ToolboxFixtures.makeToolbox(database, filer: filer)
        let arguments = ToolArguments([
            "name": .string("Rock Block"),
            "genre": .string("rock"),
            "target_count": .int(150),
        ])

        _ = try await toolbox.execute("propose_playlist", arguments: arguments)
        _ = try await toolbox.execute("propose_playlist", arguments: arguments)

        let filed = await filer.filed
        #expect(filed.count == 2)
        // Title-ordered and present-only, so the membership is writable in advance
        // rather than merely countable. "rock" also proves the match is NOCASE.
        #expect(filed.first?.trackIds == Array(ToolboxFixtures.genreTrackIDs(present: 160).prefix(150)))
        #expect(filed.first?.trackIds == filed.last?.trackIds)
    }

    /// The genre path passes the caller's own limit to the materialiser, NOT
    /// ``ToolResultBudget/fetchLimit`` — which `sample_tracks` does pass, and which
    /// would silently cap a long playlist at 200 with nothing to show for it.
    @Test("a 260-track materialisation is not silently clamped at the 200-row fetch cap")
    func materialisationIsNotClampedByTheFetchLimit() async throws {
        let database = try ToolboxFixtures.makeLibrary(seedingGenre: "Rock", present: 300)
        let filer = FakeToolboxProposalFiler()
        let toolbox = ToolboxFixtures.makeToolbox(database, filer: filer)

        _ = try await toolbox.execute("propose_playlist", arguments: ToolArguments([
            "name": .string("The Long Rock"),
            "genre": .string("rock"),
            "target_count": .int(260),
        ]))

        #expect(ToolResultBudget.fetchLimit == 200, "the cap this case exists to outrun")
        let filed = await filer.filed
        #expect(filed.first?.trackIds.count == 260)
    }

    @Test("a genre short of the target is filed anyway, with both numbers echoed")
    func genreShortfallIsFiledAndEchoed() async throws {
        let database = try ToolboxFixtures.makeLibrary(seedingGenre: "Rock", present: 160)
        let filer = FakeToolboxProposalFiler()
        let toolbox = ToolboxFixtures.makeToolbox(database, filer: filer)

        let result = try await toolbox.execute("propose_playlist", arguments: ToolArguments([
            "name": .string("Everything Rock"),
            "genre": .string("rock"),
            "target_count": .int(500),
        ]))

        #expect(result.summary == """
        Filed "Everything Rock" (160 tracks) for the listener to review. Nothing has been saved yet. \
        The listener asked for 500 tracks but this proposal has 160. \
        Add more tracks and propose again, or tell the listener why not.
        """)
        let filed = await filer.filed
        #expect(filed.first?.trackIds.count == 160)
    }

    @Test("a genre nothing carries files NOTHING and says so")
    func anUnmatchedGenreFilesNothing() async throws {
        let database = try ToolboxFixtures.makeLibrary()
        let filer = FakeToolboxProposalFiler()
        let toolbox = ToolboxFixtures.makeToolbox(database, filer: filer)

        let rendered = await toolbox.run("propose_playlist", arguments: ToolArguments([
            "name": .string("Nothing Here"),
            "genre": .string("no-such"),
        ]), profile: .cloud)

        #expect(rendered == """
        No playable tracks are tagged "no-such". Call list_genres for this library's own spellings.
        """)
        let filed = await filer.filed
        #expect(filed.isEmpty)
    }

    /// Track 6 IS tagged Rock, and is present — but it lives under the OTHER
    /// profile's library root. A materialisation that dropped `LibraryVisibility`
    /// would file it.
    @Test("a genre only another profile carries is no match at all")
    func anotherProfilesGenreIsNotVisible() async throws {
        let database = try ToolboxFixtures.makeLibrary()
        let filer = FakeToolboxProposalFiler()
        let toolbox = ToolboxFixtures.makeToolbox(database, filer: filer)

        let rendered = await toolbox.run("propose_playlist", arguments: ToolArguments([
            "name": .string("Borrowed"),
            "genre": .string("Rock"),
        ]), profile: .cloud)

        #expect(rendered.hasPrefix("No playable tracks are tagged"))
        let filed = await filer.filed
        #expect(filed.isEmpty)
    }

    @Test("a call with neither ids nor criteria names both forms rather than one")
    func neitherIdsNorCriteriaIsRefused() async throws {
        let database = try ToolboxFixtures.makeLibrary()
        let filer = FakeToolboxProposalFiler()
        let toolbox = ToolboxFixtures.makeToolbox(database, filer: filer)
        // An EMPTY list is the second spelling of "no ids": a model filling every
        // declared property pads the unused one, exactly as it pads a string.
        let incomplete = [
            ToolArguments(["name": .string("Empty")]),
            ToolArguments(["name": .string("Empty"), "track_ids": .array([])]),
        ]

        for arguments in incomplete {
            let rendered = await toolbox.run("propose_playlist", arguments: arguments, profile: .cloud)
            #expect(rendered == "At least one of these arguments is required: track_ids, genre.")
        }

        let filed = await filer.filed
        #expect(filed.isEmpty)
    }

    @Test("materialisation is present-only: missing and offline tracks never reach the offer")
    func materialisationExcludesUnplayableTracks() async throws {
        let database = try ToolboxFixtures.makeLibrary(seedingGenre: "Rock", present: 5, unavailable: 3)
        let filer = FakeToolboxProposalFiler()
        let toolbox = ToolboxFixtures.makeToolbox(database, filer: filer)

        _ = try await toolbox.execute("propose_playlist", arguments: ToolArguments([
            "name": .string("Only What Plays"),
            "genre": .string("rock"),
            "target_count": .int(100),
        ]))

        let filed = await filer.filed
        #expect(filed.first?.trackIds == ToolboxFixtures.genreTrackIDs(present: 5))
    }

    @Test("a genre made of quotes, CJK and emoji is matched, not interpolated into SQL")
    func hostileGenreTextIsBoundNotInterpolated() async throws {
        let hostile = "🎸 ロック \"; DROP TABLE track; --"
        let database = try ToolboxFixtures.makeLibrary(seedingGenre: hostile, present: 3)
        let filer = FakeToolboxProposalFiler()
        let toolbox = ToolboxFixtures.makeToolbox(database, filer: filer)

        _ = try await toolbox.execute("propose_playlist", arguments: ToolArguments([
            "name": .string("Hostile"),
            "genre": .string(hostile),
        ]))
        let rendered = await toolbox.run("propose_playlist", arguments: ToolArguments([
            "name": .string("Hostile Miss"),
            "genre": .string("'; DELETE FROM track WHERE 1=1; --"),
        ]), profile: .cloud)

        let filed = await filer.filed
        #expect(filed.count == 1)
        #expect(filed.first?.trackIds == ToolboxFixtures.genreTrackIDs(present: 3))
        #expect(rendered.hasPrefix("No playable tracks are tagged"))
        try #expect(ToolboxFixtures.playlistNames(database) == ["Evening Set", "Not Yours"])
    }

    @Test("only the name is required now that criteria can stand in for ids")
    func onlyTheNameIsRequired() throws {
        let toolbox = try ToolboxFixtures.makeToolbox(ToolboxFixtures.makeLibrary())
        let tool = try #require(toolbox.tool(named: "propose_playlist"))
        let root = try #require(tool.parametersSchema.objectValue)
        let properties = try #require(root["properties"]?.objectValue)

        #expect(root["required"]?.arrayValue?.compactMap(\.stringValue) == ["name"])
        #expect(properties["genre"]?.objectValue?["type"]?.stringValue == "string")
        #expect(properties["track_ids"]?.objectValue?["maxItems"]?.numberValue
            == Double(ToolResultBudget.proposalIdentifierLimit))
    }
}
