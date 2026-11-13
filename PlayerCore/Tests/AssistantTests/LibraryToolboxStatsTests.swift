import Foundation
@testable import Services
import Testing

/// `get_listening_stats` over the REAL `ListeningDigestBuilder` and the seeded
/// `playEvent` rows — six plays across three tracks, so every ranking has exactly
/// one right answer.
@Suite("LibraryToolbox listening stats")
struct LibraryToolboxStatsTests {
    @Test("the seven-day window reports the plays, the hours and the skip rate")
    func summarisesTheWindow() async throws {
        let database = try ToolboxFixtures.makeLibrary()
        let toolbox = ToolboxFixtures.makeToolbox(database)
        let result = try await toolbox.execute("get_listening_stats", arguments: ToolArguments([
            "window": .string("7d"),
        ]))
        #expect(result.summary.hasPrefix("7d: 6 plays,"))
        #expect(result.summary.contains("0.3 hours listened"))
        #expect(result.summary.hasSuffix("17% skipped."))
    }

    @Test("top tracks, artists and genres come back in one deterministic block")
    func ranksEveryFacet() async throws {
        let database = try ToolboxFixtures.makeLibrary()
        let toolbox = ToolboxFixtures.makeToolbox(database)
        let result = try await toolbox.execute("get_listening_stats", arguments: ToolArguments([
            "window": .string("7d"),
        ]))
        #expect(result.rows.map(\.text) == [
            "Top track: Crimson Pulse — Nova Field (3 plays)",
            "Top track: Ember Waltz — Paper Lanterns (2 plays)",
            "Top track: Aurora Drift — Nova Field (1 play)",
            "Top artist: Nova Field (4 plays)",
            "Top artist: Paper Lanterns (2 plays)",
            "Top genre: Electronic (3 plays)",
            "Top genre: Jazz (2 plays)",
            "Top genre: Ambient (1 play)",
        ])
    }

    @Test("stats rows carry no library id — the digest never joins the track table")
    func rowsCarryNoLibraryId() async throws {
        let database = try ToolboxFixtures.makeLibrary()
        let toolbox = ToolboxFixtures.makeToolbox(database)
        let result = try await toolbox.execute("get_listening_stats")
        for row in result.rows {
            #expect(row.payload.objectValue?["id"] == nil)
        }
    }

    @Test("the window argument defaults to thirty days")
    func defaultsToThirtyDays() async throws {
        let database = try ToolboxFixtures.makeLibrary()
        let toolbox = ToolboxFixtures.makeToolbox(database)
        let implicit = try await toolbox.execute("get_listening_stats")
        let explicit = try await toolbox.execute("get_listening_stats", arguments: ToolArguments([
            "window": .string(LibraryToolbox.defaultStatsWindow),
        ]))
        #expect(implicit.renderedText(profile: .cloud) == explicit.renderedText(profile: .cloud))
        #expect(implicit.summary.hasPrefix("30d: 6 plays,"))
    }

    @Test("every published window token maps to a real digest window")
    func everyWindowTokenWorks() async throws {
        let database = try ToolboxFixtures.makeLibrary()
        let toolbox = ToolboxFixtures.makeToolbox(database)
        for token in LibraryToolbox.statsWindowNames {
            let result = try await toolbox.execute("get_listening_stats", arguments: ToolArguments([
                "window": .string(token),
            ]))
            #expect(result.summary.hasPrefix("\(token): 6 plays,"), "\(token) reported \(result.summary)")
        }
    }

    @Test("an unpublished window token is refused with the vocabulary")
    func refusesAnUnknownWindow() async throws {
        let database = try ToolboxFixtures.makeLibrary()
        let toolbox = ToolboxFixtures.makeToolbox(database)
        let rendered = await toolbox.run(
            "get_listening_stats",
            arguments: ToolArguments(["window": .string("yesterday")]),
            profile: .onDevice
        )
        #expect(rendered == "Argument \"window\" must be one of: 7d, 30d, 12m, all.")
    }

    @Test("a profile with no history is told so, not shown zeroes")
    func emptyHistorySaysSo() async throws {
        let database = try ToolboxFixtures.makeLibrary()
        let toolbox = ToolboxFixtures.makeToolbox(database, profileId: ToolboxFixtures.otherProfileID)
        let result = try await toolbox.execute("get_listening_stats")
        #expect(result.rows.isEmpty)
        #expect(result.renderedText(profile: .onDevice) == "No listening history recorded for 30d.")
    }

    @Test("the stats block fits the on-device budget")
    func fitsTheOnDeviceBudget() async throws {
        let database = try ToolboxFixtures.makeLibrary()
        let toolbox = ToolboxFixtures.makeToolbox(database)
        let result = try await toolbox.execute("get_listening_stats")
        #expect(result.renderedText(profile: .onDevice).count <= ToolProfile.onDevice.characterLimit)
    }
}
