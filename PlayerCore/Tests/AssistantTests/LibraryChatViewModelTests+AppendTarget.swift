// LibraryChatViewModelTests+AppendTarget — which playlist a turn was ABOUT, captured
// at the moment its tools said so.
//
// ── WHY AN EXTENSION AND NOT A SIBLING SUITE ─────────────────────────────────
//
// The same reason `+Enrichment.swift` records: the lane that gates this seam is
// `swift test --filter LibraryChatViewModelTests`, and a filter matches the suite TYPE
// name. A sibling suite under any other name would compile, pass locally, and never
// run in the lane meant to gate it.
//
// ── WHAT IS ACTUALLY BEING PINNED ────────────────────────────────────────────
//
// Three claims a naive per-message implementation gets wrong:
//
//   1. PRECEDENCE. A filed proposal outranks a playlist merely read, and the LAST
//      read wins — a model that opened three to compare them meant the one it
//      settled on.
//   2. THE CORRECTIVE BACK-FILL. `correct(...)` is entered precisely when the first
//      landing filed NOTHING, so the suggestions sit on message A while the proposal
//      lands on message B. Per-message precedence would leave A with no target and
//      degrade the feature to download-only in exactly its most common flow.
//   3. SURVIVAL. Enrichment rewrites the suggestion-bearing row FIELD BY FIELD, and
//      is what produces the `videoURL` the download affordance needs — so a rebuild
//      landing after a target was set is the NORMAL ordering. Both orderings are
//      asserted, in both directions.
//
// ── HOW THIS SUITE WAITS ─────────────────────────────────────────────────────
//
// Exactly as the parent suite demands: a fence is a REAL transition published by the
// thing under test (``ChatTurnGate/waitForArrivals(_:)``, or awaiting the model's own
// tracked enrichment task). No yielding, no polling, no elapsed time.
import Foundation
import Services
import Testing
@testable import ViewModels

/// The fixtures, at file scope so the extension body stays inside `type_body_length`.
private enum AppendTarget {
    static let playlistID: Int64 = 5
    static let profileID: Int64 = 42

    /// The two misses a `match_tracks` turn reports, shaped exactly as the tool does.
    static let misses = [
        AssistantChatSuggestion(title: "November Rain", artist: "Guns N' Roses"),
        AssistantChatSuggestion(title: "Riders On The Storm"),
    ]

    static var suggestingReply: LibraryChatReply {
        LibraryChatReply(turn: AssistantChatTurn(text: "Two of those are not in your library.", events: [
            .toolCall(name: "match_tracks"),
            .toolResult(name: "match_tracks", summary: "1 of 3 matched.", resultCount: 1, suggestions: misses),
        ]))
    }

    /// `nonisolated` because the fakes build replies from inside a `@Sendable` send
    /// closure, which does not run on the main actor.
    nonisolated static func turn(_ text: String) -> LibraryChatReply {
        LibraryChatReply(turn: AssistantChatTurn(text: text))
    }

    static func link(_ ordinal: Int) -> URL {
        guard let url = URL(string: "https://www.youtube.com/watch?v=append\(ordinal)") else {
            fatalError("a literal fixture URL cannot fail to parse")
        }
        return url
    }

    @MainActor
    static func links(_ message: LibraryChatMessage?) -> [URL?] {
        (message?.toolActivity ?? []).flatMap(\.suggestions).map(\.videoURL)
    }

    /// Awaits every enrichment in flight, captured first because the model drops each.
    @MainActor
    static func settle(_ model: LibraryChatViewModel) async {
        for task in Array(model.enrichments.values) {
            await task.value
        }
    }

    /// An enricher that stamps every suggestion with one fixed link.
    static func enricher(_ ordinal: Int) -> @Sendable ([AssistantChatSuggestion]) async -> [AssistantChatSuggestion] {
        { suggestions in
            suggestions.map {
                AssistantChatSuggestion(title: $0.title, artist: $0.artist, videoURL: link(ordinal))
            }
        }
    }
}

/// Stands in for the shell's `LibraryChatPlaylistContextRecorder`.
@MainActor
private final class PlaylistReadBox {
    private var reads: [(playlistId: Int64, profileId: Int64)] = []

    func read(_ playlistId: Int64, profileId: Int64 = AppendTarget.profileID) {
        reads.append((playlistId: playlistId, profileId: profileId))
    }

    func drain() -> [(playlistId: Int64, profileId: Int64)] {
        defer { reads.removeAll() }
        return reads
    }
}

extension LibraryChatViewModelTests {
    // MARK: Precedence

    @Test("a turn that filed a proposal names it, and leaves the profile to the proposal itself")
    func aFiledProposalBecomesThePendingTarget() async {
        let filed = UUID()
        let box = ChatProposalBox()
        let model = LibraryChatViewModel(
            makeEngine: {
                .success(LibraryChatEngine(prewarm: {}, send: { _ in
                    await box.file(filed)
                    return AppendTarget.turn("Made you one.")
                }))
            },
            drainFiledProposals: { box.drain() }
        )

        await model.send("make me a playlist")

        #expect(model.messages.last?.appendTarget == .pendingProposal(filed))
        #expect(model.messages.last?.appendProfileId == nil)
    }

    @Test("a turn that only READ a playlist names that playlist, with the profile the tool ran as")
    func aReadPlaylistBecomesThePlaylistTarget() async {
        let reads = PlaylistReadBox()
        let model = LibraryChatViewModel(
            makeEngine: {
                .success(LibraryChatEngine(prewarm: {}, send: { _ in
                    await reads.read(AppendTarget.playlistID)
                    return AppendTarget.turn("Here is what is in it.")
                }))
            },
            drainPlaylistReads: { reads.drain() }
        )

        await model.send("what is in my evening set")

        #expect(model.messages.last?.appendTarget == .playlist(AppendTarget.playlistID))
        #expect(model.messages.last?.appendProfileId == AppendTarget.profileID)
    }

    @Test("a turn that did both is named by the PROPOSAL — the offer outranks the lookup")
    func theProposalOutranksTheRead() async {
        let filed = UUID()
        let box = ChatProposalBox()
        let reads = PlaylistReadBox()
        let model = LibraryChatViewModel(
            makeEngine: {
                .success(LibraryChatEngine(prewarm: {}, send: { _ in
                    await reads.read(AppendTarget.playlistID)
                    await box.file(filed)
                    return AppendTarget.turn("Based on that one, here is a new one.")
                }))
            },
            drainFiledProposals: { box.drain() },
            drainPlaylistReads: { reads.drain() }
        )

        await model.send("make me a playlist like my evening set")

        #expect(model.messages.last?.appendTarget == .pendingProposal(filed))
        #expect(model.messages.last?.appendProfileId == nil)
    }

    @Test("a turn that neither filed nor read names nothing — a plain download stays plain")
    func neitherFilingNorReadingLeavesNoTarget() async {
        let model = LibraryChatViewModel(makeEngine: {
            .success(LibraryChatEngine(prewarm: {}, send: { _ in AppendTarget.turn("Try these.") }))
        })

        await model.send("what should I listen to")

        #expect(model.messages.last?.appendTarget == nil)
        #expect(model.messages.last?.appendProfileId == nil)
    }

    @Test("a model built without the new drain — every construction that predates it — names nothing")
    func theDrainDefaultsToNone() async {
        let model = LibraryChatViewModel(
            makeEngine: {
                .success(LibraryChatEngine(prewarm: {}, send: { _ in AppendTarget.suggestingReply }))
            },
            drainFiledProposals: { [] }
        )

        await model.send("play me november rain")

        #expect(model.messages.last?.appendTarget == nil)
    }

    // MARK: A drain that answers awkwardly

    @Test("several reads in one turn resolve to the LAST, across duplicates and profiles alike")
    func theLastReadWins() async {
        let reads = PlaylistReadBox()
        let model = LibraryChatViewModel(
            makeEngine: {
                .success(LibraryChatEngine(prewarm: {}, send: { _ in
                    await reads.read(3, profileId: 1)
                    await reads.read(3, profileId: 1)
                    await reads.read(9, profileId: 77)
                    return AppendTarget.turn("Compared them.")
                }))
            },
            drainPlaylistReads: { reads.drain() }
        )

        await model.send("compare my two playlists")

        #expect(model.messages.last?.appendTarget == .playlist(9))
        #expect(model.messages.last?.appendProfileId == 77)
    }

    // MARK: The drain-once contract

    @Test("a read in turn A never reaches turn B")
    func aReadNeverLeaksIntoTheNextTurn() async {
        let reads = PlaylistReadBox()
        let sends = ChatCallCounter()
        let model = LibraryChatViewModel(
            makeEngine: {
                .success(LibraryChatEngine(prewarm: {}, send: { _ in
                    await sends.increment()
                    if await sends.value == 1 {
                        await reads.read(AppendTarget.playlistID)
                    }
                    return AppendTarget.turn("ok")
                }))
            },
            drainPlaylistReads: { reads.drain() }
        )

        await model.send("what is in my evening set")
        #expect(model.messages.last?.appendTarget == .playlist(AppendTarget.playlistID))

        await model.send("and what is the weather")
        #expect(model.messages.last?.appendTarget == nil)
        // Draining is not erasing: turn A's own row keeps the target it landed with.
        #expect(model.messages[1].appendTarget == .playlist(AppendTarget.playlistID))
    }

    @Test("a turn cancelled after a read leaves nothing behind for the turn after it")
    func aCancelledTurnDiscardsItsReads() async {
        let reads = PlaylistReadBox()
        let sends = ChatCallCounter()
        let model = LibraryChatViewModel(
            makeEngine: {
                .success(LibraryChatEngine(prewarm: {}, send: { _ in
                    await sends.increment()
                    guard await sends.value > 1 else {
                        await reads.read(AppendTarget.playlistID)
                        throw CancellationError()
                    }
                    return AppendTarget.turn("ok")
                }))
            },
            drainPlaylistReads: { reads.drain() }
        )

        await model.send("what is in my evening set")
        await model.send("and now something else")

        // A cancelled turn is silent, so the transcript is listener / listener /
        // assistant — and the surviving answer read nothing of its own.
        #expect(model.messages.count == 3)
        #expect(model.messages.last?.role == .assistant)
        #expect(model.messages.last?.appendTarget == nil)
    }

    // MARK: The corrective back-fill

    @Test("the corrective turn's proposal is back-filled onto the row that carries the suggestions")
    func theCorrectiveProposalReachesTheSuggestionRow() async {
        let filed = UUID()
        let box = ChatProposalBox()
        let sends = ChatCallCounter()
        let model = LibraryChatViewModel(
            makeEngine: {
                .success(LibraryChatEngine(
                    prewarm: {},
                    send: { _ in
                        await sends.increment()
                        guard await sends.value == 2 else { return AppendTarget.suggestingReply }
                        await box.file(filed)
                        return AppendTarget.turn("Filed it.")
                    },
                    supportsCorrectiveFollowUp: true
                ))
            },
            drainFiledProposals: { box.drain() }
        )

        await model.send("make me a playlist of these")

        #expect(model.messages.count == 3)
        // Message A carries the suggestions and filed nothing; message B carries the
        // proposal and has no suggestions. Both name the same target.
        #expect(model.messages[1].proposalIds.isEmpty)
        #expect(model.messages[1].appendTarget == .pendingProposal(filed))
        #expect(model.messages[1].appendProfileId == nil)
        #expect(model.messages[2].appendTarget == .pendingProposal(filed))
    }

    @Test("a corrective turn that only READ a playlist names its own row and leaves the first alone")
    func aCorrectiveReadIsNotBackFilled() async {
        let reads = PlaylistReadBox()
        let sends = ChatCallCounter()
        let model = LibraryChatViewModel(
            makeEngine: {
                .success(LibraryChatEngine(
                    prewarm: {},
                    send: { _ in
                        await sends.increment()
                        if await sends.value == 2 {
                            await reads.read(AppendTarget.playlistID)
                        }
                        return AppendTarget.turn("Have a look at this one.")
                    },
                    supportsCorrectiveFollowUp: true
                ))
            },
            drainPlaylistReads: { reads.drain() }
        )

        await model.send("make me a playlist for tonight")

        #expect(model.messages.count == 3)
        #expect(model.messages[1].appendTarget == nil)
        #expect(model.messages[2].appendTarget == .playlist(AppendTarget.playlistID))
    }

    // MARK: Enrichment survival

    @Test("an enrichment landing AFTER the target keeps it — the rebuild carries both fields")
    func enrichmentPreservesTheTarget() async {
        let filed = UUID()
        let box = ChatProposalBox()
        let model = LibraryChatViewModel(
            makeEngine: {
                .success(LibraryChatEngine(prewarm: {}, send: { _ in
                    await box.file(filed)
                    return AppendTarget.suggestingReply
                }))
            },
            drainFiledProposals: { box.drain() },
            suggestionEnricher: AppendTarget.enricher(1)
        )

        await model.send("make me a playlist of these")
        await AppendTarget.settle(model)

        #expect(AppendTarget.links(model.messages.last) == [AppendTarget.link(1), AppendTarget.link(1)])
        #expect(model.messages.last?.appendTarget == .pendingProposal(filed))
    }

    @Test("a back-fill landing AFTER an enrichment keeps the resolved link — each rebuild reads the LIVE row")
    func theBackFillPreservesAnEnrichedRow() async {
        let gate = ChatTurnGate()
        let filed = UUID()
        let box = ChatProposalBox()
        let sends = ChatCallCounter()
        let model = LibraryChatViewModel(
            makeEngine: {
                .success(LibraryChatEngine(
                    prewarm: {},
                    // The corrective send parks on the gate, so message A's enrichment
                    // is free to land BEFORE the back-fill does.
                    send: { _ in
                        await sends.increment()
                        guard await sends.value == 2 else { return AppendTarget.suggestingReply }
                        await gate.wait()
                        await box.file(filed)
                        return AppendTarget.turn("Filed it.")
                    },
                    supportsCorrectiveFollowUp: true
                ))
            },
            drainFiledProposals: { box.drain() },
            suggestionEnricher: AppendTarget.enricher(2)
        )

        let inFlight = Task { await model.send("make me a playlist of these") }
        await gate.waitForArrivals(1)
        await AppendTarget.settle(model)
        #expect(AppendTarget.links(model.messages[1]) == [AppendTarget.link(2), AppendTarget.link(2)])

        await gate.open()
        await inFlight.value
        await AppendTarget.settle(model)

        #expect(model.messages[1].appendTarget == .pendingProposal(filed))
        #expect(AppendTarget.links(model.messages[1]) == [AppendTarget.link(2), AppendTarget.link(2)])
    }
}
