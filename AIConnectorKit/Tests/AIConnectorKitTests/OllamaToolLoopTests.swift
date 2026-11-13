// OllamaToolLoopTests — the native `/api/chat` tool round, proved on the wire.
//
// Two facts make this provider unlike the other three, and each gets a case that
// would fail if the adapter treated it like OpenAI:
//
//   1. `function.arguments` arrives ALREADY PARSED, as a JSON object. The fixture
//      carries an object, and the assertion is that it is re-serialised
//      canonically into ``ToolCall/argumentsJSON`` so a tool sees the same shape
//      it would from any other provider.
//   2. THERE IS NO CALL ID. Results go back keyed by `tool_name` and matched by
//      POSITION, so the same-name-twice case is asserted explicitly — it is the
//      one shape where order is the only thing distinguishing two answers.
import AIConnectorKit
import Foundation
import Testing

@Suite("OllamaToolLoopTests")
struct OllamaToolLoopTests {
    private static let model = "llama-fixture:latest"
    private static let chatURL = "http://127.0.0.1:11434/api/chat"

    private static func connector(_ transport: FakeHTTPTransport) -> OllamaConnector {
        OllamaConnector(transport: transport)
    }

    private static func request(_ tools: [AITool]) -> ToolLoopRequest {
        ToolLoopRequest(
            instructions: "Be useful.",
            userText: "make me a shoegaze mix",
            tools: tools,
            model: model
        )
    }

    /// `arguments` is an OBJECT here — the whole point of this suite.
    private static let toolCallRound = """
    {"model":"llama-fixture:latest","message":{"role":"assistant","content":"",
     "tool_calls":[{"function":{"name":"search_tracks",
      "arguments":{"query":"shoegaze","limit":5}}}]},"done":true,"done_reason":"stop"}
    """

    private static let answerRound = """
    {"model":"llama-fixture:latest","message":{"role":"assistant","content":"Here are five."},"done":true}
    """

    // MARK: - Two-round loop

    @Test("A two-round turn re-serialises the pre-parsed arguments object canonically")
    func twoRoundTurnNormalisesObjectArguments() async throws {
        let recorder = ToolRecorder(["search_tracks": ["Found 5 tracks."]])
        let transport = FakeHTTPTransport(scripts: [
            .success(jsonResponse(Self.toolCallRound)),
            .success(jsonResponse(Self.answerRound)),
        ])

        let outcome = try await ToolLoopEngine().run(
            Self.request([recorder.tool("search_tracks", schema: ToolFixture.looseSchema)]),
            connector: Self.connector(transport)
        )

        #expect(outcome.text == "Here are five.")
        #expect(outcome.termination == .answered)
        #expect(outcome.rounds == 2)
        // Canonical `.sortedKeys` text, so a tool written against any other
        // provider parses this one unchanged.
        #expect(recorder.invocations == [
            ToolInvocation(name: "search_tracks", argumentsJSON: "{\"limit\":5,\"query\":\"shoegaze\"}"),
        ])
        // The empty `content` of the tool-calling round produces NO
        // `.assistantText` event — an empty bubble is not something to render.
        #expect(outcome.events == [
            .toolCall(name: "search_tracks", argumentsJSON: "{\"limit\":5,\"query\":\"shoegaze\"}"),
            .toolResult(name: "search_tracks", text: "Found 5 tracks.", resultCount: nil),
            .assistantText("Here are five."),
        ])
    }

    @Test("The first request sends the nested envelope WITHOUT `strict`, and stream: false")
    func firstRequestShape() async throws {
        let recorder = ToolRecorder()
        let transport = FakeHTTPTransport(scripts: [
            .success(jsonResponse(Self.toolCallRound)),
            .success(jsonResponse(Self.answerRound)),
        ])

        _ = try await ToolLoopEngine().run(
            Self.request([recorder.tool("search_tracks")]),
            connector: Self.connector(transport)
        )

        #expect(await transport.recordedRequests.first?.url?.absoluteString == Self.chatURL)
        let body = try #require(await recordedJSONBody(transport, at: 0))
        // Omitting this is not "a slower path" — Ollama would answer with
        // newline-delimited JSON objects, which is not one document.
        #expect(body["stream"] == .bool(false))

        let tools = try #require(body["tools"]?.arrayValue)
        #expect(tools[0]["type"]?.stringValue == "function")
        let function = try #require(tools[0]["function"])
        #expect(function["name"]?.stringValue == "search_tracks")
        #expect(function["parameters"] == ToolFixture.strictSchema)
        // Ollama does not document `strict`, and constrains decoding itself.
        #expect(function["strict"] == nil)

        let messages = try #require(body["messages"]?.arrayValue)
        #expect(messages == [
            .object(["role": .string("system"), "content": .string("Be useful.")]),
            .object(["role": .string("user"), "content": .string("make me a shoegaze mix")]),
        ])
    }

    @Test("Results go back as `role: tool` messages keyed by tool_name, with no call id anywhere")
    func replyShapeIsNameKeyed() async throws {
        let recorder = ToolRecorder(["search_tracks": ["Found 5 tracks."]])
        let transport = FakeHTTPTransport(scripts: [
            .success(jsonResponse(Self.toolCallRound)),
            .success(jsonResponse(Self.answerRound)),
        ])

        _ = try await ToolLoopEngine().run(
            Self.request([recorder.tool("search_tracks")]),
            connector: Self.connector(transport)
        )

        let messages = try #require(await recordedJSONBody(transport, at: 1)?["messages"]?.arrayValue)
        #expect(messages.count == 4)

        let assistant = messages[2]
        #expect(assistant["role"]?.stringValue == "assistant")
        #expect(assistant["tool_calls"]?.arrayValue?.count == 1)

        #expect(messages[3] == .object([
            "role": .string("tool"),
            "content": .string("Found 5 tracks."),
            "tool_name": .string("search_tracks"),
        ]))
        // There is no call-id concept on this wire, in either direction.
        #expect(messages[3]["tool_call_id"] == nil)
    }

    @Test("Two calls to the SAME tool are answered in emission order — the only thing that pairs them")
    func sameNameParallelCallsKeepOrder() async throws {
        let parallel = """
        {"model":"llama-fixture:latest","message":{"role":"assistant","content":"","tool_calls":[
          {"function":{"name":"search_tracks","arguments":{"query":"shoegaze"}}},
          {"function":{"name":"search_tracks","arguments":{"query":"dream pop"}}}]},"done":true}
        """
        let recorder = ToolRecorder(["search_tracks": ["shoegaze rows", "dream pop rows"]])
        let transport = FakeHTTPTransport(scripts: [
            .success(jsonResponse(parallel)),
            .success(jsonResponse(Self.answerRound)),
        ])

        _ = try await ToolLoopEngine().run(
            Self.request([recorder.tool("search_tracks")]),
            connector: Self.connector(transport)
        )

        #expect(recorder.invocations.map(\.argumentsJSON) == [
            "{\"query\":\"shoegaze\"}",
            "{\"query\":\"dream pop\"}",
        ])

        let messages = try #require(await recordedJSONBody(transport, at: 1)?["messages"]?.arrayValue)
        let toolMessages = messages.filter { $0["role"]?.stringValue == "tool" }
        // Both carry the SAME `tool_name`, so ORDER is the only thing that says
        // which answer belongs to which question. Sorting or de-duplicating these
        // would silently swap two answers.
        #expect(toolMessages.compactMap { $0["tool_name"]?.stringValue }
            == ["search_tracks", "search_tracks"])
        #expect(toolMessages.compactMap { $0["content"]?.stringValue }
            == ["shoegaze rows", "dream pop rows"])
    }

    // MARK: - Failures

    @Test("A warm-up round with neither prose nor a call is malformedResponse")
    func contentlessRoundIsMalformed() async throws {
        let bodies = [
            "<html>",
            "{\"done\":true}",
            "{\"model\":\"m\",\"message\":{\"role\":\"assistant\",\"content\":\"\"},\"done_reason\":\"load\"}",
        ]
        for body in bodies {
            let transport = FakeHTTPTransport(scripts: [.success(jsonResponse(body))])
            await #expect(throws: ConnectorFailure.malformedResponse) {
                _ = try await ToolLoopEngine().run(Self.request([]), connector: Self.connector(transport))
            }
        }
    }

    @Test("A never-responding server is bounded by the loop's per-round deadline")
    func neverRespondingServerIsBounded() async throws {
        let transport = FakeHTTPTransport(scripts: [.neverRespond])
        await #expect(throws: ConnectorFailure.timeout) {
            _ = try await ToolLoopEngine(roundDeadlineSeconds: 0.05)
                .run(Self.request([]), connector: Self.connector(transport))
        }
    }

    @Test("An Ollama Cloud key rides the same Authorization header on a tool round")
    func cloudKeyIsSentOnToolRounds() async throws {
        let transport = FakeHTTPTransport(scripts: [.success(jsonResponse(Self.answerRound))])
        let connector = OllamaConnector(apiKey: { "test-ollama-cloud-key" }, transport: transport)

        _ = try await ToolLoopEngine().run(Self.request([]), connector: connector)

        let sent = try #require(await transport.recordedRequests.first)
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer test-ollama-cloud-key")
    }
}
