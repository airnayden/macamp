import Foundation
import PlayerCoreTestSupport
import Services
import Testing

/// `play_tracks` and `queue_tracks` — the validation matrix.
///
/// Every case asserts BOTH halves: what the model was told, and what actually
/// reached the seam. Asserting only the sentence would pass a tool that refused an
/// id in words and played it anyway; asserting only the seam would pass one that
/// played the right four tracks and never mentioned the fifth.
///
/// The fixture supplies all three rejection shapes without any setup: track 6 lives
/// under the OTHER profile's root (invisible), track 4 is `.missing` (visible but
/// unplayable), and any unseeded id is absent.
@Suite("LibraryToolbox control — play and queue")
struct LibraryToolboxControlQueueTests {
    /// Visible to ``ToolboxFixtures/profileID`` but owned by the other profile.
    static let invisibleID: Int64 = 6
    /// Visible and present in the table, but its file is gone.
    static let missingFileID: Int64 = 4
    /// Not in the table at all.
    static let unknownID: Int64 = 4242

    // MARK: play_tracks

    @Test("valid ids reach the player in the order they were asked for")
    func validIdsReachThePlayerInOrder() async throws {
        let (toolbox, player) = try ToolboxFixtures.makeControllableToolbox(ToolboxFixtures.makeLibrary())
        let result = try await toolbox.execute("play_tracks", arguments: ids([3, 1, 5]))
        #expect(await player.playCalls == [[3, 1, 5]])
        #expect(result.summary == "Playing #3 Ember Waltz — Paper Lanterns · 0:00 of 5:12 "
            + "· shuffle off · repeat off · 2 up next.")
    }

    @Test("a fully accepted call adds no lead sentence — the state already says what started")
    func aFullyAcceptedCallAddsNoLead() async throws {
        let (toolbox, _) = try ToolboxFixtures.makeControllableToolbox(ToolboxFixtures.makeLibrary())
        let result = try await toolbox.execute("play_tracks", arguments: ids([1]))
        #expect(result.summary.hasPrefix("Playing #1 Aurora Drift"))
        #expect(!result.summary.contains("of 1 tracks"))
    }

    @Test("a track the profile cannot see is refused by id, and the rest still play")
    func anInvisibleIdIsRefusedByIdAndTheRestPlay() async throws {
        let (toolbox, player) = try ToolboxFixtures.makeControllableToolbox(ToolboxFixtures.makeLibrary())
        let result = try await toolbox.execute("play_tracks", arguments: ids([1, Self.invisibleID]))
        #expect(await player.playCalls == [[1]])
        #expect(result.summary.hasPrefix(
            "Playing 1 of 2 tracks. #6 is not in this listener's library."
        ))
        #expect(result.summary.contains("Playing #1 Aurora Drift — Nova Field"))
    }

    @Test("an id in no library at all gets the same honest sentence — the two are indistinguishable")
    func anUnknownIdIsRefusedTheSameWay() async throws {
        let (toolbox, player) = try ToolboxFixtures.makeControllableToolbox(ToolboxFixtures.makeLibrary())
        let result = try await toolbox.execute("play_tracks", arguments: ids([2, Self.unknownID]))
        #expect(await player.playCalls == [[2]])
        #expect(result.summary.contains("#4242 is not in this listener's library."))
    }

    @Test("a visible track whose file is gone is refused with its OWN reason, by name")
    func aMissingFileIsRefusedWithItsOwnReason() async throws {
        let (toolbox, player) = try ToolboxFixtures.makeControllableToolbox(ToolboxFixtures.makeLibrary())
        let result = try await toolbox.execute("play_tracks", arguments: ids([1, Self.missingFileID]))
        #expect(await player.playCalls == [[1]])
        #expect(result.summary.contains(
            "#4 Frostbite — Glass Harbour · Winterlong (2020) is missing from disk."
        ))
        #expect(!result.summary.contains("#4 is not in this listener's library"))
    }

    @Test("when NOTHING is playable the player is not touched at all")
    func everyIdInvalidTouchesNothing() async throws {
        let (toolbox, player) = try ToolboxFixtures.makeControllableToolbox(ToolboxFixtures.makeLibrary())
        let result = try await toolbox.execute(
            "play_tracks",
            arguments: ids([Self.invisibleID, Self.unknownID])
        )
        #expect(await player.playCalls.isEmpty)
        #expect(result.rows.isEmpty)
        #expect(result.resultCount == nil)
        #expect(result.summary == "Nothing was played; the player was not changed. "
            + "#6 is not in this listener's library; #4242 is not in this listener's library.")
    }

    @Test("a long refusal list is capped, and the remainder is counted rather than spelled")
    func aLongRefusalListIsCappedAndCounted() async throws {
        let (toolbox, _) = try ToolboxFixtures.makeControllableToolbox(ToolboxFixtures.makeLibrary())
        let ghosts = (0 ..< 9).map { Int64(9000 + $0) }
        let result = try await toolbox.execute("play_tracks", arguments: ids(ghosts))
        #expect(result.summary.contains("#9000 is not in this listener's library"))
        #expect(result.summary.contains("#9002 is not in this listener's library"))
        #expect(!result.summary.contains("#9003"))
        #expect(result.summary.hasSuffix("6 more could not be used."))
    }

    @Test("the OTHER profile can play the very track this one is refused")
    func visibilityIsPerProfileInBothDirections() async throws {
        let database = try ToolboxFixtures.makeLibrary()
        let (mine, minePlayer) = ToolboxFixtures.makeControllableToolbox(database)
        let (theirs, theirPlayer) = ToolboxFixtures.makeControllableToolbox(
            database,
            profileId: ToolboxFixtures.otherProfileID
        )

        let refused = try await mine.execute("play_tracks", arguments: ids([Self.invisibleID]))
        #expect(await minePlayer.playCalls.isEmpty)
        #expect(refused.summary.hasPrefix("Nothing was played"))

        let allowed = try await theirs.execute("play_tracks", arguments: ids([Self.invisibleID]))
        #expect(await theirPlayer.playCalls == [[Self.invisibleID]])
        #expect(allowed.summary.hasPrefix("Playing #6 Hidden Track — Other Owner"))
    }

    @Test("a malformed track_ids is refused BEFORE the player is reached")
    func malformedIdsNeverReachThePlayer() async throws {
        let (toolbox, player) = try ToolboxFixtures.makeControllableToolbox(ToolboxFixtures.makeLibrary())
        let cases: [(ToolArguments, ToolArgumentError)] = [
            (ToolArguments(), .missing(argument: "track_ids")),
            (ids([]), .empty(argument: "track_ids")),
            (
                ids((0 ..< 101).map { Int64($0) }),
                .tooMany(argument: "track_ids", limit: ToolResultBudget.identifierBatchLimit, found: 101)
            ),
            (
                ToolArguments(["track_ids": .string("1,2")]),
                .wrongType(argument: "track_ids", expected: "an array of integers")
            ),
        ]
        for (arguments, expected) in cases {
            let text = await toolbox.run("play_tracks", arguments: arguments, profile: .external)
            #expect(text == expected.message)
        }
        #expect(await player.playCalls.isEmpty)
    }

    /// The proposal ceiling rose to 500; `play_tracks` did NOT come with it. This tool
    /// starts playback, so its batch stays at the shared limit — the divergence is the
    /// point of the raise and is asserted here rather than inferred from two constants.
    @Test("play_tracks still refuses 101 ids even though a proposal now takes 500")
    func playbackKeepsTheHundredIdCeiling() async throws {
        let (toolbox, player) = try ToolboxFixtures.makeControllableToolbox(ToolboxFixtures.makeLibrary())
        let overshoot = ids((0 ..< 101).map { Int64($0) })

        let text = await toolbox.run("play_tracks", arguments: overshoot, profile: .external)

        #expect(text == "Argument \"track_ids\" accepts at most 100 items; 101 were given.")
        #expect(ToolResultBudget.proposalIdentifierLimit > ToolResultBudget.identifierBatchLimit)
        #expect(await player.playCalls.isEmpty)
    }

    @Test("mode accepts replace and refuses anything else, naming the vocabulary")
    func modeAcceptsOnlyReplace() async throws {
        let (toolbox, player) = try ToolboxFixtures.makeControllableToolbox(ToolboxFixtures.makeLibrary())
        var accepted = ids([1])
        accepted = ToolArguments(accepted.values.merging(["mode": .string("replace")]) { _, new in new })
        _ = try await toolbox.execute("play_tracks", arguments: accepted)
        #expect(await player.playCalls == [[1]])

        var rejected = ids([2])
        rejected = ToolArguments(rejected.values.merging(["mode": .string("append")]) { _, new in new })
        let text = await toolbox.run("play_tracks", arguments: rejected, profile: .external)
        #expect(text == ToolArgumentError.notAllowed(
            argument: "mode",
            allowed: LibraryToolbox.playTracksModes
        ).message)
        #expect(await player.playCalls == [[1]])
    }

    // MARK: queue_tracks

    @Test("queueing defaults to the end of the queue")
    func queueDefaultsToLast() async throws {
        let (toolbox, player) = try ToolboxFixtures.makeControllableToolbox(ToolboxFixtures.makeLibrary())
        let result = try await toolbox.execute("queue_tracks", arguments: ids([2, 3]))
        #expect(await player.queueCalls == [.init(ids: [2, 3], position: .last)])
        #expect(result.summary.hasPrefix("Queued 2 tracks at the end of the queue."))
    }

    @Test("position next is forwarded as next")
    func queueNextIsForwarded() async throws {
        let (toolbox, player) = try ToolboxFixtures.makeControllableToolbox(ToolboxFixtures.makeLibrary())
        let result = try await toolbox.execute("queue_tracks", arguments: positioned([5], "next"))
        #expect(await player.queueCalls == [.init(ids: [5], position: .next)])
        #expect(result.summary.hasPrefix("Queued 1 track to play next."))
    }

    @Test("queueing does not disturb what is playing")
    func queueingLeavesPlaybackAlone() async throws {
        let (toolbox, player) = try ToolboxFixtures.makeControllableToolbox(ToolboxFixtures.makeLibrary())
        _ = try await toolbox.execute("play_tracks", arguments: ids([1]))
        let result = try await toolbox.execute("queue_tracks", arguments: positioned([3], "next"))
        #expect(await player.playCalls == [[1]])
        #expect(result.summary.contains("Playing #1 Aurora Drift — Nova Field"))
        #expect(result.rows.map(\.text) == ["#3 Ember Waltz — Paper Lanterns · 5:12"])
    }

    @Test("an unusable id is refused here too, and the rest are still queued")
    func queueRefusesPerIdAsWell() async throws {
        let (toolbox, player) = try ToolboxFixtures.makeControllableToolbox(ToolboxFixtures.makeLibrary())
        let result = try await toolbox.execute(
            "queue_tracks",
            arguments: ids([2, Self.invisibleID, Self.missingFileID])
        )
        #expect(await player.queueCalls == [.init(ids: [2], position: .last)])
        #expect(result.summary.hasPrefix("Queued 1 of 3 tracks at the end of the queue."))
        #expect(result.summary.contains("#6 is not in this listener's library"))
        #expect(result.summary.contains("is missing from disk"))
    }

    @Test("nothing queueable leaves the queue untouched")
    func nothingQueueableTouchesNothing() async throws {
        let (toolbox, player) = try ToolboxFixtures.makeControllableToolbox(ToolboxFixtures.makeLibrary())
        let result = try await toolbox.execute("queue_tracks", arguments: ids([Self.invisibleID]))
        #expect(await player.queueCalls.isEmpty)
        #expect(result.summary.hasPrefix("Nothing was queued; the player was not changed."))
    }

    @Test("an unknown position is refused with the vocabulary and queues nothing")
    func anUnknownPositionIsRefused() async throws {
        let (toolbox, player) = try ToolboxFixtures.makeControllableToolbox(ToolboxFixtures.makeLibrary())
        let text = await toolbox.run("queue_tracks", arguments: positioned([1], "front"), profile: .external)
        #expect(text == ToolArgumentError.notAllowed(
            argument: "position",
            allowed: ToolboxQueuePosition.allCases.map(\.rawValue)
        ).message)
        #expect(await player.queueCalls.isEmpty)
    }

    // MARK: Helpers

    private func ids(_ values: [Int64]) -> ToolArguments {
        ToolArguments(["track_ids": .array(values.map { .int($0) })])
    }

    private func positioned(_ values: [Int64], _ position: String) -> ToolArguments {
        ToolArguments([
            "track_ids": .array(values.map { .int($0) }),
            "position": .string(position),
        ])
    }
}
