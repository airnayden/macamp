// ConnectorChatEngineTests — the composition W4 will hold.
//
// Three things are asserted here and nowhere else, because they are properties of
// the COMPOSITION rather than of the loop or of a wire format: the event
// transcript a shell renders arrives in the right order with real toolbox
// results behind it; history goes in and comes back out without this type
// storing any; and what is SENT is bounded while what is RETURNED is not.
import AIConnectorBridge
import AIConnectorKit
import Foundation
import Services
import Testing

@Suite("ConnectorChatEngineTests")
struct ConnectorChatEngineTests {
    private static func engine(
        _ scripts: [ScriptedToolConnector.Script],
        toolbox: FakeToolPublisher,
        profile: ToolProfile = .cloud
    ) -> (engine: ConnectorChatEngine, connector: ScriptedToolConnector) {
        let connector = ScriptedToolConnector(scripts)
        return (
            ConnectorChatEngine(
                connector: connector,
                model: "fixture-model",
                tools: LibraryToolAdapter.aiTools(toolbox, profile: profile),
                instructions: "Answer with the library."
            ),
            connector
        )
    }

    private static let searchCall = ToolCall(
        id: "call_01",
        name: "search_tracks",
        argumentsJSON: "{\"query\":\"shoegaze\"}"
    )

    // MARK: - Event ordering

    @Test("The event transcript is ordered, and each result is the toolbox's own answer")
    func eventTranscriptIsOrderedAndReal() async throws {
        let toolbox = FakeToolPublisher.standard()
        let (engine, _) = Self.engine([
            .calls([Self.searchCall]),
            .text("Here are five."),
        ], toolbox: toolbox)

        let turn = try await engine.reply(to: "make me a shoegaze mix")

        #expect(turn.text == "Here are five.")
        #expect(turn.termination == .answered)
        #expect(turn.rounds == 2)
        #expect(turn.events == [
            .toolCall(name: "search_tracks", argumentsJSON: "{\"query\":\"shoegaze\"}"),
            .toolResult(name: "search_tracks", text: "ran search_tracks", resultCount: nil),
            .assistantText("Here are five."),
        ])
        // The result really came through the toolbox, at the `.cloud` tier.
        #expect(toolbox.calls == [
            FakeToolCall(name: "search_tracks", profile: .cloud, keys: ["query"]),
        ])
    }

    @Test("Parallel calls keep emission order through the composition")
    func parallelCallsKeepOrder() async throws {
        let toolbox = FakeToolPublisher.standard()
        let calls = [
            Self.searchCall,
            ToolCall(id: "call_02", name: "list_genres", argumentsJSON: ""),
        ]
        let (engine, _) = Self.engine([.calls(calls), .text("done")], toolbox: toolbox)

        let turn = try await engine.reply(to: "what do I own?")

        #expect(turn.events == [
            .toolCall(name: "search_tracks", argumentsJSON: "{\"query\":\"shoegaze\"}"),
            .toolResult(name: "search_tracks", text: "ran search_tracks", resultCount: nil),
            .toolCall(name: "list_genres", argumentsJSON: ""),
            .toolResult(name: "list_genres", text: "ran list_genres", resultCount: nil),
            .assistantText("done"),
        ])
        #expect(toolbox.calls.map(\.name) == ["search_tracks", "list_genres"])
        // The empty argument string reached `list_genres` as an empty read, not
        // as a refusal.
        #expect(toolbox.calls[1].keys.isEmpty)
    }

    @Test("A tool the connector invents is answered in prose and never reaches the toolbox")
    func hallucinatedToolNeverReachesTheToolbox() async throws {
        let toolbox = FakeToolPublisher.standard()
        let ghost = ToolCall(id: "call_x", name: "delete_library", argumentsJSON: "{}")
        let (engine, _) = Self.engine([.calls([ghost]), .text("sorry")], toolbox: toolbox)

        let turn = try await engine.reply(to: "delete everything")

        #expect(turn.termination == .answered)
        #expect(toolbox.calls.isEmpty)
        #expect(turn.events.contains { event in
            guard case let .toolResult(_, text, _, _, _) = event else { return false }
            return text.contains("delete_library") && text.contains("search_tracks")
        })
    }

    // MARK: - History

    @Test("History goes in, comes back out grown by two, and is stored nowhere")
    func historyIsReturnedNotStored() async throws {
        let toolbox = FakeToolPublisher.standard()
        // Two identical rounds, because the assertion is that the SECOND call
        // sees the same request as the first — which needs the connector to
        // answer the same way, not to fall through to its exhausted-script
        // fallback.
        let (engine, connector) = Self.engine([.text("Sure."), .text("Sure.")], toolbox: toolbox)
        let prior: [ChatMessage] = [.user("earlier"), .assistant("previous answer")]

        let turn = try await engine.reply(to: "and now?", history: prior)

        #expect(turn.history == prior + [.user("and now?"), .assistant("Sure.")])
        // Nothing was retained: a second call with the SAME prior history sees
        // exactly the same request.
        let second = try await engine.reply(to: "and now?", history: prior)
        #expect(second.history == turn.history)
        #expect(connector.recordedRequests.count == 2)
        #expect(connector.recordedRequests[0].messages == connector.recordedRequests[1].messages)
    }

    @Test("An answerless turn records the question but not an empty answer")
    func answerlessTurnDoesNotStoreABlankAssistantMessage() async throws {
        let toolbox = FakeToolPublisher.standard()
        let connector = ScriptedToolConnector([.calls([Self.searchCall]), .calls([Self.searchCall])])
        let engine = ConnectorChatEngine(
            connector: connector,
            model: "fixture-model",
            tools: LibraryToolAdapter.aiTools(toolbox),
            instructions: "Answer with the library.",
            loop: ToolLoopEngine(maxToolRounds: 2)
        )

        let turn = try await engine.reply(to: "make me a mix")

        #expect(turn.termination == .toolBudgetExhausted)
        #expect(turn.text.isEmpty)
        // An empty assistant message would be re-sent on every later round and
        // rendered as an empty bubble by any shell that trusts the history.
        #expect(turn.history == [.user("make me a mix")])
    }

    @Test("What is SENT is capped; what is RETURNED is not")
    func historyIsCappedOnTheWireOnly() async throws {
        let toolbox = FakeToolPublisher.standard()
        let (engine, connector) = Self.engine([.text("ok")], toolbox: toolbox)
        let long = (0 ..< 60).map { ChatMessage.user("turn \($0)") }

        let turn = try await engine.reply(to: "and now?", history: long)

        let sent = try #require(connector.recordedRequests.first)
        // Every round re-sends the whole prose history on all four wire formats,
        // so an uncapped one is an unbounded request body.
        #expect(sent.messages.count == ConnectorChatEngine.maxHistoryMessages + 1)
        #expect(sent.messages.last == .user("and now?"))
        #expect(sent.messages.first == .user("turn 40"))
        // The caller still gets everything back, so a shell can render the whole
        // conversation.
        #expect(turn.history.count == long.count + 2)
    }

    @Test("Instructions and model reach the connector on every round")
    func framingReachesTheConnector() async throws {
        let toolbox = FakeToolPublisher.standard()
        let (engine, connector) = Self.engine([
            .calls([Self.searchCall]),
            .text("done"),
        ], toolbox: toolbox)

        _ = try await engine.reply(to: "hello")

        #expect(connector.recordedRequests.count == 2)
        for request in connector.recordedRequests {
            #expect(request.instructions == "Answer with the library.")
            #expect(request.model == "fixture-model")
            #expect(request.tools.map(\.name) == ["search_tracks", "list_genres"])
        }
    }

    @Test("The tier the tools were adapted at is the tier the toolbox is called at")
    func adaptedTierGovernsExecution() async throws {
        let toolbox = FakeToolPublisher.standard()
        let (engine, _) = Self.engine(
            [.calls([Self.searchCall]), .text("done")],
            toolbox: toolbox,
            profile: .external
        )

        _ = try await engine.reply(to: "hello")
        #expect(toolbox.calls.map(\.profile) == [.external])
    }

    // MARK: - Failures

    @Test("A connector failure propagates unchanged rather than becoming an empty turn")
    func connectorFailurePropagates() async throws {
        let toolbox = FakeToolPublisher.standard()
        let (engine, _) = Self.engine([.failure(.rateLimited(retryAfter: 30))], toolbox: toolbox)

        await #expect(throws: ConnectorFailure.rateLimited(retryAfter: 30)) {
            _ = try await engine.reply(to: "hello")
        }
    }
}
