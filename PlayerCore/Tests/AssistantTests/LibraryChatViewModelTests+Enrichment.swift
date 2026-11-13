// LibraryChatViewModelTests+Enrichment — the seam that fills in a suggestion's video
// link after its turn has already landed.
//
// ── WHY AN EXTENSION AND NOT A SIBLING SUITE ─────────────────────────────────
//
// The lane that gates this seam is `swift test --filter LibraryChatViewModelTests`,
// and a filter matches the suite TYPE name. A sibling suite under any other name
// would compile, pass locally, and never run in the lane that is supposed to gate it —
// the same failure mode the parent suite's own header records for a wrong fence.
// An extension is reached by the existing filter and keeps
// `LibraryChatViewModelTests.swift` under `file_length`. Its `private` fakes are
// file-scoped, so the ones below are declared fresh rather than shared.
//
// ── HOW THIS SUITE WAITS ─────────────────────────────────────────────────────
//
// Enrichment deliberately OUTLIVES the turn that started it, so `await send(_:)`
// returning proves nothing about it. Every case here captures the model's tracked
// enrichment task and awaits THAT — a real transition published by the thing under
// test, no yielding, no polling, no elapsed time, exactly as the parent suite demands.
// ``ChatTurnGate`` parks the FIRST enrichment and lets every later one straight
// through, which is what makes the stale-message case expressible at all: the second
// turn has to be able to land while the first turn's enrichment is still in the air.
import Foundation
import Services
import Testing
@testable import ViewModels

/// The fakes and readers, at file scope so the extension body stays small.
private enum Enrichment {
    /// One link per enricher CALL, so an assertion can name which call's answer landed
    /// on which row rather than merely observing that something did.
    static func link(_ ordinal: Int) -> URL {
        guard let url = URL(string: "https://www.youtube.com/watch?v=fixture\(ordinal)") else {
            fatalError("a literal fixture URL cannot fail to parse")
        }
        return url
    }

    /// The two misses every case in this file enriches.
    static let misses = [
        AssistantChatSuggestion(title: "November Rain", artist: "Guns N' Roses"),
        AssistantChatSuggestion(title: "Riders On The Storm"),
    ]

    /// A turn that reported those misses, shaped exactly as `match_tracks` reports
    /// them: one call event, one result event carrying the suggestions.
    static var reply: LibraryChatReply {
        LibraryChatReply(turn: AssistantChatTurn(text: "Two of those are not in your library.", events: [
            .toolCall(name: "match_tracks"),
            .toolResult(name: "match_tracks", summary: "1 of 3 matched.", resultCount: 1, suggestions: misses),
        ]))
    }

    static func engine(_ reply: LibraryChatReply) -> LibraryChatEngine {
        LibraryChatEngine(prewarm: {}, send: { _ in reply })
    }

    /// The suggestions one row draws, flattened in the order the transcript reads them.
    @MainActor
    static func suggestions(_ message: LibraryChatMessage?) -> [AssistantChatSuggestion] {
        (message?.toolActivity ?? []).flatMap(\.suggestions)
    }

    @MainActor
    static func links(_ message: LibraryChatMessage?) -> [URL?] {
        suggestions(message).map(\.videoURL)
    }

    /// Awaits every enrichment this model still has in flight.
    ///
    /// The tasks are CAPTURED before they are awaited because the model drops each one
    /// as it finishes; awaiting the dictionary lazily would race with its own drain.
    @MainActor
    static func settle(_ model: LibraryChatViewModel) async {
        for task in Array(model.enrichments.values) {
            await task.value
        }
    }
}

/// An enricher a test can park, count, and read an ordinal back out of.
///
/// It answers with the SAME titles it was handed plus one link derived from the call's
/// ordinal — so a case can assert not just "a link landed" but "call 1's link landed on
/// call 1's row".
///
/// It deliberately does NOT abandon its work when cancelled; it merely RECORDS that it
/// was. Bailing out would make cancellation indistinguishable from the generation guard
/// that also stops the write, and the two are separate deliverables: the guard keeps a
/// stale answer off the screen, cancellation stops the round trip being paid for at all.
/// Answering anyway is also the hostile case — a real resolver is free to ignore
/// cancellation, and the transcript must survive one that does.
private actor GatedEnricher {
    private let gate: ChatTurnGate?
    private var calls = 0
    private(set) var cancelledCalls = 0

    init(gate: ChatTurnGate? = nil) {
        self.gate = gate
    }

    func enrich(_ suggestions: [AssistantChatSuggestion]) async -> [AssistantChatSuggestion] {
        calls += 1
        let ordinal = calls
        await gate?.wait()
        if Task.isCancelled {
            cancelledCalls += 1
        }
        return suggestions.map {
            AssistantChatSuggestion(title: $0.title, artist: $0.artist, videoURL: Enrichment.link(ordinal))
        }
    }
}

extension LibraryChatViewModelTests {
    // MARK: The happy path

    @Test("an enrichment fills the landed row's links and changes nothing else about the transcript")
    func enrichmentKeepsTheTranscriptsCountAndIdentity() async {
        let enricher = GatedEnricher()
        let model = LibraryChatViewModel(
            makeEngine: { .success(Enrichment.engine(Enrichment.reply)) },
            suggestionEnricher: { await enricher.enrich($0) }
        )
        await model.send("play me november rain")
        let identities = model.messages.map(\.id)
        await Enrichment.settle(model)
        // Count and identity are the assertion: a rebuild that appended a row, or one
        // that minted a fresh id, would re-animate a transcript the listener is reading.
        #expect(model.messages.count == 2)
        #expect(model.messages.map(\.id) == identities)
        #expect(Enrichment.links(model.messages.last) == [Enrichment.link(1), Enrichment.link(1)])
        #expect(Enrichment.suggestions(model.messages.last).map(\.title) == Enrichment.misses.map(\.title))
    }

    @Test("with no enricher a turn's suggestions are exactly what the tier reported")
    func noEnricherLeavesTheTranscriptUntouched() async {
        let model = LibraryChatViewModel(makeEngine: { .success(Enrichment.engine(Enrichment.reply)) })
        await model.send("play me november rain")
        #expect(model.enrichments.isEmpty)
        #expect(Enrichment.suggestions(model.messages.last) == Enrichment.misses)
    }

    // MARK: What an enricher may and may not contribute

    @Test("an enricher contributes a link and nothing else — it cannot rewrite what was asked for")
    func anEnricherMayContributeOnlyTheLink() async {
        let link = Enrichment.link(9)
        let model = LibraryChatViewModel(
            makeEngine: { .success(Enrichment.engine(Enrichment.reply)) },
            suggestionEnricher: { suggestions in
                suggestions.map { _ in
                    AssistantChatSuggestion(title: "hijacked", artist: "hijacked", videoURL: link)
                }
            }
        )
        await model.send("play me november rain")
        await Enrichment.settle(model)
        #expect(Enrichment.suggestions(model.messages.last).map(\.title) == Enrichment.misses.map(\.title))
        #expect(Enrichment.suggestions(model.messages.last).map(\.artist) == Enrichment.misses.map(\.artist))
        #expect(Enrichment.links(model.messages.last) == [link, link])
    }

    @Test("an answer of the wrong length is discarded whole, so every original survives")
    func aShortOrLongAnswerLeavesTheOriginalsAlone() async {
        for answered in [0, 1, 3] {
            let model = LibraryChatViewModel(
                makeEngine: { .success(Enrichment.engine(Enrichment.reply)) },
                suggestionEnricher: { _ in
                    (0 ..< answered).map {
                        AssistantChatSuggestion(title: "answer \($0)", videoURL: Enrichment.link($0))
                    }
                }
            )
            await model.send("play me november rain")
            await Enrichment.settle(model)
            #expect(
                Enrichment.suggestions(model.messages.last) == Enrichment.misses,
                "an answer of \(answered) items must not merge onto \(Enrichment.misses.count) originals"
            )
        }
    }

    // MARK: Reset and staleness

    @Test("a reset while an enrichment is in flight mutates nothing when it lands")
    func aResetMidEnrichmentMutatesNothing() async {
        let gate = ChatTurnGate()
        let enricher = GatedEnricher(gate: gate)
        let model = LibraryChatViewModel(
            makeEngine: { .success(Enrichment.engine(Enrichment.reply)) },
            suggestionEnricher: { await enricher.enrich($0) }
        )
        await model.send("play me november rain")
        // The enricher having been ENTERED is what proves the enrichment is genuinely
        // in flight; the task merely existing is set a hop earlier.
        await gate.waitForArrivals(1)
        let parked = Array(model.enrichments.values)
        #expect(parked.count == 1)
        model.reset()
        #expect(model.messages.isEmpty)
        await gate.open()
        for task in parked {
            await task.value
        }
        // Two separate deliverables, asserted separately: the round trip was CANCELLED
        // (so a discarded conversation stops costing anything), and the answer it
        // returned anyway wrote NOTHING (so a resolver that ignores cancellation still
        // cannot resurrect a row). Only the second survives the generation guard alone.
        #expect(await enricher.cancelledCalls == 1)
        #expect(model.messages.isEmpty)
        #expect(model.enrichments.isEmpty)
    }

    @Test("cancelInFlight stops the enrichment round trip but keeps the transcript")
    func cancelInFlightCancelsEnrichmentWithoutClearingTheTranscript() async {
        // The composition root calls this on a graph rebuild — a profile switch or a
        // provider change — where the conversation stays on screen. So the assertion is
        // the pair: the work stops, the rows the listener is reading do not move.
        let gate = ChatTurnGate()
        let enricher = GatedEnricher(gate: gate)
        let model = LibraryChatViewModel(
            makeEngine: { .success(Enrichment.engine(Enrichment.reply)) },
            suggestionEnricher: { await enricher.enrich($0) }
        )
        await model.send("play me november rain")
        await gate.waitForArrivals(1)
        let parked = Array(model.enrichments.values)
        let identities = model.messages.map(\.id)
        model.cancelInFlight()
        await gate.open()
        for task in parked {
            await task.value
        }
        #expect(await enricher.cancelledCalls == 1)
        #expect(model.messages.map(\.id) == identities)
    }

    @Test("a slow enrichment lands on its OWN row, never on the newer one that overtook it")
    func aSlowEnrichmentNeverOverwritesANewerRow() async {
        let gate = ChatTurnGate()
        let enricher = GatedEnricher(gate: gate)
        let model = LibraryChatViewModel(
            makeEngine: { .success(Enrichment.engine(Enrichment.reply)) },
            suggestionEnricher: { await enricher.enrich($0) }
        )
        await model.send("first")
        await gate.waitForArrivals(1)
        // The second turn LANDS while the first turn's enrichment is still parked, so a
        // rebuild that targeted "the last row" instead of its own id would put call 1's
        // link on the second answer and leave the first answer bare.
        await model.send("second")
        let identities = model.messages.map(\.id)
        await gate.open()
        await Enrichment.settle(model)
        #expect(model.messages.count == 4)
        #expect(model.messages.map(\.id) == identities)
        #expect(Enrichment.links(model.messages[1]) == [Enrichment.link(1), Enrichment.link(1)])
        #expect(Enrichment.links(model.messages[3]) == [Enrichment.link(2), Enrichment.link(2)])
    }
}
