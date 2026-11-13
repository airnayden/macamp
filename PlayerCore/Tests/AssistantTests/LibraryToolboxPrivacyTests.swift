import Foundation
@testable import Services
import Testing

/// The sweep that keeps the layout of the listener's disk out of a model's
/// context: EVERY tool, at EVERY tier, in both its rendered text and its machine
/// payload, must be free of file paths.
///
/// This is the tool-layer form of the stats digest's rule ("no `filePath` … in
/// events, rollups, heatmaps, or archive payloads"), and it matters more here: a
/// `.cloud` result leaves the machine.
@Suite("LibraryToolbox privacy")
struct LibraryToolboxPrivacyTests {
    /// A valid call for every registered tool. Kept exhaustive by
    /// ``everyToolIsSwept`` — a new tool with no entry fails that test.
    ///
    /// The control calls are ORDER-DEPENDENT on purpose: `play_tracks` runs before
    /// `get_playback_state`, so the state the sweep reads back is a real queue of
    /// real fixture tracks rather than an empty player that could not leak a path
    /// even if the renderer wanted to.
    static let calls: [(name: String, arguments: [String: ToolboxJSON])] = [
        ("search_tracks", ["query": .string("a")]),
        ("list_genres", [:]),
        ("get_tracks", ["track_ids": .array([.int(1), .int(2), .int(3), .int(4), .int(5)])]),
        ("get_track_features", ["track_ids": .array([.int(1), .int(3), .int(5)])]),
        ("get_listening_stats", ["window": .string("all")]),
        ("list_playlists", [:]),
        ("get_playlist", ["playlist_id": .int(ToolboxFixtures.playlistID)]),
        ("sample_tracks", [:]),
        ("propose_playlist", ["name": .string("Sweep"), "track_ids": .array([.int(1), .int(2)])]),
        ("match_tracks", ["pairs": .array([
            .object(["title": .string("Aurora Drift"), "artist": .string("Nova Field")]),
            .object(["title": .string("Ember Waltz"), "artist": .string("Paper Lanterns")]),
        ])]),
        ("play_tracks", ["track_ids": .array([.int(1), .int(2), .int(3), .int(4), .int(6)])]),
        ("queue_tracks", ["track_ids": .array([.int(5)]), "position": .string("next")]),
        ("get_playback_state", [:]),
        ("transport", ["action": .string("pause")]),
    ]

    /// The markers the fixture library plants in every `filePath`.
    static let forbidden = [ToolboxFixtures.pathPrefix, ".flac", "filePath"]

    @Test("the sweep covers every registered tool")
    func everyToolIsSwept() throws {
        let database = try ToolboxFixtures.makeLibrary()
        let (toolbox, _) = ToolboxFixtures.makeControllableToolbox(database)
        #expect(Set(Self.calls.map(\.name)) == Set(toolbox.allTools.map(\.name)))
    }

    @Test("no rendered result names a file, at any tier")
    func renderedResultsCarryNoPaths() async throws {
        let database = try ToolboxFixtures.makeLibrary()
        let (toolbox, _) = ToolboxFixtures.makeControllableToolbox(database)
        for call in Self.calls {
            let result = try await toolbox.execute(call.name, arguments: ToolArguments(call.arguments))
            for profile in ToolProfile.allCases {
                let rendered = result.renderedText(profile: profile)
                for marker in Self.forbidden {
                    #expect(!rendered.contains(marker), "\(call.name) at \(profile) leaked \"\(marker)\"")
                }
            }
        }
    }

    @Test("no machine payload names a file either")
    func payloadsCarryNoPaths() async throws {
        let database = try ToolboxFixtures.makeLibrary()
        let (toolbox, _) = ToolboxFixtures.makeControllableToolbox(database)
        for call in Self.calls {
            let result = try await toolbox.execute(call.name, arguments: ToolArguments(call.arguments))
            let json = result.payload.jsonText
            #expect(!json.isEmpty, "\(call.name) produced no payload")
            for marker in Self.forbidden {
                #expect(!json.contains(marker), "\(call.name) payload leaked \"\(marker)\"")
            }
        }
    }

    @Test("every result honours its tier's character budget")
    func everyResultFitsItsBudget() async throws {
        let database = try ToolboxFixtures.makeLibrary()
        let (toolbox, _) = ToolboxFixtures.makeControllableToolbox(database)
        for call in Self.calls {
            let result = try await toolbox.execute(call.name, arguments: ToolArguments(call.arguments))
            for profile in ToolProfile.allCases {
                let rendered = result.renderedText(profile: profile)
                #expect(
                    rendered.count <= profile.characterLimit,
                    "\(call.name) at \(profile) rendered \(rendered.count) characters"
                )
            }
        }
    }

    /// The caller's OWN words are echoed back so a multi-tool turn can tell its
    /// searches apart. That echo is the one part of a result the caller controls,
    /// so it is bounded — otherwise a long enough query would be an unbounded
    /// write channel into a budget meant for library data.
    @Test("the echoed query is bounded")
    func echoedQueryIsBounded() async throws {
        let database = try ToolboxFixtures.makeLibrary()
        let toolbox = ToolboxFixtures.makeToolbox(database)
        let result = try await toolbox.execute("search_tracks", arguments: ToolArguments([
            "query": .string(String(repeating: "z", count: 500)),
        ]))
        #expect(result.summary.count < LibraryToolbox.echoedQueryLimit * 2)
        #expect(result.summary.contains(ToolResultBudget.ellipsis))
    }
}
