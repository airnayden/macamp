import Foundation
import Persistence
@testable import Services
import Testing

/// `propose_playlist` — the one write-adjacent tool. It FILES; it must never
/// reach the database.
@Suite("LibraryToolbox propose_playlist")
struct LibraryToolboxProposalTests {
    @Test("filing reports the proposal id and says nothing was saved")
    func filesAndReportsTheId() async throws {
        let database = try ToolboxFixtures.makeLibrary()
        let filer = FakeToolboxProposalFiler()
        let toolbox = ToolboxFixtures.makeToolbox(database, filer: filer)

        let result = try await toolbox.execute("propose_playlist", arguments: ToolArguments([
            "name": .string("Late Shift"),
            "track_ids": .array([.int(3), .int(1)]),
            "description": .string("Two slow ones."),
        ]))

        #expect(result.renderedText(profile: .cloud) == """
        Filed "Late Shift" (2 tracks) for the listener to review. Nothing has been saved yet.
        proposal_id \(filer.identifier.uuidString)
        """)
    }

    @Test("the filed proposal carries the profile, the name, the order and the note")
    func filesTheWholeOffer() async throws {
        let database = try ToolboxFixtures.makeLibrary()
        let filer = FakeToolboxProposalFiler()
        let toolbox = ToolboxFixtures.makeToolbox(database, filer: filer)

        _ = try await toolbox.execute("propose_playlist", arguments: ToolArguments([
            "name": .string("Late Shift"),
            "track_ids": .array([.int(3), .int(1), .int(5)]),
            "description": .string("Two slow ones."),
        ]))

        let allFiled = await filer.filed
        let filed = try #require(allFiled.first)
        #expect(allFiled.count == 1)
        #expect(filed.profileId == ToolboxFixtures.profileID)
        #expect(filed.name == "Late Shift")
        #expect(filed.trackIds == [3, 1, 5])
        #expect(filed.summary == "Two slow ones.")
    }

    @Test("filing writes NOTHING to the library")
    func filingWritesNothing() async throws {
        let database = try ToolboxFixtures.makeLibrary()
        let toolbox = ToolboxFixtures.makeToolbox(database)
        let before = try ToolboxFixtures.playlistNames(database)

        _ = try await toolbox.execute("propose_playlist", arguments: ToolArguments([
            "name": .string("Late Shift"),
            "track_ids": .int(3).arrayWrapped,
        ]))

        try #expect(ToolboxFixtures.playlistNames(database) == before)
        #expect(before == ["Evening Set", "Not Yours"])
    }

    @Test("the description is optional")
    func descriptionIsOptional() async throws {
        let database = try ToolboxFixtures.makeLibrary()
        let filer = FakeToolboxProposalFiler()
        let toolbox = ToolboxFixtures.makeToolbox(database, filer: filer)

        _ = try await toolbox.execute("propose_playlist", arguments: ToolArguments([
            "name": .string("Bare"),
            "track_ids": .int(1).arrayWrapped,
        ]))

        let filed = await filer.filed
        #expect(filed.first?.summary == nil)
    }

    /// `name` is the one argument criteria cannot stand in for. The membership half
    /// of the refusal moved to `+Criteria.swift`, where an empty `track_ids` is one
    /// of the two spellings of "no ids".
    @Test("a nameless proposal is refused before anything is filed")
    func refusesAnIncompleteOffer() async throws {
        let database = try ToolboxFixtures.makeLibrary()
        let filer = FakeToolboxProposalFiler()
        let toolbox = ToolboxFixtures.makeToolbox(database, filer: filer)

        await #expect(throws: ToolArgumentError.missing(argument: "name")) {
            try await toolbox.execute("propose_playlist", arguments: ToolArguments([
                "track_ids": .int(1).arrayWrapped,
            ]))
        }
        let filed = await filer.filed
        #expect(filed.isEmpty)
    }

    @Test("a filing failure becomes a sentence, not an exception that ends the turn")
    func filingFailureIsReported() async throws {
        let database = try ToolboxFixtures.makeLibrary()
        let filer = FakeToolboxProposalFiler()
        await filer.setFailure(ToolboxFilingFailure())
        let toolbox = ToolboxFixtures.makeToolbox(database, filer: filer)

        let rendered = await toolbox.run("propose_playlist", arguments: ToolArguments([
            "name": .string("Doomed"),
            "track_ids": .int(1).arrayWrapped,
        ]), profile: .cloud)

        #expect(rendered.hasPrefix("The proposal could not be filed:"))
        let filed = await filer.filed
        #expect(filed.isEmpty)
    }

    @Test("a proposal short of the asked-for total says so, in numbers, in the summary")
    func shortfallIsEchoedBackToTheModel() async throws {
        let database = try ToolboxFixtures.makeLibrary()
        let filer = FakeToolboxProposalFiler()
        let toolbox = ToolboxFixtures.makeToolbox(database, filer: filer)

        let result = try await toolbox.execute("propose_playlist", arguments: ToolArguments([
            "name": .string("Long Haul"),
            "track_ids": .array((1 ... 12).map { ToolboxJSON.int($0) }),
            "target_count": .int(25),
        ]))

        // Both numbers, spelled out, so a model that under-delivered can see the
        // gap without re-counting its own answer.
        #expect(result.summary.contains("asked for 25"))
        #expect(result.summary.contains("has 12"))
        #expect(result.summary == """
        Filed "Long Haul" (12 tracks) for the listener to review. Nothing has been saved yet. \
        The listener asked for 25 tracks but this proposal has 12. \
        Add more tracks and propose again, or tell the listener why not.
        """)
        // The shortfall is a SENTENCE, not a refusal: the offer is still filed.
        let filed = await filer.filed
        #expect(filed.count == 1)
        #expect(filed.first?.trackIds.count == 12)
    }

    @Test("a proposal that meets the asked-for total adds nothing to the summary")
    func meetingTheTargetSaysNothingExtra() async throws {
        let database = try ToolboxFixtures.makeLibrary()
        let toolbox = ToolboxFixtures.makeToolbox(database, filer: FakeToolboxProposalFiler())

        let result = try await toolbox.execute("propose_playlist", arguments: ToolArguments([
            "name": .string("Long Haul"),
            "track_ids": .array((1 ... 12).map { ToolboxJSON.int($0) }),
            "target_count": .int(12),
        ]))

        #expect(result.summary == """
        Filed "Long Haul" (12 tracks) for the listener to review. Nothing has been saved yet.
        """)
        #expect(result.summary.contains("asked for") == false)
    }

    @Test("omitting target_count leaves the summary byte-identical to what shipped")
    func omittedTargetCountChangesNothing() async throws {
        let database = try ToolboxFixtures.makeLibrary()
        let toolbox = ToolboxFixtures.makeToolbox(database, filer: FakeToolboxProposalFiler())

        let result = try await toolbox.execute("propose_playlist", arguments: ToolArguments([
            "name": .string("Late Shift"),
            "track_ids": .array([.int(3), .int(1)]),
            "description": .string("Two slow ones."),
        ]))

        // The optional argument is invisible when absent — an existing caller's
        // answer must not move by one byte.
        #expect(result.summary == """
        Filed "Late Shift" (2 tracks) for the listener to review. Nothing has been saved yet.
        """)
    }

    @Test("a target_count outside 1…500 is refused with its bounds named")
    func outOfRangeTargetCountIsRefused() async throws {
        let database = try ToolboxFixtures.makeLibrary()
        let filer = FakeToolboxProposalFiler()
        let toolbox = ToolboxFixtures.makeToolbox(database, filer: filer)
        let refusal = ToolArgumentError.outOfRange(
            argument: "target_count",
            lower: 1,
            upper: Double(ToolResultBudget.proposalIdentifierLimit)
        )

        for asked in [0, ToolResultBudget.proposalIdentifierLimit + 1] {
            let arguments = ToolArguments([
                "name": .string("Out Of Bounds"),
                "track_ids": .int(1).arrayWrapped,
                "target_count": .int(asked),
            ])
            await #expect(throws: refusal) {
                try await toolbox.execute("propose_playlist", arguments: arguments)
            }
            #expect(await toolbox.run("propose_playlist", arguments: arguments, profile: .cloud)
                == "Argument \"target_count\" must be between 1 and 500.")
        }

        let filed = await filer.filed
        #expect(filed.isEmpty)
    }

    @Test("a membership past the PROPOSAL ceiling is refused rather than silently trimmed")
    func oversizedMembershipIsRefused() async throws {
        let database = try ToolboxFixtures.makeLibrary()
        let filer = FakeToolboxProposalFiler()
        let toolbox = ToolboxFixtures.makeToolbox(database, filer: filer)
        let overshoot = ToolResultBudget.proposalIdentifierLimit + 1
        let ids = (1 ... overshoot).map { ToolboxJSON.int($0) }

        let rendered = await toolbox.run("propose_playlist", arguments: ToolArguments([
            "name": .string("Too Big"),
            "track_ids": .array(ids),
        ]), profile: .cloud)

        // The exact refusal sentence, not a prefix: a model reads this to correct
        // itself, so both numbers have to be in it.
        #expect(rendered == "Argument \"track_ids\" accepts at most 500 items; 501 were given.")
        let filed = await filer.filed
        #expect(filed.isEmpty)
    }

    @Test("the ceiling itself accepts a full 500-track offer")
    func theCeilingIsAcceptedInFull() async throws {
        let database = try ToolboxFixtures.makeLibrary()
        let filer = FakeToolboxProposalFiler()
        let toolbox = ToolboxFixtures.makeToolbox(database, filer: filer)
        let ceiling = ToolResultBudget.proposalIdentifierLimit
        let ids = (1 ... ceiling).map { ToolboxJSON.int($0) }

        let result = try await toolbox.execute("propose_playlist", arguments: ToolArguments([
            "name": .string("The Long Set"),
            "track_ids": .array(ids),
            "target_count": .int(ceiling),
        ]))

        #expect(result.summary == """
        Filed "The Long Set" (500 tracks) for the listener to review. Nothing has been saved yet.
        """)
        let filed = await filer.filed
        #expect(filed.first?.trackIds.count == ceiling)
    }

    /// The proposal ceiling lands EXACTLY on the clamp `sampleTrackIds` lowers into
    /// (`SmartPlaylistRules.effectiveLimit`). Raising it past that clamp would let a
    /// model file ids the materialiser silently truncates, so the coupling is pinned
    /// here rather than left as a comment.
    @Test("the proposal ceiling never outruns the smart-playlist materialisation clamp")
    func theCeilingIsCoupledToTheMaterialisationClamp() {
        #expect(ToolResultBudget.proposalIdentifierLimit <= SmartPlaylistRules.maximumLimit)
    }

    /// The raise is DELIBERATELY local to `propose_playlist`. Widening the shared
    /// batch limit would also widen `play_tracks`, `queue_tracks`, `get_tracks`,
    /// `get_track_features` and `match_tracks` — playback control the raise never
    /// asked for.
    @Test("raising the proposal ceiling leaves the shared batch limit at 100")
    func theSharedBatchLimitIsUntouched() {
        #expect(ToolResultBudget.identifierBatchLimit == 100)
        #expect(ToolResultBudget.proposalIdentifierLimit == 500)
    }
}
