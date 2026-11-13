import Foundation
@testable import Services
import Testing

/// `match_tracks` — the batch resolver, and the two things it has to get right
/// that a per-track search cannot: a MISS is answered rather than omitted, and the
/// whole batch is bounded in the schema as well as at the accessor.
@Suite("LibraryToolbox match_tracks")
struct LibraryToolboxMatchTests {
    private static func pairs(_ entries: [(String, String?)]) -> ToolArguments {
        ToolArguments(["pairs": .array(entries.map { title, artist in
            .object([
                "title": .string(title),
                "artist": artist.map { ToolboxJSON.string($0) } ?? .null,
            ])
        })])
    }

    // MARK: The answer

    @Test("two present pairs and one absent produce two match rows and one miss row")
    func matchesAndMissesAreBothAnswered() async throws {
        let toolbox = try ToolboxFixtures.makeToolbox(ToolboxFixtures.makeLibrary())
        let result = try await toolbox.execute("match_tracks", arguments: Self.pairs([
            ("Aurora Drift", "Nova Field"),
            ("Ember Waltz", "Paper Lanterns"),
            ("Nonexistent Song", "Nobody At All"),
        ]))

        #expect(result.summary == "Matched 2 of 3 requested tracks.")
        #expect(result.rows.map(\.text) == [
            "#1 Aurora Drift — Nova Field · Northern Lights (2001)",
            "#3 Ember Waltz — Paper Lanterns · Slow Burn (1995)",
            "no match: Nonexistent Song — Nobody At All",
        ])

        let misses = result.rows.filter { $0.payload.objectValue?["kind"]?.stringValue == "miss" }
        #expect(misses.count == 1)
        #expect(result.rows.count - misses.count == 2)
        #expect(misses.first?.payload == .object([
            "kind": .string("miss"),
            "title": .string("Nonexistent Song"),
            "artist": .string("Nobody At All"),
        ]))
    }

    /// `resultCount` is the MATCH count. `ToolResult` clamps a stated count up to
    /// the rows the caller can already see, so the figure is read from a batch with
    /// no misses — where matches and rows are the same set and the clamp is inert.
    @Test("resultCount is the number of matches, not the number of pairs")
    func resultCountCountsMatches() async throws {
        let toolbox = try ToolboxFixtures.makeToolbox(ToolboxFixtures.makeLibrary())
        let matched = try await toolbox.execute("match_tracks", arguments: Self.pairs([
            ("Aurora Drift", "Nova Field"),
            ("Ember Waltz", "Paper Lanterns"),
        ]))
        #expect(matched.rows.count == 2)
        #expect(matched.resultCount == 2)

        let nothing = try await toolbox.execute("match_tracks", arguments: Self.pairs([
            ("Nonexistent Song", "Nobody At All"),
        ]))
        #expect(nothing.summary == "Matched 0 of 1 requested tracks.")
        #expect(nothing.resultCount == nothing.rows.count)
    }

    @Test("a pair with no artist still resolves, and its miss row carries a null artist")
    func theArtistIsOptional() async throws {
        let toolbox = try ToolboxFixtures.makeToolbox(ToolboxFixtures.makeLibrary())
        let result = try await toolbox.execute("match_tracks", arguments: Self.pairs([
            ("Golden Hour", nil),
            ("Nonexistent Song", nil),
        ]))
        #expect(result.summary == "Matched 1 of 2 requested tracks.")
        #expect(result.rows.map(\.text) == [
            "#5 Golden Hour — Paper Lanterns · Slow Burn (2008)",
            "no match: Nonexistent Song",
        ])
        #expect(result.rows.last?.payload.objectValue?["artist"] == .null)
    }

    @Test("limit_per_pair widens one pair's answer without widening the others")
    func limitPerPairWidensOnePair() async throws {
        let toolbox = try ToolboxFixtures.makeToolbox(ToolboxFixtures.makeLibrary())
        let single = try await toolbox.execute("match_tracks", arguments: Self.pairs([("Nova Field", nil)]))
        #expect(single.rows.count == 1)

        var wider = Self.pairs([("Nova Field", nil)]).values
        wider["limit_per_pair"] = .int(2)
        let result = try await toolbox.execute("match_tracks", arguments: ToolArguments(wider))
        #expect(result.rows.count == 2)
        #expect(result.summary == "Matched 1 of 1 requested tracks.")
    }

    @Test("a track owned by another profile is a MISS, not a leak")
    func visibilityScopingHoldsForABatch() async throws {
        let toolbox = try ToolboxFixtures.makeToolbox(ToolboxFixtures.makeLibrary())
        let result = try await toolbox.execute("match_tracks", arguments: Self.pairs([
            ("Hidden Track", "Other Owner"),
        ]))
        #expect(result.summary == "Matched 0 of 1 requested tracks.")
        #expect(result.rows.map(\.text) == ["no match: Hidden Track — Other Owner"])
    }

    // MARK: Refusals

    @Test("a batch above the documented ceiling is refused with the ceiling and the size")
    func anOversizedBatchIsRefused() async throws {
        let toolbox = try ToolboxFixtures.makeToolbox(ToolboxFixtures.makeLibrary())
        let oversized = (0 ... ToolResultBudget.identifierBatchLimit).map { ("Track \($0)", String?.none) }
        let text = await toolbox.run("match_tracks", arguments: Self.pairs(oversized), profile: .cloud)
        #expect(text == ToolArgumentError.tooMany(
            argument: "pairs",
            limit: ToolResultBudget.identifierBatchLimit,
            found: ToolResultBudget.identifierBatchLimit + 1
        ).message)
    }

    @Test("an empty pairs array is a typed refusal, and so is an absent or mistyped one")
    func malformedBatchesAreTypedRefusals() async throws {
        let toolbox = try ToolboxFixtures.makeToolbox(ToolboxFixtures.makeLibrary())

        await #expect(throws: ToolArgumentError.empty(argument: "pairs")) {
            try await toolbox.execute("match_tracks", arguments: ToolArguments(["pairs": .array([])]))
        }
        await #expect(throws: ToolArgumentError.missing(argument: "pairs")) {
            try await toolbox.execute("match_tracks")
        }
        await #expect(throws: ToolArgumentError.wrongType(argument: "pairs", expected: "an array of objects")) {
            try await toolbox.execute("match_tracks", arguments: ToolArguments(["pairs": .string("Aurora")]))
        }
        await #expect(throws: ToolArgumentError.wrongType(argument: "pairs", expected: "an array of objects")) {
            try await toolbox.execute(
                "match_tracks",
                arguments: ToolArguments(["pairs": .array([.string("Aurora")])])
            )
        }
        await #expect(throws: ToolArgumentError.missing(argument: "title")) {
            try await toolbox.execute(
                "match_tracks",
                arguments: ToolArguments(["pairs": .array([.object(["artist": .string("Nova Field")])])])
            )
        }
    }

    @Test("limit_per_pair is bounded, and a fractional value is a type error")
    func limitPerPairIsBounded() async throws {
        let toolbox = try ToolboxFixtures.makeToolbox(ToolboxFixtures.makeLibrary())
        var arguments = Self.pairs([("Aurora Drift", "Nova Field")]).values
        arguments["limit_per_pair"] = .int(LibraryToolbox.maximumMatchesPerPair + 1)
        let text = await toolbox.run("match_tracks", arguments: ToolArguments(arguments), profile: .cloud)
        #expect(text == ToolArgumentError.outOfRange(
            argument: "limit_per_pair",
            lower: 1,
            upper: Double(LibraryToolbox.maximumMatchesPerPair)
        ).message)
    }
}

// MARK: - The schema primitive

/// ``ToolSchema/objectArray(_:properties:required:maxItems:)`` — the nested shape
/// `match_tracks` needed and no other tool had. Asserted here as well as through
/// the registry sweeps because the MCP bridge republishes it verbatim.
@Suite("ToolSchema object arrays")
struct ToolSchemaObjectArrayTests {
    @Test("the item object is a strict object with its own properties and required list")
    func theItemShapeIsPublished() throws {
        let toolbox = try ToolboxFixtures.makeToolbox(ToolboxFixtures.makeLibrary())
        let tool = try #require(toolbox.tool(named: "match_tracks"))
        let properties = try #require(tool.parametersSchema.objectValue?["properties"]?.objectValue)
        let pairs = try #require(properties["pairs"]?.objectValue)

        #expect(pairs["type"]?.stringValue == "array")
        #expect(pairs["maxItems"]?.numberValue == Double(ToolResultBudget.identifierBatchLimit))

        let items = try #require(pairs["items"]?.objectValue)
        #expect(items["type"]?.stringValue == "object")
        #expect(items["additionalProperties"]?.boolValue == false)
        #expect(items["required"]?.arrayValue?.compactMap(\.stringValue) == ["title"])

        let itemProperties = try #require(items["properties"]?.objectValue)
        #expect(itemProperties.keys.sorted() == ["artist", "title"])
        #expect(itemProperties["title"]?.objectValue?["type"]?.stringValue == "string")
        #expect(itemProperties["artist"]?.objectValue?["type"]?.stringValue == "string")
    }

    @Test("a nested item object survives an encode/decode round trip unchanged")
    func theNestedSchemaRoundTrips() throws {
        let toolbox = try ToolboxFixtures.makeToolbox(ToolboxFixtures.makeLibrary())
        let tool = try #require(toolbox.tool(named: "match_tracks"))
        let decoded = try ToolboxJSON.decoded(from: tool.parametersSchema.encodedData())
        #expect(decoded == tool.parametersSchema)
    }
}
