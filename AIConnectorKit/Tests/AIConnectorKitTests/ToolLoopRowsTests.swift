// ToolLoopRowsTests — the structured half of a tool answer, from ``AIToolOutput``
// to ``ChatEvent``, and the proof that it stops there.
//
// ── THE ROWS ARE FOR THE SHELL, AND ONLY FOR THE SHELL ──────────────────────
//
// A provider is handed ``ToolCallOutcome/text`` and nothing else. That is already
// true of `resultCount`, but rows make it load-bearing rather than tidy: a track
// list is listener data, and re-sending it every subsequent round would spend
// context on material the model has already read as prose — on every round, for
// the listener who uses the feature most.
//
// So the negative is pinned at the WIRE, over three real connectors driven by
// `FakeHTTPTransport`, in exactly the shape `ToolLoopSecretLeakTests` uses for a
// credential: "it must never appear in a request body" is the same assertion, and
// asserting it on the BODY rather than on a value type is what makes it hold for
// inputs these fixtures never tried.
//
// Every row sentinel is `sentinel-` prefixed so one substring catches a leak
// through any of the four wire formats' encodings.
import AIConnectorKit
import Foundation
import Testing

@Suite("ToolLoopRowsTests")
struct ToolLoopRowsTests {
    private static let rowTitle = "sentinel-row-title-alpha"
    private static let rowArtist = "sentinel-row-artist-alpha"
    private static let missTitle = "sentinel-miss-title-alpha"
    private static let trackId: Int64 = 987_654_321
    private static let answerText = "Found 1 track."

    private static let rows = [AIToolRow(trackId: trackId, title: rowTitle, artist: rowArtist)]
    private static let suggestions = [AIToolSuggestion(title: missTitle, artist: rowArtist)]

    /// Everything that must never reach a provider: the row CONTENT, and the keys
    /// a serialiser would have had to invent to carry it.
    private static let forbiddenInBodies = [
        rowTitle, rowArtist, missTitle, "\(trackId)",
        "\"rows\"", "\"suggestions\"", "\"trackId\"",
    ]

    private static let searchCall = ToolCall(
        id: "call_01",
        name: "search_tracks",
        argumentsJSON: "{\"query\":\"shoegaze\"}"
    )

    private static func request(_ tools: [AITool]) -> ToolLoopRequest {
        ToolLoopRequest(
            instructions: "Be useful.",
            userText: "make me a shoegaze mix",
            tools: tools,
            model: "fixture-model"
        )
    }

    private static func recorder(
        rows: [AIToolRow] = ToolLoopRowsTests.rows,
        suggestions: [AIToolSuggestion] = ToolLoopRowsTests.suggestions
    ) -> ToolRecorder {
        ToolRecorder(
            ["search_tracks": [answerText]],
            resultCounts: ["search_tracks": 1],
            rows: ["search_tracks": rows],
            suggestions: ["search_tracks": suggestions]
        )
    }

    // MARK: - Through the loop

    @Test("A tool's rows and suggestions reach the event unchanged")
    func rowsReachTheEvent() async throws {
        let recorder = Self.recorder()
        let connector = FakeToolCallingConnector([.calls([Self.searchCall]), .text("done")])

        let outcome = try await ToolLoopEngine().run(
            Self.request([recorder.tool("search_tracks")]),
            connector: connector
        )

        #expect(outcome.events.contains(.toolResult(
            name: "search_tracks",
            text: Self.answerText,
            resultCount: 1,
            rows: Self.rows,
            suggestions: Self.suggestions
        )))
        // The provider still got the text and only the text.
        let second = try #require(connector.recordedRequests.dropFirst().first)
        #expect(second.outcomes.map(\.text) == [Self.answerText])
    }

    @Test("A tool that answers with no rows produces an empty list, never a placeholder")
    func absentRowsStayAbsent() async throws {
        let recorder = ToolRecorder(["search_tracks": ["Filed a proposal."]])
        let connector = FakeToolCallingConnector([.calls([Self.searchCall]), .text("done")])

        let outcome = try await ToolLoopEngine().run(
            Self.request([recorder.tool("search_tracks")]),
            connector: connector
        )

        #expect(outcome.events.contains(.toolResult(
            name: "search_tracks",
            text: "Filed a proposal.",
            resultCount: nil
        )))
    }

    // MARK: - The cap

    @Test("More rows than the cap allows are clamped, keeping the LEADING ones")
    func oversizedRowSetIsClamped() async throws {
        let over = AIToolOutput.maxRows + 12
        let recorder = Self.recorder(
            rows: (1 ... over).map { AIToolRow(trackId: Int64($0), title: "track \($0)") },
            suggestions: (1 ... over).map { AIToolSuggestion(title: "miss \($0)") }
        )
        let connector = FakeToolCallingConnector([.calls([Self.searchCall]), .text("done")])

        let outcome = try await ToolLoopEngine().run(
            Self.request([recorder.tool("search_tracks")]),
            connector: connector
        )

        let rows = try #require(outcome.events.compactMap { event -> [AIToolRow]? in
            guard case let .toolResult(_, _, _, rows, _) = event else { return nil }
            return rows
        }.first)
        let suggestions = try #require(outcome.events.compactMap { event -> [AIToolSuggestion]? in
            guard case let .toolResult(_, _, _, _, suggestions) = event else { return nil }
            return suggestions
        }.first)

        #expect(rows.count == AIToolOutput.maxRows)
        #expect(suggestions.count == AIToolOutput.maxRows)
        // Which fifty matters: a tool orders its rows by relevance, so the tail is
        // what a cap may drop.
        #expect(rows.first?.trackId == 1)
        #expect(rows.last?.trackId == Int64(AIToolOutput.maxRows))
    }

    // MARK: - The wire

    @Test("No connector ever writes a row into a REQUEST BODY")
    func rowsNeverReachTheWire() async throws {
        try await assertBodiesCarryNoRows(
            rounds: Self.anthropicRounds,
            connector: { AnthropicConnector(auth: .apiKey(provider: { "test-token-a" }), transport: $0) }
        )
        try await assertBodiesCarryNoRows(
            rounds: Self.openAIRounds,
            connector: { OpenAIConnector(apiKey: { "test-token-o" }, transport: $0) }
        )
        try await assertBodiesCarryNoRows(
            rounds: Self.ollamaRounds,
            connector: { OllamaConnector(apiKey: { "test-token-l" }, transport: $0) }
        )
    }

    private func assertBodiesCarryNoRows(
        rounds: [String],
        connector: (FakeHTTPTransport) -> any ToolCallingConnector
    ) async throws {
        let recorder = Self.recorder()
        let transport = FakeHTTPTransport(scripts: rounds.map { .success(jsonResponse($0)) })

        let outcome = try await ToolLoopEngine().run(
            Self.request([recorder.tool("search_tracks")]),
            connector: connector(transport)
        )

        // Guards the assertion below against passing over a turn that produced no
        // rows at all, which every one of these fixtures would otherwise allow.
        let carried = outcome.events.contains { event in
            guard case let .toolResult(_, _, _, rows, suggestions) = event else { return false }
            return rows.isEmpty == false && suggestions.isEmpty == false
        }
        #expect(carried, "The fixture turn really did carry rows")

        let sent = await transport.recordedRequests
        #expect(sent.count == rounds.count)
        for request in sent {
            let body = request.httpBody.flatMap { String(bytes: $0, encoding: .utf8) } ?? ""
            for forbidden in Self.forbiddenInBodies {
                #expect(body.contains(forbidden) == false, "\(forbidden) reached a request body")
            }
            // The TEXT is on the wire, so this is a statement about what rides
            // beside it — not about a round that forgot to answer the tool call.
            #expect(body.isEmpty == false)
        }
        #expect(sent.dropFirst().contains { request in
            let body = request.httpBody.flatMap { String(bytes: $0, encoding: .utf8) } ?? ""
            return body.contains(Self.answerText)
        })
    }

    // MARK: - Provider round fixtures

    private static let anthropicRounds = [
        """
        {"id":"msg_01","stop_reason":"tool_use","content":[
          {"type":"tool_use","id":"toolu_01","name":"search_tracks","input":{"query":"shoegaze"}}]}
        """,
        """
        {"id":"msg_02","stop_reason":"end_turn","content":[{"type":"text","text":"Here is one."}]}
        """,
    ]

    private static let openAIRounds = [
        #"""
        {"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[
          {"id":"call_01","type":"function",
           "function":{"name":"search_tracks","arguments":"{\"query\":\"shoegaze\"}"}}]}}]}
        """#,
        #"{"choices":[{"message":{"role":"assistant","content":"Here is one."}}]}"#,
    ]

    private static let ollamaRounds = [
        """
        {"message":{"role":"assistant","content":"","tool_calls":[
          {"function":{"name":"search_tracks","arguments":{"query":"shoegaze"}}}]},"done":true}
        """,
        """
        {"message":{"role":"assistant","content":"Here is one."},"done":true}
        """,
    ]
}
