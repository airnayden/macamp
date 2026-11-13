// AnthropicToolLoopTests — the Messages API tool round, proved on the wire.
//
// Every assertion is either about the recorded REQUEST or about how a captured
// response is mapped; nothing touches the network. The three rules from
// `AnthropicConnector+ToolLoop.swift`'s header each get a dedicated case,
// because each failure mode is a 400 at runtime and invisible at compile time:
// the reply message must lead with `tool_result`, parallel calls share ONE reply,
// and the assistant turn is replayed verbatim rather than rebuilt.
import AIConnectorKit
import Foundation
import Testing

@Suite("AnthropicToolLoopTests")
struct AnthropicToolLoopTests {
    private static let apiKey = "sk-ant-api03-test-key"
    private static let model = "claude-fixture-4"
    private static let messagesURL = "https://api.anthropic.com/v1/messages"

    private static func connector(_ transport: FakeHTTPTransport) -> AnthropicConnector {
        AnthropicConnector(auth: .apiKey(provider: { AnthropicToolLoopTests.apiKey }), transport: transport)
    }

    private static func request(_ tools: [AITool]) -> ToolLoopRequest {
        ToolLoopRequest(
            instructions: "Be useful.",
            userText: "make me a shoegaze mix",
            tools: tools,
            model: model
        )
    }

    /// A round that calls one tool, with a leading `text` block the replay must
    /// preserve.
    private static let toolUseRound = """
    {"id":"msg_01","type":"message","role":"assistant","model":"claude-fixture-4",
     "stop_reason":"tool_use","content":[
       {"type":"text","text":"Let me look."},
       {"type":"tool_use","id":"toolu_01","name":"search_tracks",
        "input":{"query":"shoegaze","limit":5}}]}
    """

    private static let answerRound = """
    {"id":"msg_02","type":"message","role":"assistant","stop_reason":"end_turn",
     "content":[{"type":"text","text":"Here are five."}]}
    """

    // MARK: - Two-round loop

    @Test("A two-round turn sends the tool list, answers the call, and returns the model's prose")
    func twoRoundTurnCompletes() async throws {
        let recorder = ToolRecorder(["search_tracks": ["Found 5 tracks."]])
        let transport = FakeHTTPTransport(scripts: [
            .success(jsonResponse(Self.toolUseRound)),
            .success(jsonResponse(Self.answerRound)),
        ])

        let outcome = try await ToolLoopEngine().run(
            Self.request([recorder.tool("search_tracks", schema: ToolFixture.looseSchema)]),
            connector: Self.connector(transport)
        )

        #expect(outcome.text == "Here are five.")
        #expect(outcome.termination == .answered)
        #expect(outcome.rounds == 2)
        // Arguments are normalised to canonical `.sortedKeys` text, so the same
        // object reads identically whichever provider emitted it.
        #expect(outcome.events == [
            .assistantText("Let me look."),
            .toolCall(name: "search_tracks", argumentsJSON: "{\"limit\":5,\"query\":\"shoegaze\"}"),
            .toolResult(name: "search_tracks", text: "Found 5 tracks.", resultCount: nil),
            .assistantText("Here are five."),
        ])
        #expect(await transport.recordedRequests.count == 2)
    }

    @Test("The first request carries top-level tools, auto tool_choice, max_tokens and system framing")
    func firstRequestShape() async throws {
        let recorder = ToolRecorder()
        let transport = FakeHTTPTransport(scripts: [
            .success(jsonResponse(Self.toolUseRound)),
            .success(jsonResponse(Self.answerRound)),
        ])

        _ = try await ToolLoopEngine().run(
            Self.request([recorder.tool("search_tracks")]),
            connector: Self.connector(transport)
        )

        let sent = try #require(await transport.recordedRequests.first)
        #expect(sent.url?.absoluteString == Self.messagesURL)
        #expect(sent.httpMethod == "POST")
        #expect(sent.value(forHTTPHeaderField: "x-api-key") == Self.apiKey)
        #expect(sent.value(forHTTPHeaderField: "anthropic-version") == AnthropicConnector.anthropicVersion)

        let body = try #require(await recordedJSONBody(transport, at: 0))
        #expect(body["max_tokens"]?.intValue == AnthropicConnector.maxTokensForToolLoop)
        #expect(body["max_tokens"]?.intValue == 8192)
        #expect(body["model"]?.stringValue == Self.model)
        #expect(body["system"]?.stringValue == "Be useful.")
        // `tool_choice` is an OBJECT here — a bare `"auto"` string is the OpenAI
        // dialect and a 400 on this endpoint.
        #expect(body["tool_choice"] == .object(["type": .string("auto")]))

        let tools = try #require(body["tools"]?.arrayValue)
        #expect(tools.count == 1)
        // Top level, NOT wrapped in a `function` envelope.
        #expect(tools[0]["name"]?.stringValue == "search_tracks")
        #expect(tools[0]["input_schema"] == ToolFixture.strictSchema)
        #expect(tools[0]["function"] == nil)
        #expect(tools[0]["parameters"] == nil)

        let messages = try #require(body["messages"]?.arrayValue)
        #expect(messages.count == 1)
        #expect(messages[0] == .object(["role": .string("user"), "content": .string("make me a shoegaze mix")]))
    }

    @Test("The reply replays the assistant content VERBATIM, then one tool_result-led user message")
    func replyShapeIsExact() async throws {
        let recorder = ToolRecorder(["search_tracks": ["Found 5 tracks."]])
        let transport = FakeHTTPTransport(scripts: [
            .success(jsonResponse(Self.toolUseRound)),
            .success(jsonResponse(Self.answerRound)),
        ])

        _ = try await ToolLoopEngine().run(
            Self.request([recorder.tool("search_tracks")]),
            connector: Self.connector(transport)
        )

        let body = try #require(await recordedJSONBody(transport, at: 1))
        let messages = try #require(body["messages"]?.arrayValue)
        #expect(messages.count == 3)

        // VERBATIM: the leading `text` block survives. A rebuild that kept only
        // the blocks this parser interprets would drop it and silently degrade
        // the conversation.
        let assistant = messages[1]
        #expect(assistant["role"]?.stringValue == "assistant")
        let content = try #require(assistant["content"]?.arrayValue)
        #expect(content.count == 2)
        #expect(content[0] == .object(["type": .string("text"), "text": .string("Let me look.")]))
        #expect(content[1]["type"]?.stringValue == "tool_use")
        #expect(content[1]["id"]?.stringValue == "toolu_01")

        // ONE user message, whose content STARTS with a `tool_result` block —
        // text before one in that message is a 400.
        let reply = messages[2]
        #expect(reply["role"]?.stringValue == "user")
        let blocks = try #require(reply["content"]?.arrayValue)
        #expect(blocks.count == 1)
        #expect(blocks[0]["type"]?.stringValue == "tool_result")
        #expect(blocks[0]["tool_use_id"]?.stringValue == "toolu_01")
        #expect(blocks[0]["content"]?.stringValue == "Found 5 tracks.")
        // `is_error` is never set: a tool in this kit cannot fail, it refuses in
        // prose.
        #expect(blocks[0]["is_error"] == nil)
    }

    // MARK: - Parallel calls

    @Test("Parallel tool_use blocks are answered by a SINGLE user message, in emission order")
    func parallelCallsShareOneReply() async throws {
        let parallel = """
        {"id":"msg_03","type":"message","role":"assistant","stop_reason":"tool_use","content":[
          {"type":"tool_use","id":"toolu_a","name":"search_tracks","input":{"query":"shoegaze"}},
          {"type":"tool_use","id":"toolu_b","name":"list_genres","input":{}}]}
        """
        let recorder = ToolRecorder([
            "search_tracks": ["Found 5 tracks."],
            "list_genres": ["Shoegaze, Dream Pop."],
        ])
        let transport = FakeHTTPTransport(scripts: [
            .success(jsonResponse(parallel)),
            .success(jsonResponse(Self.answerRound)),
        ])

        let outcome = try await ToolLoopEngine().run(
            Self.request([recorder.tool("search_tracks"), recorder.tool("list_genres")]),
            connector: Self.connector(transport)
        )

        #expect(outcome.termination == .answered)
        #expect(recorder.invocations.map(\.name) == ["search_tracks", "list_genres"])

        let body = try #require(await recordedJSONBody(transport, at: 1))
        let messages = try #require(body["messages"]?.arrayValue)
        // user, assistant, ONE user reply — never one reply per call, which has
        // no preceding assistant turn to answer and is a 400.
        #expect(messages.count == 3)
        #expect(messages.count { $0["role"]?.stringValue == "user" } == 2)

        let blocks = try #require(messages[2]["content"]?.arrayValue)
        #expect(blocks.count == 2)
        #expect(blocks.allSatisfy { $0["type"]?.stringValue == "tool_result" })
        #expect(blocks.compactMap { $0["tool_use_id"]?.stringValue } == ["toolu_a", "toolu_b"])
        #expect(blocks.compactMap { $0["content"]?.stringValue }
            == ["Found 5 tracks.", "Shoegaze, Dream Pop."])
    }

    // MARK: - Strict derivation

    @Test("`strict` follows the schema: true when it can be honoured, false when it cannot")
    func strictFlagIsDerivedFromTheSchema() async throws {
        let recorder = ToolRecorder()
        let transport = FakeHTTPTransport(scripts: [.success(jsonResponse(Self.answerRound))])

        _ = try await ToolLoopEngine().run(
            ToolLoopRequest(
                userText: "hello",
                tools: [
                    recorder.tool("strict_tool", schema: ToolFixture.strictSchema),
                    recorder.tool("loose_tool", schema: ToolFixture.looseSchema),
                ],
                model: Self.model
            ),
            connector: Self.connector(transport)
        )

        let tools = try #require(await recordedJSONBody(transport, at: 0)?["tools"]?.arrayValue)
        #expect(tools[0]["strict"]?.boolValue == true)
        // `looseSchema` leaves an optional `limit` out of `required`, which is
        // exactly how PlayerCore's real `search_tracks` is shaped. Sending
        // `strict: true` beside it would be a guaranteed 400.
        #expect(tools[1]["strict"]?.boolValue == false)
    }

    @Test("Blank instructions omit `system`, and an empty tool list omits `tools` and `tool_choice`")
    func optionalFieldsAreOmittedRatherThanBlank() async throws {
        let transport = FakeHTTPTransport(scripts: [.success(jsonResponse(Self.answerRound))])
        _ = try await ToolLoopEngine().run(
            ToolLoopRequest(instructions: "  \n ", userText: "hello", model: Self.model),
            connector: Self.connector(transport)
        )

        let body = try #require(await recordedJSONBody(transport, at: 0))
        #expect(body["system"] == nil)
        #expect(body["tools"] == nil)
        #expect(body["tool_choice"] == nil)
    }

    // MARK: - Failures

    @Test("An unreadable or content-less round is malformedResponse, never a crash")
    func unreadableRoundsMapToMalformedResponse() async throws {
        for body in ["<html>not json</html>", "{\"stop_reason\":\"end_turn\"}", "{\"content\":[]}"] {
            let transport = FakeHTTPTransport(scripts: [.success(jsonResponse(body))])
            await #expect(throws: ConnectorFailure.malformedResponse) {
                _ = try await ToolLoopEngine().run(Self.request([]), connector: Self.connector(transport))
            }
        }
    }

    @Test("A never-responding provider is bounded by the loop's per-round deadline")
    func neverRespondingProviderIsBounded() async throws {
        // No `simulatedRequestTimeout`: the fake parks until CANCELLED, so this
        // proves the loop's own deadline fired and cancelled its loser rather
        // than a transport timeout doing the work.
        let transport = FakeHTTPTransport(scripts: [.neverRespond])
        await #expect(throws: ConnectorFailure.timeout) {
            _ = try await ToolLoopEngine(roundDeadlineSeconds: 0.05)
                .run(Self.request([]), connector: Self.connector(transport))
        }
    }

    @Test("A 401 on a tool round is authExpired, and a credential that cannot be produced never calls out")
    func failuresMapOntoTheTaxonomy() async throws {
        let unauthorized = FakeHTTPTransport(scripts: [
            .success(jsonResponse("{\"error\":{\"type\":\"authentication_error\"}}", statusCode: 401)),
        ])
        await #expect(throws: ConnectorFailure.authExpired) {
            _ = try await ToolLoopEngine().run(Self.request([]), connector: Self.connector(unauthorized))
        }

        let blank = FakeHTTPTransport()
        let unconfigured = AnthropicConnector(auth: .apiKey(provider: { "   " }), transport: blank)
        await #expect(throws: ConnectorFailure.unconfigured) {
            _ = try await ToolLoopEngine().run(Self.request([]), connector: unconfigured)
        }
        #expect(await blank.recordedRequests.isEmpty)
    }
}

/// The array-bound sanitizer behind ``ToolWireEncoding/anthropicTools(_:)``.
///
/// MEASURED 2026-09-09: `/v1/messages` answers HTTP 400 `invalid_request_error`
/// — `tools.N.custom: For 'array' type, property 'maxItems' is not supported` —
/// so a tool list carrying PlayerCore's real `maxItems` bounds took every
/// assistant turn down. The bounds are stripped for this provider only.
@Suite("AnthropicSchemaSanitizerTests")
struct AnthropicSchemaSanitizerTests {
    private static let idArraySchema: AIJSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "track_ids": .object([
                "type": .string("array"),
                "items": .object(["type": .string("integer")]),
                "maxItems": .int(100),
                "minItems": .int(1),
            ]),
            "limit": .object([
                "type": .string("integer"),
                "minimum": .int(1),
                "maximum": .int(200),
            ]),
        ]),
        "required": .array([.string("track_ids")]),
        "additionalProperties": .bool(false),
    ])

    @Test("maxItems and minItems are stripped from array nodes, nested ones included")
    func arrayBoundsAreStripped() {
        let nested: AIJSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "pairs": .object([
                    "type": .string("array"),
                    "maxItems": .int(100),
                    "items": .object([
                        "type": .string("object"),
                        "properties": .object([
                            "titles": .object(["type": .string("array"), "maxItems": .int(3)]),
                        ]),
                    ]),
                ]),
            ]),
        ])
        let cleaned = ToolWireEncoding.anthropicSchema(nested)
        let pairs = cleaned["properties"]?["pairs"]
        #expect(pairs?["maxItems"] == nil)
        #expect(pairs?["items"]?["properties"]?["titles"]?["maxItems"] == nil)
        #expect(pairs?["type"]?.stringValue == "array")
    }

    @Test("Numeric minimum/maximum and every non-array keyword survive untouched")
    func nonArrayBoundsSurvive() {
        let cleaned = ToolWireEncoding.anthropicSchema(Self.idArraySchema)
        let limit = cleaned["properties"]?["limit"]
        #expect(limit?["minimum"]?.intValue == 1)
        #expect(limit?["maximum"]?.intValue == 200)
        #expect(cleaned["additionalProperties"]?.boolValue == false)
        #expect(cleaned["required"] == .array([.string("track_ids")]))
    }

    @Test("A PROPERTY named maxItems is not a schema keyword and is left alone")
    func aPropertyNamedMaxItemsSurvives() {
        let schema: AIJSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "maxItems": .object(["type": .string("integer")]),
            ]),
        ])
        let cleaned = ToolWireEncoding.anthropicSchema(schema)
        #expect(cleaned["properties"]?["maxItems"] == .object(["type": .string("integer")]))
    }

    @Test("The wire body's input_schema is the sanitized schema")
    func wireBodyCarriesTheSanitizedSchema() {
        let tool = AITool(
            name: "get_tracks",
            description: "Look up tracks.",
            parametersSchema: Self.idArraySchema,
            execute: { _ in AIToolOutput(text: "") }
        )
        let tools = ToolWireEncoding.anthropicTools([tool]).arrayValue
        let schema = tools?.first?["input_schema"]
        #expect(schema?["properties"]?["track_ids"]?["maxItems"] == nil)
        #expect(schema?["properties"]?["track_ids"]?["minItems"] == nil)
        #expect(schema?["properties"]?["track_ids"]?["items"] == .object(["type": .string("integer")]))
    }
}
