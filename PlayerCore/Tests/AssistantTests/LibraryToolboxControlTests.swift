import Foundation
import PlayerCoreTestSupport
import Services
import Testing

/// The playback grant as a REGISTRY fact, plus the two control tools that name no
/// tracks.
///
/// The grant tests are the load-bearing ones: gating is implemented by not
/// registering a tool, so "the tools are absent" and "the names that were already
/// published did not move" are the two properties every tier inherits for free.
@Suite("LibraryToolbox control — registry and state")
struct LibraryToolboxControlTests {
    /// Every LIBRARY tool, in the order an UNGRANTED caller sees them.
    static let libraryToolNames = [
        "search_tracks",
        "list_genres",
        "get_tracks",
        "get_track_features",
        "get_listening_stats",
        "list_playlists",
        "get_playlist",
        "sample_tracks",
        "propose_playlist",
        "match_tracks",
    ]

    /// The library names registered BEFORE the conditional control block, so they
    /// occupy the same positions at either grant. `match_tracks` is registered
    /// after it and is therefore always last, which is why it is dropped here.
    static let leadingLibraryToolNames = Array(libraryToolNames.dropLast())

    // MARK: The grant

    @Test("without a playback grant the control tools are not registered at all")
    func noGrantHidesEveryControlTool() throws {
        let toolbox = try ToolboxFixtures.makeToolbox(ToolboxFixtures.makeLibrary())
        #expect(toolbox.allTools.map(\.name) == Self.libraryToolNames)
        for profile in ToolProfile.allCases {
            let published = Set(toolbox.tools(profile: profile).map(\.name))
            #expect(published.isDisjoint(with: Set(LibraryToolbox.controlToolNames)))
        }
        for name in LibraryToolbox.controlToolNames {
            #expect(toolbox.tool(named: name) == nil)
        }
    }

    @Test("a grant INSERTS the control tools contiguously; it never renumbers a published name")
    func aGrantAppendsWithoutRenumbering() throws {
        let (toolbox, _) = try ToolboxFixtures.makeControllableToolbox(ToolboxFixtures.makeLibrary())
        let names = toolbox.allTools.map(\.name)
        #expect(Array(names.prefix(Self.leadingLibraryToolNames.count)) == Self.leadingLibraryToolNames)
        // The control four are CONTIGUOUS and sit immediately before the library
        // tools registered after them; `match_tracks` stays last at either grant.
        let afterLeading = names.dropFirst(Self.leadingLibraryToolNames.count)
        #expect(Array(afterLeading.dropLast()) == LibraryToolbox.controlToolNames)
        #expect(names.last == "match_tracks")
        #expect(names.count == Self.libraryToolNames.count + LibraryToolbox.controlToolNames.count)
        #expect(names.count == 14)
    }

    @Test("cloud and external publish all fourteen; on-device publishes five plus three")
    func eachTierPublishesItsOwnSet() throws {
        let (toolbox, _) = try ToolboxFixtures.makeControllableToolbox(ToolboxFixtures.makeLibrary())
        #expect(toolbox.tools(profile: .cloud).map(\.name) == toolbox.allTools.map(\.name))
        #expect(toolbox.tools(profile: .external).map(\.name) == toolbox.allTools.map(\.name))
        #expect(
            toolbox.tools(profile: .onDevice).map(\.name)
                == LibraryToolbox.onDeviceToolNames + LibraryToolbox.onDeviceControlToolNames
        )
        #expect(LibraryToolbox.onDeviceToolNames.count == ToolResultBudget.onDeviceToolLimit)
        #expect(LibraryToolbox.onDeviceControlToolNames.count == ToolResultBudget.onDeviceControlToolLimit)
    }

    @Test("the ungranted on-device set is byte-identical to what shipped before")
    func theUngrantedOnDeviceSetIsUnchanged() throws {
        let toolbox = try ToolboxFixtures.makeToolbox(ToolboxFixtures.makeLibrary())
        #expect(toolbox.tools(profile: .onDevice).map(\.name) == LibraryToolbox.onDeviceToolNames)
    }

    @Test("queue_tracks is the control tool the on-device tier leaves out")
    func onDeviceDropsQueueTracks() {
        let dropped = Set(LibraryToolbox.controlToolNames)
            .subtracting(LibraryToolbox.onDeviceControlToolNames)
        #expect(dropped == ["queue_tracks"])
    }

    @Test("an ungranted control tool is UNKNOWN, not refused — the model is never taught it exists")
    func ungrantedControlToolsReadAsUnknown() async throws {
        let toolbox = try ToolboxFixtures.makeToolbox(ToolboxFixtures.makeLibrary())
        for name in LibraryToolbox.controlToolNames {
            let text = await toolbox.run(name, profile: .external)
            #expect(text == LibraryToolError.unknownTool(name: name).message)
        }
    }

    // MARK: get_playback_state

    @Test("an idle player is reported as idle, with no invented position")
    func idlePlayerReportsNothing() async throws {
        let (toolbox, _) = try ToolboxFixtures.makeControllableToolbox(ToolboxFixtures.makeLibrary())
        let result = try await toolbox.execute("get_playback_state")
        #expect(result.summary == "Nothing is playing · shuffle off · repeat off · nothing up next.")
        #expect(result.rows.isEmpty)
    }

    @Test("the report names the current track, the playhead and the queue")
    func stateNamesTheTrackAndTheQueue() async throws {
        let (toolbox, player) = try ToolboxFixtures.makeControllableToolbox(ToolboxFixtures.makeLibrary())
        _ = try await toolbox.execute("play_tracks", arguments: ids([3, 1, 5]))
        await player.setElapsedSeconds(32)
        await player.setShuffling(true)
        await player.setRepeatSetting(.all)

        let result = try await toolbox.execute("get_playback_state")
        #expect(result.summary == "Playing #3 Ember Waltz — Paper Lanterns · 0:32 of 5:12 "
            + "· shuffle on · repeat all · 2 up next.")
        #expect(result.rows.map(\.text) == [
            "#1 Aurora Drift — Nova Field · 4:05",
            "#5 Golden Hour — Paper Lanterns · 4:25",
        ])
    }

    @Test("the queue preview is bounded, and the summary states the real total")
    func theQueuePreviewIsBoundedButHonest() async throws {
        let (toolbox, _) = try ToolboxFixtures.makeControllableToolbox(ToolboxFixtures.makeLibrary())
        let fillerIds = (0 ..< 12).map { Int64(100 + $0) }
        _ = try await toolbox.execute("play_tracks", arguments: ids(fillerIds))

        let result = try await toolbox.execute("get_playback_state")
        #expect(result.rows.count == ToolResultBudget.playbackQueuePreviewLimit)
        #expect(result.summary.contains("11 up next."))
        #expect(!result.summary.contains("+"))
    }

    @Test("the report asks the player for exactly the documented preview depth")
    func theReportRequestsTheDocumentedDepth() async throws {
        let (toolbox, player) = try ToolboxFixtures.makeControllableToolbox(ToolboxFixtures.makeLibrary())
        _ = try await toolbox.execute("get_playback_state")
        #expect(await player.snapshotRequests == [ToolResultBudget.playbackQueuePreviewLimit])
    }

    @Test("no control tool is list-shaped — a transport press has no result count")
    func controlToolsReportNoResultCount() async throws {
        let (toolbox, _) = try ToolboxFixtures.makeControllableToolbox(ToolboxFixtures.makeLibrary())
        let calls: [(String, ToolArguments)] = [
            ("get_playback_state", ToolArguments()),
            ("play_tracks", ids([1, 2])),
            ("queue_tracks", ids([3])),
            ("transport", ToolArguments(["action": .string("pause")])),
        ]
        for (name, arguments) in calls {
            let result = try await toolbox.execute(name, arguments: arguments)
            #expect(result.resultCount == nil, "\(name) reported a count it cannot mean")
        }
    }

    // MARK: transport

    @Test("every transport verb reaches the player, in order")
    func everyVerbReachesThePlayer() async throws {
        let (toolbox, player) = try ToolboxFixtures.makeControllableToolbox(ToolboxFixtures.makeLibrary())
        for action in ToolboxTransportAction.allCases {
            _ = try await toolbox.execute("transport", arguments: ToolArguments([
                "action": .string(action.rawValue),
            ]))
        }
        #expect(await player.transportCalls == ToolboxTransportAction.allCases)
    }

    @Test("pause reports the paused state, so the model can tell a no-op from a press")
    func pauseReportsThePausedState() async throws {
        let (toolbox, _) = try ToolboxFixtures.makeControllableToolbox(ToolboxFixtures.makeLibrary())
        _ = try await toolbox.execute("play_tracks", arguments: ids([2]))
        let result = try await toolbox.execute("transport", arguments: ToolArguments([
            "action": .string("pause"),
        ]))
        #expect(result.summary.hasPrefix("Paused at #2 Crimson Pulse — Nova Field"))
    }

    @Test("stepping past the end of the queue reports a stop rather than claiming success")
    func steppingPastTheEndReportsAStop() async throws {
        let (toolbox, _) = try ToolboxFixtures.makeControllableToolbox(ToolboxFixtures.makeLibrary())
        _ = try await toolbox.execute("play_tracks", arguments: ids([2]))
        let result = try await toolbox.execute("transport", arguments: ToolArguments([
            "action": .string("next"),
        ]))
        #expect(result.summary == "Nothing is playing · shuffle off · repeat off · nothing up next.")
    }

    @Test("an unknown verb is refused with the whole vocabulary and touches nothing")
    func anUnknownVerbIsRefusedWithTheVocabulary() async throws {
        let (toolbox, player) = try ToolboxFixtures.makeControllableToolbox(ToolboxFixtures.makeLibrary())
        let text = await toolbox.run("transport", arguments: ToolArguments([
            "action": .string("volume_up"),
        ]), profile: .external)
        #expect(text == ToolArgumentError.notAllowed(
            argument: "action",
            allowed: ToolboxTransportAction.allCases.map(\.rawValue)
        ).message)
        #expect(await player.transportCalls.isEmpty)
    }

    @Test("transport requires an action")
    func transportRequiresAnAction() async throws {
        let (toolbox, player) = try ToolboxFixtures.makeControllableToolbox(ToolboxFixtures.makeLibrary())
        let text = await toolbox.run("transport", profile: .external)
        #expect(text == ToolArgumentError.missing(argument: "action").message)
        #expect(await player.transportCalls.isEmpty)
    }

    private func ids(_ values: [Int64]) -> ToolArguments {
        ToolArguments(["track_ids": .array(values.map { .int($0) })])
    }
}
