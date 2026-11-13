// LibraryChatEventTests — the chat tier's two pure policies: what a transcript
// becomes, and when it gets condensed.
//
// NOT gated on `canImport(FoundationModels)`, and that is the point of the design
// under test. ``ChatTranscriptEntry`` is this module's own mirror of Apple's
// `Transcript.Entry`, so every branch of the event mapping and the whole 4096-token
// context policy is table-testable on ANY host — no macOS 26, no SDK, no Apple
// Intelligence, no model. The gated half (`LibraryChatTranscript`) is a five-case
// translation with nothing to decide; it is exercised in
// `LibraryChatToolTests.swift`, which does need the SDK.
import Foundation
import Services
import Testing

@Suite("LibraryChat events")
struct LibraryChatEventTests {
    private static let toolText = "3 genres in this listener's library."

    @Test("Instructions and the listener's own prompt are dropped, not echoed back")
    func dropsInstructionsAndPrompt() {
        let events = AssistantChatEventMapping.events(from: [
            .instructions("You are the assistant inside MacAMP."),
            .prompt("what jazz do I have?"),
        ])
        #expect(events.isEmpty)
    }

    @Test("A tool round-trip becomes a call event then a result event, in order")
    func mapsToolRoundTrip() {
        let events = AssistantChatEventMapping.events(from: [
            .prompt("what jazz do I have?"),
            .toolCalls(["list_genres"]),
            .toolOutput(name: "list_genres", text: Self.toolText),
            .response("You have one jazz track."),
        ])
        #expect(events == [
            .toolCall(name: "list_genres"),
            .toolResult(name: "list_genres", summary: Self.toolText, resultCount: nil),
            .assistantText("You have one jazz track."),
        ])
    }

    @Test("Every call in one toolCalls entry is reported, in call order")
    func mapsParallelToolCalls() {
        // `Tool.call` is `@concurrent` and MAY run alongside itself, so one entry
        // can carry several calls. Reporting only the first would silently hide a
        // lookup the answer was built from.
        let events = AssistantChatEventMapping.events(from: [.toolCalls(["list_genres", "search_tracks"])])
        #expect(events == [.toolCall(name: "list_genres"), .toolCall(name: "search_tracks")])
    }

    @Test("A blank response segment produces no event")
    func dropsBlankResponse() {
        // The model emits one on a turn that was pure tool calling. An empty
        // bubble in the transcript is worse than no bubble.
        #expect(AssistantChatEventMapping.events(from: [.response("   \n ")]).isEmpty)
        #expect(AssistantChatEventMapping.events(from: [.response("")]).isEmpty)
    }

    @Test("The answer text is derived from the same entries the events are")
    func derivesAnswerText() {
        let entries: [ChatTranscriptEntry] = [
            .instructions("ignored"),
            .prompt("ignored"),
            .toolOutput(name: "list_genres", text: Self.toolText),
            .response("  You have one jazz track.  "),
        ]
        #expect(AssistantChatEventMapping.answerText(from: entries) == "You have one jazz track.")
    }

    @Test("calledToolNames reports the deterministic half of a turn")
    func reportsCalledToolNames() {
        // A model's WORDING varies run to run; whether it reached for `list_genres`
        // does not. This is what the live smoke test asserts on.
        let turn = AssistantChatTurn(text: "…", events: [
            .toolCall(name: "list_genres"),
            .toolResult(name: "list_genres", summary: Self.toolText, resultCount: nil),
            .toolCall(name: "search_tracks"),
            .assistantText("…"),
        ])
        #expect(turn.calledToolNames == ["list_genres", "search_tracks"])
    }

    @Test("A turn's text falls back to the response content only when the entries carry none")
    func turnFallsBackToResponseContent() {
        let derived = AssistantChatEventMapping.turn(
            from: [.toolCalls(["list_genres"]), .response("From the entries.")],
            fallbackText: "From the response object."
        )
        #expect(derived.text == "From the entries.")
        #expect(derived.calledToolNames == ["list_genres"])

        let fallback = AssistantChatEventMapping.turn(
            from: [.toolCalls(["list_genres"])],
            fallbackText: "From the response object."
        )
        #expect(fallback.text == "From the response object.")
        #expect(fallback.events == [.toolCall(name: "list_genres")])
    }

    @Test("An unavailable reason survives the Error wrapper unchanged")
    func carriesUnavailableReason() {
        for reason in AssistantUnavailableReason.allCases {
            #expect(AssistantChatUnavailable(reason: reason).reason == reason)
        }
    }
}

// MARK: - Result counts

/// The half of the count contract that needs no SDK: what a ledger stores, how a
/// transcript entry picks its count back up, and how calls are paired with results.
@Suite("LibraryChat result counts")
struct LibraryChatResultCountTests {
    private static let genresText = "3 genres in this listener's library."
    private static let searchText = "12 tracks matching \"jazz\"."

    @Test("A recorded count reaches the event for the answer it was recorded against")
    func recordedCountReachesTheEvent() {
        var counts = ChatToolResultCounts()
        counts.record(renderedText: Self.genresText, resultCount: 3)

        let events = AssistantChatEventMapping.events(
            from: [.toolCalls(["list_genres"]), .toolOutput(name: "list_genres", text: Self.genresText)],
            counts: counts
        )
        #expect(events == [
            .toolCall(name: "list_genres"),
            .toolResult(name: "list_genres", summary: Self.genresText, resultCount: 3),
        ])
    }

    @Test("An answer nobody recorded a count for stays nil, and the mapping is otherwise unchanged")
    func unrecordedAnswerStaysNil() {
        // The default argument is what every existing caller gets, so a tier that
        // cannot produce counts renders exactly the copy it rendered before.
        let entries: [ChatTranscriptEntry] = [.toolOutput(name: "list_genres", text: Self.genresText)]
        #expect(AssistantChatEventMapping.events(from: entries) == [
            .toolResult(name: "list_genres", summary: Self.genresText, resultCount: nil),
        ])
    }

    @Test("A nil count is not stored, so it cannot be told apart from one never recorded")
    func nilCountsAreNotStored() {
        var counts = ChatToolResultCounts()
        counts.record(renderedText: Self.genresText, resultCount: nil)
        #expect(counts.isEmpty)
        #expect(counts.resultCount(forRenderedText: Self.genresText) == nil)
    }

    @Test("The join is by ANSWER, so two tools recorded in one turn do not cross over")
    func countsAreJoinedByAnswerNotByOrder() {
        // The SDK may run a round's tool calls concurrently, so completion order
        // need not be transcript order. Keying on the text each call returned is
        // what makes the pairing exact regardless.
        var counts = ChatToolResultCounts()
        counts.record(renderedText: Self.searchText, resultCount: 12)
        counts.record(renderedText: Self.genresText, resultCount: 3)

        let events = AssistantChatEventMapping.events(
            from: [
                .toolOutput(name: "list_genres", text: Self.genresText),
                .toolOutput(name: "search_tracks", text: Self.searchText),
            ],
            counts: counts
        )
        #expect(events == [
            .toolResult(name: "list_genres", summary: Self.genresText, resultCount: 3),
            .toolResult(name: "search_tracks", summary: Self.searchText, resultCount: 12),
        ])
    }

    @Test("A turn's activity pairs every call with its own result, in call order")
    func activityPairsCallsWithResults() {
        let turn = AssistantChatTurn(text: "…", events: [
            .toolCall(name: "list_genres"),
            .toolResult(name: "list_genres", summary: "a", resultCount: 3),
            .toolCall(name: "search_tracks"),
            .toolResult(name: "search_tracks", summary: "b", resultCount: 12),
            .assistantText("…"),
        ])
        #expect(turn.toolActivity == [
            AssistantChatActivity(name: "list_genres", resultCount: 3),
            AssistantChatActivity(name: "search_tracks", resultCount: 12),
        ])
        #expect(turn.toolActivity.map(\.name) == turn.calledToolNames)
    }

    @Test("Two calls to the SAME tool keep their own counts, first answer to first call")
    func repeatedToolCallsKeepTheirOwnCounts() {
        let activity = AssistantChatEvent.activity(in: [
            .toolCall(name: "search_tracks"),
            .toolCall(name: "search_tracks"),
            .toolResult(name: "search_tracks", summary: "a", resultCount: 12),
            .toolResult(name: "search_tracks", summary: "b", resultCount: 1),
        ])
        #expect(activity == [
            AssistantChatActivity(name: "search_tracks", resultCount: 12),
            AssistantChatActivity(name: "search_tracks", resultCount: 1),
        ])
    }

    @Test("A call that never got an answer reports no count rather than borrowing another's")
    func unansweredCallReportsNoCount() {
        // The connector tier can end a turn mid-round on an exhausted tool budget.
        let activity = AssistantChatEvent.activity(in: [
            .toolCall(name: "search_tracks"),
            .toolResult(name: "search_tracks", summary: "a", resultCount: 12),
            .toolCall(name: "search_tracks"),
        ])
        #expect(activity == [
            AssistantChatActivity(name: "search_tracks", resultCount: 12),
            AssistantChatActivity(name: "search_tracks", resultCount: nil),
        ])
    }

    @Test("The ledger clears, so a turn is never joined against an earlier turn's answers")
    func ledgerResets() async {
        let ledger = LibraryChatToolCounts()
        await ledger.record(renderedText: Self.genresText, resultCount: 3)
        #expect(await ledger.snapshot().resultCount(forRenderedText: Self.genresText) == 3)
        await ledger.reset()
        #expect(await ledger.snapshot().isEmpty)
    }
}

// MARK: - Budget

@Suite("LibraryChat budget")
struct LibraryChatBudgetTests {
    @Test("The character estimate rounds UP, because an under-estimate overflows")
    func estimatesTokensRoundingUp() {
        #expect(LibraryChatBudget.estimatedTokens(forCharacters: 0) == 0)
        #expect(LibraryChatBudget.estimatedTokens(forCharacters: 1) == 1)
        #expect(LibraryChatBudget.estimatedTokens(forCharacters: 4) == 1)
        #expect(LibraryChatBudget.estimatedTokens(forCharacters: 5) == 2)
        #expect(LibraryChatBudget.estimatedTokens(forCharacters: 4096) == 1024)
        // A negative count cannot arise from a `String.count`, but the guard must
        // not turn one into a negative token budget if it ever does.
        #expect(LibraryChatBudget.estimatedTokens(forCharacters: -10) == 0)
    }

    @Test("Every entry kind contributes its characters to the estimate")
    func countsEveryEntryKind() {
        let entries: [ChatTranscriptEntry] = [
            .instructions("abcd"),
            .prompt("efgh"),
            .toolCalls(["ij", "kl"]),
            .toolOutput(name: "mn", text: "op"),
            .response("qrst"),
        ]
        #expect(entries.map(\.characterCount) == [4, 4, 4, 4, 4])
        #expect(LibraryChatBudget.estimatedTokens(for: entries) == 5)
    }

    @Test("Condensation fires at half the window, not at the brink")
    func condensesAtHalfTheWindow() {
        // A threshold that only fired at 90% would fire during a turn it could no
        // longer rescue: the turn still has to fit a prompt, up to five tool
        // round-trips and an answer.
        #expect(LibraryChatBudget.shouldCondense(usedTokens: 2048, contextSize: 4096))
        #expect(LibraryChatBudget.shouldCondense(usedTokens: 2047, contextSize: 4096) == false)
        #expect(LibraryChatBudget.shouldCondense(usedTokens: 0, contextSize: 4096) == false)
    }

    @Test("A non-positive contextSize falls back to the assumed window, never to no limit")
    func treatsBadContextSizeAsTheAssumedWindow() {
        #expect(LibraryChatBudget.assumedContextSize == 4096)
        #expect(LibraryChatBudget.shouldCondense(usedTokens: 2048, contextSize: 0))
        #expect(LibraryChatBudget.shouldCondense(usedTokens: 2047, contextSize: -1) == false)
    }

    @Test("Condensation keeps the first and last entries and nothing else")
    func selectsFirstAndLast() {
        #expect(LibraryChatBudget.condensationSelection(entryCount: 0).isEmpty)
        #expect(LibraryChatBudget.condensationSelection(entryCount: 1) == [0])
        #expect(LibraryChatBudget.condensationSelection(entryCount: 2) == [0, 1])
        #expect(LibraryChatBudget.condensationSelection(entryCount: 7) == [0, 6])
    }

    @Test("The kept first entry is the one carrying instructions and tool definitions")
    func condensedTranscriptKeepsInstructions() {
        // Dropping entry 0 would rebuild a session with no tools and no grounding —
        // a silent capability loss, not a visible failure. That is the whole reason
        // the selection is "first and last" rather than "the last N".
        let entries: [ChatTranscriptEntry] = [
            .instructions("You are the assistant inside MacAMP."),
            .prompt("first question"),
            .response("first answer"),
            .prompt("second question"),
            .response("second answer"),
        ]
        #expect(LibraryChatBudget.condensed(entries) == [entries[0], entries[4]])
    }

    @Test("Condensing a transcript that cannot shrink is a no-op, so the policy terminates")
    func condensationTerminates() {
        let short: [ChatTranscriptEntry] = [.instructions("i"), .response("r")]
        #expect(LibraryChatBudget.condensed(short) == short)
        #expect(LibraryChatBudget.condensed(LibraryChatBudget.condensed(short)) == short)
        #expect(LibraryChatBudget.condensed([]).isEmpty)
    }
}
