// OpenAIToolLoopTests — the Chat Completions tool round, proved on the wire.
//
// The discriminating fact for this provider is that `function.arguments` is a
// JSON ***STRING***, not an object — the fixtures below carry a real escaped
// string, and the assertion is that the model's own text survives byte-for-byte
// rather than being re-serialised. A fixture that used an object would pass
// against a parser that only ever handled objects, which is the Ollama shape and
// the exact confusion this suite exists to prevent.
import AIConnectorKit
import Foundation
import Testing

@Suite("OpenAIToolLoopTests")
struct OpenAIToolLoopTests {
    private static let apiKey = "sk-openai-test-key"
    private static let model = "gpt-fixture-max"
    private static let completionsURL = "https://api.openai.com/v1/chat/completions"

    private static func connector(
        _ transport: FakeHTTPTransport,
        onRefusal: (@Sendable (String) -> Void)? = nil
    ) -> OpenAIConnector {
        OpenAIConnector(apiKey: { OpenAIToolLoopTests.apiKey }, transport: transport, onRefusal: onRefusal)
    }

    private static func request(_ tools: [AITool]) -> ToolLoopRequest {
        ToolLoopRequest(
            instructions: "Be useful.",
            userText: "make me a shoegaze mix",
            tools: tools,
            model: model
        )
    }

    /// `arguments` is a STRING here, with the model's own spacing inside it.
    private static let toolCallRound = #"""
    {"id":"chatcmpl-1","choices":[{"index":0,"finish_reason":"tool_calls",
     "message":{"role":"assistant","content":null,"refusal":null,
      "tool_calls":[{"id":"call_01","type":"function",
       "function":{"name":"search_tracks","arguments":"{\"query\": \"shoegaze\", \"limit\": 5}"}}]}}]}
    """#

    private static let answerRound = """
    {"id":"chatcmpl-2","choices":[{"index":0,"finish_reason":"stop",
     "message":{"role":"assistant","content":"Here are five."}}]}
    """

    // MARK: - Two-round loop

    @Test("A two-round turn parses arguments-as-string and returns the model's prose")
    func twoRoundTurnParsesStringArguments() async throws {
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
        // The model's own text, verbatim — spacing included. Re-serialising would
        // have produced `{"limit":5,"query":"shoegaze"}` instead.
        #expect(recorder.invocations == [
            ToolInvocation(name: "search_tracks", argumentsJSON: "{\"query\": \"shoegaze\", \"limit\": 5}"),
        ])
        #expect(outcome.events == [
            .toolCall(name: "search_tracks", argumentsJSON: "{\"query\": \"shoegaze\", \"limit\": 5}"),
            .toolResult(name: "search_tracks", text: "Found 5 tracks.", resultCount: nil),
            .assistantText("Here are five."),
        ])
    }

    @Test("The first request sends the NESTED function envelope and a bare `auto` tool_choice")
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

        let sent = try #require(await transport.recordedRequests.first)
        #expect(sent.url?.absoluteString == Self.completionsURL)
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.apiKey)")

        let body = try #require(await recordedJSONBody(transport, at: 0))
        // A bare string, NOT the object Anthropic wants.
        #expect(body["tool_choice"] == .string("auto"))

        let tools = try #require(body["tools"]?.arrayValue)
        #expect(tools[0]["type"]?.stringValue == "function")
        let function = try #require(tools[0]["function"])
        #expect(function["name"]?.stringValue == "search_tracks")
        #expect(function["parameters"] == ToolFixture.strictSchema)
        #expect(function["strict"]?.boolValue == true)
        // The schema rides `function.parameters`, never a top-level
        // `input_schema` — that is the Anthropic dialect.
        #expect(tools[0]["input_schema"] == nil)

        let messages = try #require(body["messages"]?.arrayValue)
        #expect(messages == [
            .object(["role": .string("system"), "content": .string("Be useful.")]),
            .object(["role": .string("user"), "content": .string("make me a shoegaze mix")]),
        ])
    }

    @Test("The reply carries the assistant turn's tool_calls, then one `role: tool` message per call")
    func replyShapeIsExact() async throws {
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
        #expect(assistant["content"] == .null)
        let calls = try #require(assistant["tool_calls"]?.arrayValue)
        #expect(calls.count == 1)
        #expect(calls[0]["id"]?.stringValue == "call_01")
        // The call is carried through as the exact value that arrived, so the
        // argument string is not reformatted on the way back either.
        #expect(calls[0]["function"]?["arguments"]?.stringValue == "{\"query\": \"shoegaze\", \"limit\": 5}")
        // Output-only fields are NOT echoed back into the request.
        #expect(assistant["refusal"] == nil)

        #expect(messages[3] == .object([
            "role": .string("tool"),
            "tool_call_id": .string("call_01"),
            "content": .string("Found 5 tracks."),
        ]))
    }

    @Test("Parallel calls produce one `role: tool` message each, in emission order")
    func parallelCallsProduceOneToolMessageEach() async throws {
        let parallel = #"""
        {"id":"chatcmpl-3","choices":[{"message":{"role":"assistant","content":null,"tool_calls":[
          {"id":"call_a","type":"function","function":{"name":"search_tracks","arguments":"{\"query\":\"a\"}"}},
          {"id":"call_b","type":"function","function":{"name":"list_genres","arguments":"{}"}}]}}]}
        """#
        let recorder = ToolRecorder(["search_tracks": ["A tracks."], "list_genres": ["Shoegaze."]])
        let transport = FakeHTTPTransport(scripts: [
            .success(jsonResponse(parallel)),
            .success(jsonResponse(Self.answerRound)),
        ])

        _ = try await ToolLoopEngine().run(
            Self.request([recorder.tool("search_tracks"), recorder.tool("list_genres")]),
            connector: Self.connector(transport)
        )

        let messages = try #require(await recordedJSONBody(transport, at: 1)?["messages"]?.arrayValue)
        let toolMessages = messages.filter { $0["role"]?.stringValue == "tool" }
        #expect(toolMessages.count == 2)
        #expect(toolMessages.compactMap { $0["tool_call_id"]?.stringValue } == ["call_a", "call_b"])
        #expect(toolMessages.compactMap { $0["content"]?.stringValue } == ["A tracks.", "Shoegaze."])
    }

    // MARK: - Refusal

    @Test("A refusal ENDS the turn as the model's own words, and still reaches the refusal sink")
    func refusalBecomesTheAnswerAndReachesTheSink() async throws {
        let refusal = #"{"choices":[{"message":{"role":"assistant","content":null,"refusal":"I cannot help."}}]}"#
        let transport = FakeHTTPTransport(scripts: [.success(jsonResponse(refusal))])
        let box = RefusalBox()

        let outcome = try await ToolLoopEngine().run(
            Self.request([]),
            connector: Self.connector(transport, onRefusal: { box.record($0) })
        )

        // A conversation that got a refusal got a good turn. Reporting
        // `.malformedResponse` — which the one-shot structured path does, for a
        // different and correct reason — would replace the model's sentence with
        // a diagnostic.
        #expect(outcome.text == "I cannot help.")
        #expect(outcome.termination == .answered)
        #expect(box.recorded == ["I cannot help."])
    }

    // MARK: - Failures

    @Test("An unreadable or empty round is malformedResponse, never a crash")
    func unreadableRoundsMapToMalformedResponse() async throws {
        let bodies = [
            "<html>",
            "{\"choices\":[]}",
            "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":null}}]}",
        ]
        for body in bodies {
            let transport = FakeHTTPTransport(scripts: [.success(jsonResponse(body))])
            await #expect(throws: ConnectorFailure.malformedResponse) {
                _ = try await ToolLoopEngine().run(Self.request([]), connector: Self.connector(transport))
            }
        }
    }

    @Test("A never-responding provider is bounded by the loop's per-round deadline")
    func neverRespondingProviderIsBounded() async throws {
        let transport = FakeHTTPTransport(scripts: [.neverRespond])
        await #expect(throws: ConnectorFailure.timeout) {
            _ = try await ToolLoopEngine(roundDeadlineSeconds: 0.05)
                .run(Self.request([]), connector: Self.connector(transport))
        }
    }

    @Test("An unconfigured key never reaches the transport")
    func unconfiguredKeyNeverCallsOut() async throws {
        let blank = FakeHTTPTransport()
        let connector = OpenAIConnector(apiKey: { "  " }, transport: blank)
        await #expect(throws: ConnectorFailure.unconfigured) {
            _ = try await ToolLoopEngine().run(Self.request([]), connector: connector)
        }
        #expect(await blank.recordedRequests.isEmpty)
    }
}

/// Collects refusal text from the connector's `@Sendable` sink.
///
/// A lock-guarded class rather than an actor because the sink is a synchronous
/// `@Sendable` closure, which an actor cannot witness.
final class RefusalBox: @unchecked Sendable {
    private let lock = NSLock()
    private var texts: [String] = []

    func record(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        texts.append(text)
    }

    var recorded: [String] {
        lock.lock()
        defer { lock.unlock() }
        return texts
    }
}
