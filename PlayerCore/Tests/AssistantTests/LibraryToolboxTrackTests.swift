import Foundation
@testable import Services
import Testing

/// `get_tracks` and `get_track_features`.
@Suite("LibraryToolbox tracks")
struct LibraryToolboxTrackTests {
    @Test("details come back in the order they were asked for")
    func resolvesInRequestOrder() async throws {
        let database = try ToolboxFixtures.makeLibrary()
        let toolbox = ToolboxFixtures.makeToolbox(database)
        let result = try await toolbox.execute("get_tracks", arguments: ToolArguments([
            "track_ids": .array([.int(3), .int(1)]),
        ]))
        #expect(result.renderedText(profile: .cloud) == """
        2 tracks.
        #3 Ember Waltz — Paper Lanterns · Slow Burn (1995) · Jazz · 5:12 · present
        #1 Aurora Drift — Nova Field · Northern Lights (2001) · Ambient · 4:05 · present
        """)
    }

    @Test("an unknown id is reported as unknown rather than silently dropped")
    func reportsUnknownIds() async throws {
        let database = try ToolboxFixtures.makeLibrary()
        let toolbox = ToolboxFixtures.makeToolbox(database)
        let result = try await toolbox.execute("get_tracks", arguments: ToolArguments([
            "track_ids": .array([.int(1), .int(9999)]),
        ]))
        #expect(result.rows.count == 1)
        #expect(result.summary == "1 of 2 tracks found; 1 unknown to this listener's library.")
    }

    @Test("a missing file keeps its row and states its availability")
    func availabilityIsStated() async throws {
        let database = try ToolboxFixtures.makeLibrary()
        let toolbox = ToolboxFixtures.makeToolbox(database)
        let result = try await toolbox.execute("get_tracks", arguments: ToolArguments([
            "track_ids": .array([.int(4)]),
        ]))
        #expect(result.rows.first?.text.hasSuffix("· missing") == true)
    }

    @Test("an untagged genre is simply absent from the row")
    func untaggedGenreIsAbsent() async throws {
        let database = try ToolboxFixtures.makeLibrary()
        let toolbox = ToolboxFixtures.makeToolbox(database)
        let result = try await toolbox.execute("get_tracks", arguments: ToolArguments([
            "track_ids": .int(5).arrayWrapped,
        ]))
        let row = try #require(result.rows.first)
        #expect(row.text == "#5 Golden Hour — Paper Lanterns · Slow Burn (2008) · 4:25 · present")
        #expect(row.payload.objectValue?["genre"] == .null)
    }

    @Test("a batch larger than the resolve ceiling is refused, not half-answered")
    func oversizedBatchIsRefused() async throws {
        let database = try ToolboxFixtures.makeLibrary()
        let toolbox = ToolboxFixtures.makeToolbox(database)
        let ids = (1 ... ToolResultBudget.identifierBatchLimit + 1).map { ToolboxJSON.int($0) }
        let rendered = await toolbox.run(
            "get_tracks",
            arguments: ToolArguments(["track_ids": .array(ids)]),
            profile: .cloud
        )
        #expect(rendered == "Argument \"track_ids\" accepts at most \(ToolResultBudget.identifierBatchLimit) "
            + "items; \(ToolResultBudget.identifierBatchLimit + 1) were given.")
    }
}

// MARK: - Features

@Suite("LibraryToolbox audio features")
struct LibraryToolboxFeatureTests {
    @Test("an unanalysed track says so; it is never reported as zero")
    func unanalysedIsSaidNotZeroed() async throws {
        let database = try ToolboxFixtures.makeLibrary()
        let toolbox = ToolboxFixtures.makeToolbox(database)
        let result = try await toolbox.execute("get_track_features", arguments: ToolArguments([
            "track_ids": .array([.int(2), .int(3), .int(5)]),
        ]))
        #expect(result.renderedText(profile: .cloud) == """
        2 of 3 requested tracks are analysed.
        #2 Crimson Pulse — Nova Field · Northern Lights (2014) — tempo 128 bpm · energy 0.82 · brightness 0.71
        #3 Ember Waltz — Paper Lanterns · Slow Burn (1995) — tempo unknown · energy 0.25 · brightness 0.30
        #5 Golden Hour — Paper Lanterns · Slow Burn (2008) — not analysed
        """)
    }

    @Test("the payload distinguishes unanalysed from a null beat")
    func payloadIsNullableHonest() async throws {
        let database = try ToolboxFixtures.makeLibrary()
        let toolbox = ToolboxFixtures.makeToolbox(database)
        let result = try await toolbox.execute("get_track_features", arguments: ToolArguments([
            "track_ids": .array([.int(3), .int(5)]),
        ]))
        let beatless = try #require(result.rows.first?.payload.objectValue)
        let unanalysed = try #require(result.rows.last?.payload.objectValue)

        #expect(beatless["analysed"] == .bool(true))
        #expect(beatless["bpm"] == .null)
        #expect(beatless["energy"] == .number(0.25))
        #expect(unanalysed["analysed"] == .bool(false))
        #expect(unanalysed["bpm"] == nil)
    }

    @Test("an id nobody knows still gets a row, named by its id")
    func unknownIdStillGetsARow() async throws {
        let database = try ToolboxFixtures.makeLibrary()
        let toolbox = ToolboxFixtures.makeToolbox(database)
        let result = try await toolbox.execute("get_track_features", arguments: ToolArguments([
            "track_ids": .int(4242).arrayWrapped,
        ]))
        #expect(result.rows.first?.text == "#4242 (unknown track) — not analysed")
    }
}

// MARK: - Test conveniences

extension ToolboxJSON {
    /// `[self]` — reads better than `.array([.int(5)])` at a call site that names
    /// exactly one id.
    var arrayWrapped: ToolboxJSON {
        .array([self])
    }
}
