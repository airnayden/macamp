import Foundation
@testable import Services
import Testing

/// `ToolResult.resultCount` — the one number a shell may draw beside a lookup.
///
/// Two properties matter and both are asserted here rather than downstream:
/// the count is PRE-truncation (it survives a tier dropping rows), and it is
/// ABSENT rather than zero for an answer that is not a list.
@Suite("ToolResult result count")
struct ToolResultCountTests {
    // MARK: - The value type

    @Test("a result reports no count unless its tool states one")
    func absentByDefault() {
        let rows = [ToolResultRow(text: "a"), ToolResultRow(text: "b")]
        #expect(ToolResult(summary: "s", rows: rows).resultCount == nil)
        #expect(ToolResult.message("refused").resultCount == nil)
        #expect(ToolResult(summary: "s", rows: rows, resultCount: 2).resultCount == 2)
    }

    @Test("a stated count is clamped up to the rows it was given")
    func clampedToRowCount() {
        // Same reasoning as `totalCount`: under-reporting the rows the caller can
        // already see would be a figure the result itself contradicts.
        let rows = [ToolResultRow(text: "a"), ToolResultRow(text: "b"), ToolResultRow(text: "c")]
        #expect(ToolResult(summary: "s", rows: rows, resultCount: 1).resultCount == 3)
        #expect(ToolResult(summary: "s", resultCount: 0).resultCount == 0)
    }

    @Test("the count is not smuggled into the machine payload")
    func payloadShapeIsUnchanged() {
        // The payload is a WIRE shape an external MCP client reads. `resultCount`
        // is a shell affordance and duplicates `totalCount` whenever it is set, so
        // adding a key would widen a published contract for nothing.
        let result = ToolResult(summary: "s", rows: [ToolResultRow(text: "a")], resultCount: 9)
        let keys = result.payload.objectValue?.keys.sorted()
        #expect(keys == ["rows", "summary", "totalCount"])
    }

    // MARK: - The registry

    /// Which of the ten library tools answer with a count, and which cannot. Kept
    /// exhaustive by ``everyToolIsClassified`` — a new tool with no entry fails.
    static let listShaped: Set<String> = [
        "search_tracks",
        "list_genres",
        "get_tracks",
        "get_track_features",
        "list_playlists",
        "get_playlist",
        "sample_tracks",
        "match_tracks",
    ]

    /// A digest is not a list of results and a filed proposal is one offer, so
    /// "N results" would be a category error rather than a missing feature.
    ///
    /// Every CONTROL tool joins them for the same reason: a transport press is not
    /// a lookup, and the queue rows a playback report carries are a preview of
    /// what is about to happen — labelling them "3 results" would report the
    /// length of someone's queue as the size of a search.
    static let countless: Set<String> = [
        "get_listening_stats",
        "propose_playlist",
        "get_playback_state",
        "play_tracks",
        "queue_tracks",
        "transport",
    ]

    @Test("every registered tool is classified as list-shaped or not")
    func everyToolIsClassified() throws {
        let (toolbox, _) = try ToolboxFixtures.makeControllableToolbox(ToolboxFixtures.makeLibrary())
        #expect(Self.listShaped.union(Self.countless) == Set(toolbox.allTools.map(\.name)))
        #expect(Self.listShaped.isDisjoint(with: Self.countless))
    }

    @Test("each tool reports a count exactly when its answer is a list")
    func countsMatchTheClassification() async throws {
        let (toolbox, _) = try ToolboxFixtures.makeControllableToolbox(ToolboxFixtures.makeLibrary())
        for call in LibraryToolboxPrivacyTests.calls {
            let result = try await toolbox.execute(call.name, arguments: ToolArguments(call.arguments))
            if Self.listShaped.contains(call.name) {
                #expect(result.resultCount == result.rows.count, "\(call.name) miscounted its rows")
            } else {
                #expect(result.resultCount == nil, "\(call.name) reported a count it cannot mean")
            }
        }
    }

    @Test("an empty lookup reports zero, not nothing")
    func emptyLookupsReportZero() async throws {
        // "Searched your library — 0 results" is a fact about a lookup that ran.
        // `nil` there would be indistinguishable from a tool that cannot count.
        let toolbox = try ToolboxFixtures.makeToolbox(ToolboxFixtures.makeLibrary())
        let search = try await toolbox.execute(
            "search_tracks",
            arguments: ToolArguments(["query": .string("zzzznothingmatches")])
        )
        #expect(search.rows.isEmpty)
        #expect(search.resultCount == 0)

        let sample = try await toolbox.execute(
            "sample_tracks",
            arguments: ToolArguments(["genre": .string("Polka")])
        )
        #expect(sample.rows.isEmpty)
        #expect(sample.resultCount == 0)
    }

    // MARK: - Pre-truncation

    @Test("the count survives every tier's row budget, because it is taken before rendering")
    func countIsPreTruncation() async throws {
        // The fixture seeds `fillerCount` (30) rows sharing one token, and
        // `search_tracks` fetches `defaultSearchLimit` (20) of them. `.onDevice`
        // then renders far fewer, so a count recovered from the rendered text
        // would say something different at every tier. This one does not.
        let toolbox = try ToolboxFixtures.makeToolbox(ToolboxFixtures.makeLibrary())
        let result = try await toolbox.execute(
            "search_tracks",
            arguments: ToolArguments(["query": .string("Fillerton")])
        )

        #expect(ToolboxFixtures.fillerCount > LibraryToolbox.defaultSearchLimit)
        #expect(result.rows.count == LibraryToolbox.defaultSearchLimit)
        #expect(result.resultCount == LibraryToolbox.defaultSearchLimit)

        let onDevice = result.renderedText(profile: .onDevice)
        let renderedRows = onDevice.split(separator: "\n").count
        #expect(renderedRows < result.rows.count, "the on-device budget must drop rows for this to prove anything")
        #expect(onDevice.contains("more — refine your query"))
    }

    @Test("an explicit limit above the on-device budget still reports what was found")
    func explicitLimitIsReportedHonestly() async throws {
        let toolbox = try ToolboxFixtures.makeToolbox(ToolboxFixtures.makeLibrary())
        let result = try await toolbox.execute("search_tracks", arguments: ToolArguments([
            "query": .string("Fillerton"),
            "limit": .int(25),
        ]))
        #expect(result.rows.count == 25)
        #expect(result.resultCount == 25)
        #expect(result.renderedText(profile: .onDevice).count <= ToolProfile.onDevice.characterLimit)
    }

    // MARK: - The run seam

    @Test("runResult carries the count and run still answers byte-identical text")
    func runSeamIsUnchangedApartFromTheCount() async throws {
        let toolbox = try ToolboxFixtures.makeToolbox(ToolboxFixtures.makeLibrary())
        for profile in ToolProfile.allCases {
            let outcome = await toolbox.runResult(
                "search_tracks",
                arguments: ToolArguments(["query": .string("Fillerton")]),
                profile: profile
            )
            let text = await toolbox.run(
                "search_tracks",
                arguments: ToolArguments(["query": .string("Fillerton")]),
                profile: profile
            )
            #expect(outcome.text == text)
            #expect(outcome.resultCount == LibraryToolbox.defaultSearchLimit)
        }
    }

    @Test("a refusal reports no count, so a shell cannot label a failure as an empty lookup")
    func refusalsReportNoCount() async throws {
        let toolbox = try ToolboxFixtures.makeToolbox(ToolboxFixtures.makeLibrary())

        let badArgument = await toolbox.runResult("search_tracks", profile: .cloud)
        #expect(badArgument.resultCount == nil)
        #expect(badArgument.text == ToolArgumentError.missing(argument: "query").message)

        let unknown = await toolbox.runResult("delete_everything", profile: .cloud)
        #expect(unknown.resultCount == nil)
        #expect(unknown.text == LibraryToolError.unknownTool(name: "delete_everything").message)

        let missingPlaylist = await toolbox.runResult(
            "get_playlist",
            arguments: ToolArguments(["playlist_id": .int(9999)]),
            profile: .cloud
        )
        #expect(missingPlaylist.resultCount == nil)
    }
}
