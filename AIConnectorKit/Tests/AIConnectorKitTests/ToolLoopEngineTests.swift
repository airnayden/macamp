// ToolLoopEngineTests — the three bounds and the event contract.
//
// The bounds (rounds, per-round deadline, result size) are the whole safety
// property of the loop, and none of them is enforced by any provider — so each
// gets an assertion that fails if the bound is removed rather than merely
// loosened. The event ordering is asserted as an exact array because "in order"
// is what a shell renders from, and a partial assertion would pass on a
// transcript that interleaved two calls' results.
import AIConnectorKit
import Foundation
import Testing

@Suite("ToolLoopEngineTests")
struct ToolLoopEngineTests {
    private static func request(
        _ tools: [AITool],
        userText: String = "make me a shoegaze mix",
        history: [ChatMessage] = []
    ) -> ToolLoopRequest {
        ToolLoopRequest(
            instructions: "Be useful.",
            history: history,
            userText: userText,
            tools: tools,
            model: "fixture-model"
        )
    }

    private static let searchCall = ToolCall(
        id: "call_1",
        name: "search_tracks",
        argumentsJSON: "{\"query\":\"shoegaze\"}"
    )

    // MARK: - Ordering

    @Test("A two-round turn emits assistant text, then each call paired with its own result")
    func eventsArePairedAndOrdered() async throws {
        let recorder = ToolRecorder(["search_tracks": ["Found 5 tracks."]])
        let connector = FakeToolCallingConnector([
            .calls([Self.searchCall], text: "Let me look."),
            .text("Here are five."),
        ])

        let outcome = try await ToolLoopEngine().run(
            Self.request([recorder.tool("search_tracks")]),
            connector: connector
        )

        #expect(outcome.text == "Here are five.")
        #expect(outcome.termination == .answered)
        #expect(outcome.rounds == 2)
        #expect(outcome.events == [
            .assistantText("Let me look."),
            .toolCall(name: "search_tracks", argumentsJSON: "{\"query\":\"shoegaze\"}"),
            .toolResult(name: "search_tracks", text: "Found 5 tracks.", resultCount: nil),
            .assistantText("Here are five."),
        ])
        #expect(recorder.invocations.map(\.name) == ["search_tracks"])
    }

    @Test("A tool's result count reaches the event unchanged")
    func resultCountReachesTheEvent() async throws {
        let recorder = ToolRecorder(
            ["search_tracks": ["Found 12 tracks."]],
            resultCounts: ["search_tracks": 12]
        )
        let connector = FakeToolCallingConnector([.calls([Self.searchCall]), .text("done")])

        let outcome = try await ToolLoopEngine().run(
            Self.request([recorder.tool("search_tracks")]),
            connector: connector
        )

        #expect(outcome.events.contains(
            .toolResult(name: "search_tracks", text: "Found 12 tracks.", resultCount: 12)
        ))
        // The count is the SHELL's; a provider is still handed only the text.
        let second = try #require(connector.recordedRequests.dropFirst().first)
        #expect(second.outcomes.map(\.text) == ["Found 12 tracks."])
    }

    @Test("A tool that reports no count produces a nil one, not a zero")
    func absentResultCountStaysAbsent() async throws {
        let recorder = ToolRecorder(["search_tracks": ["Filed a proposal."]])
        let connector = FakeToolCallingConnector([.calls([Self.searchCall]), .text("done")])

        let outcome = try await ToolLoopEngine().run(
            Self.request([recorder.tool("search_tracks")]),
            connector: connector
        )

        let counts = outcome.events.compactMap { event -> Int?? in
            guard case let .toolResult(_, _, resultCount, _, _) = event else { return nil }
            return resultCount
        }
        #expect(counts.count == 1)
        #expect(counts[0] == nil)
    }

    @Test("Parallel calls are executed and announced in the order the model emitted them")
    func parallelCallsKeepEmissionOrder() async throws {
        let recorder = ToolRecorder(["search_tracks": ["first answer", "second answer"]])
        let calls = [
            ToolCall(id: "call_a", name: "search_tracks", argumentsJSON: "{\"query\":\"a\"}"),
            ToolCall(id: "call_b", name: "search_tracks", argumentsJSON: "{\"query\":\"b\"}"),
        ]
        let connector = FakeToolCallingConnector([.calls(calls), .text("done")])

        let outcome = try await ToolLoopEngine().run(
            Self.request([recorder.tool("search_tracks")]),
            connector: connector
        )

        #expect(recorder.invocations.map(\.argumentsJSON) == ["{\"query\":\"a\"}", "{\"query\":\"b\"}"])
        #expect(outcome.events == [
            .toolCall(name: "search_tracks", argumentsJSON: "{\"query\":\"a\"}"),
            .toolResult(name: "search_tracks", text: "first answer", resultCount: nil),
            .toolCall(name: "search_tracks", argumentsJSON: "{\"query\":\"b\"}"),
            .toolResult(name: "search_tracks", text: "second answer", resultCount: nil),
            .assistantText("done"),
        ])
        // Both outcomes reach the NEXT round together — a wire format that can
        // only answer one call per message would fail here rather than at runtime.
        let second = try #require(connector.recordedRequests.dropFirst().first)
        #expect(second.outcomes.map(\.call.id) == ["call_a", "call_b"])
        #expect(second.outcomes.map(\.text) == ["first answer", "second answer"])
    }

    @Test("The current user turn is appended to the history the connector receives")
    func historyCarriesTheCurrentUserTurn() async throws {
        let connector = FakeToolCallingConnector([.text("hi")])
        _ = try await ToolLoopEngine().run(
            Self.request([], userText: "what do I own?", history: [.user("earlier"), .assistant("answer")]),
            connector: connector
        )

        let sent = try #require(connector.recordedRequests.first)
        #expect(sent.messages == [.user("earlier"), .assistant("answer"), .user("what do I own?")])
        #expect(sent.instructions == "Be useful.")
        #expect(sent.transcript.isEmpty)
        #expect(sent.outcomes.isEmpty)
    }

    @Test("The transcript a round returns is the transcript the next round receives")
    func transcriptIsCarriedForward() async throws {
        let recorder = ToolRecorder()
        let connector = FakeToolCallingConnector([
            .calls([Self.searchCall]),
            .calls([Self.searchCall]),
            .text("done"),
        ])

        _ = try await ToolLoopEngine().run(
            Self.request([recorder.tool("search_tracks")]),
            connector: connector
        )

        let sent = connector.recordedRequests
        #expect(sent.count == 3)
        #expect(sent[0].transcript.items.isEmpty)
        #expect(sent[1].transcript.items.count == 1)
        #expect(sent[2].transcript.items.count == 2)
    }

    // MARK: - Bounds

    @Test("Hitting the round cap is a TYPED terminal state carrying whatever prose exists")
    func roundCapIsTypedAndNotSilent() async throws {
        let recorder = ToolRecorder()
        // A model that never stops calling: the fallback script keeps emitting.
        let connector = FakeToolCallingConnector([], fallback: .calls([Self.searchCall], text: "still working"))

        let outcome = try await ToolLoopEngine(maxToolRounds: 3).run(
            Self.request([recorder.tool("search_tracks")]),
            connector: connector
        )

        #expect(outcome.termination == .toolBudgetExhausted)
        #expect(outcome.rounds == 3)
        // NOT a silent stop: the text the model did produce survives.
        #expect(outcome.text == "still working")
        #expect(recorder.invocations.count == 3)
        #expect(connector.recordedRequests.count == 3)
    }

    @Test("A zero budget performs no provider call at all")
    func zeroBudgetPerformsNoCall() async throws {
        let connector = FakeToolCallingConnector()
        let outcome = try await ToolLoopEngine(maxToolRounds: 0).run(Self.request([]), connector: connector)

        #expect(outcome.termination == .toolBudgetExhausted)
        #expect(outcome.rounds == 0)
        #expect(outcome.text.isEmpty)
        #expect(connector.recordedRequests.isEmpty)
    }

    @Test("Every round is deadline-bounded, and the loser is cancelled")
    func everyRoundIsDeadlineBounded() async throws {
        let connector = FakeToolCallingConnector([.never])

        await #expect(throws: ConnectorFailure.timeout) {
            _ = try await ToolLoopEngine(maxToolRounds: 5, roundDeadlineSeconds: 0.05)
                .run(Self.request([]), connector: connector)
        }
    }

    @Test("The deadline is PER ROUND, so a fast first round does not spend the second's budget")
    func deadlineIsPerRoundNotPerTurn() async throws {
        let recorder = ToolRecorder()
        let connector = FakeToolCallingConnector([
            .calls([Self.searchCall]),
            .calls([Self.searchCall]),
            .text("done"),
        ])

        // Three rounds under a 0.5 s PER-ROUND budget. A per-turn budget of the
        // same size would still pass here, so the discriminating assertion is
        // the one above: `.never` fails at 0.05 s no matter which round it is in.
        let outcome = try await ToolLoopEngine(maxToolRounds: 5, roundDeadlineSeconds: 0.5).run(
            Self.request([recorder.tool("search_tracks")]),
            connector: connector
        )
        #expect(outcome.termination == .answered)
        #expect(outcome.rounds == 3)
    }

    @Test("A connector failure propagates unchanged rather than becoming an empty answer")
    func connectorFailurePropagates() async throws {
        let connector = FakeToolCallingConnector([.failure(.authExpired)])
        await #expect(throws: ConnectorFailure.authExpired) {
            _ = try await ToolLoopEngine().run(Self.request([]), connector: connector)
        }
    }

    @Test("An oversized tool result is clamped and marked as truncated")
    func oversizedResultIsClamped() async throws {
        let huge = String(repeating: "x", count: ToolLoopEngine.maxToolResultCharacters + 500)
        let recorder = ToolRecorder(["search_tracks": [huge]])
        let connector = FakeToolCallingConnector([.calls([Self.searchCall]), .text("done")])

        let outcome = try await ToolLoopEngine().run(
            Self.request([recorder.tool("search_tracks")]),
            connector: connector
        )

        let result = try #require(outcome.events.compactMap { event -> String? in
            guard case let .toolResult(_, text, _, _, _) = event else { return nil }
            return text
        }.first)
        #expect(result.count == ToolLoopEngine.maxToolResultCharacters)
        #expect(result.hasSuffix(ToolLoopEngine.truncationMarker))
    }

    @Test("A result inside the cap passes through byte-identical")
    func inBoundsResultIsUntouched() async throws {
        let exact = String(repeating: "y", count: ToolLoopEngine.maxToolResultCharacters)
        let recorder = ToolRecorder(["search_tracks": [exact]])
        let connector = FakeToolCallingConnector([.calls([Self.searchCall]), .text("done")])

        let outcome = try await ToolLoopEngine().run(
            Self.request([recorder.tool("search_tracks")]),
            connector: connector
        )
        #expect(outcome.events.contains(.toolResult(name: "search_tracks", text: exact, resultCount: nil)))
    }

    // MARK: - Unknown tools

    @Test("A hallucinated tool name is answered in prose, never thrown")
    func unknownToolIsAnsweredNotThrown() async throws {
        let recorder = ToolRecorder()
        let ghost = ToolCall(id: "call_x", name: "delete_everything", argumentsJSON: "{}")
        let connector = FakeToolCallingConnector([.calls([ghost]), .text("sorry")])

        let outcome = try await ToolLoopEngine().run(
            Self.request([recorder.tool("search_tracks")]),
            connector: connector
        )

        #expect(outcome.termination == .answered)
        #expect(recorder.invocations.isEmpty)
        let result = try #require(outcome.events.compactMap { event -> String? in
            guard case let .toolResult(_, text, _, _, _) = event else { return nil }
            return text
        }.first)
        // The sentence names what IS available, so the model's retry has
        // somewhere to go.
        #expect(result.contains("delete_everything"))
        #expect(result.contains("search_tracks"))
    }

    @Test("A hallucinated call with no tools published still answers in prose")
    func unknownToolWithEmptyToolsetStillAnswers() async throws {
        let ghost = ToolCall(id: "call_x", name: "search_tracks", argumentsJSON: "{}")
        let connector = FakeToolCallingConnector([.calls([ghost]), .text("sorry")])

        let outcome = try await ToolLoopEngine().run(Self.request([]), connector: connector)
        #expect(outcome.termination == .answered)
        #expect(outcome.events.contains { event in
            guard case let .toolResult(_, text, _, _, _) = event else { return false }
            return text.contains("no tools are available")
        })
    }
}
