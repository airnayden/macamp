// ChatGPTToolLoopTests — the Responses-API tool round over the subscription
// backend, proved on the wire. ZERO live network.
//
// The two facts this suite exists to pin:
//
//   1. THE ENVELOPE IS FLAT. `{type: "function", name, description, parameters,
//      strict}` with no `function` wrapper. Copying OpenAI's nested shape here
//      is a 400 that no compiler catches.
//   2. REASONING ITEMS ARE REPLAYED. In stateless mode the client owns the whole
//      `input` array, so an item the model produced and needs back must be sent
//      back. Dropping one degrades answers in a way that looks like a bad model,
//      never like a lost field — so the fixture carries one and the assertion is
//      that it survives the round trip byte for byte.
import AIConnectorKit
@testable import AIConnectorKitOAuth
import Foundation
import Testing

@Suite("ChatGPTToolLoopTests")
struct ChatGPTToolLoopTests {
    private static let model = "gpt-fixture-max"
    private static let responsesURL = "https://chatgpt.com/backend-api/codex/responses"

    private static func connector(
        _ transport: FakeTokenTransport,
        token: String = ChatGPTFixture.accessToken
    ) -> ChatGPTConnector {
        ChatGPTConnector(bearerToken: { token }, transport: transport)
    }

    private static func request(_ tools: [AITool]) -> ToolLoopRequest {
        ToolLoopRequest(
            instructions: "Be useful.",
            userText: "make me a shoegaze mix",
            tools: tools,
            model: model
        )
    }

    /// A round carrying a REASONING item alongside the function call — the shape
    /// stateless mode requires the client to replay.
    private static let toolCallRound = #"""
    {"id":"resp_01","status":"completed","output":[
      {"id":"rs_01","type":"reasoning","summary":[],"encrypted_content":"opaque-reasoning-blob"},
      {"id":"fc_01","call_id":"call_01","type":"function_call","name":"search_tracks",
       "arguments":"{\"query\":\"shoegaze\"}"}]}
    """#

    private static let answerRound = """
    {"id":"resp_02","status":"completed","output":[
      {"id":"msg_01","type":"message","role":"assistant",
       "content":[{"type":"output_text","text":"Here are five."}]}]}
    """

    // MARK: - Two-round loop

    @Test("A two-round turn answers the function call and returns the model's prose")
    func twoRoundTurnCompletes() async throws {
        let recorder = ToolRecorder(["search_tracks": ["Found 5 tracks."]])
        let transport = FakeTokenTransport([
            .success(toolLoopResponse(Self.toolCallRound)),
            .success(toolLoopResponse(Self.answerRound)),
        ])

        let outcome = try await ToolLoopEngine().run(
            Self.request([recorder.tool("search_tracks", schema: ToolFixture.looseSchema)]),
            connector: Self.connector(transport)
        )

        #expect(outcome.text == "Here are five.")
        #expect(outcome.termination == .answered)
        #expect(outcome.rounds == 2)
        #expect(outcome.events == [
            .toolCall(name: "search_tracks", argumentsJSON: "{\"query\":\"shoegaze\"}"),
            .toolResult(name: "search_tracks", text: "Found 5 tracks.", resultCount: nil),
            .assistantText("Here are five."),
        ])
        #expect(await transport.recordedRequests.count == 2)
    }

    @Test("The first request sends FLAT function tools, stateless input, and no server-side store")
    func firstRequestShape() async throws {
        let recorder = ToolRecorder()
        let transport = FakeTokenTransport([
            .success(toolLoopResponse(Self.toolCallRound)),
            .success(toolLoopResponse(Self.answerRound)),
        ])

        _ = try await ToolLoopEngine().run(
            Self.request([recorder.tool("search_tracks")]),
            connector: Self.connector(transport, token: ChatGPTFixture.identityToken())
        )

        #expect(await transport.recordedRequests.first?.url?.absoluteString == Self.responsesURL)
        #expect(await transport.recordedHeader("ChatGPT-Account-Id", at: 0) == ChatGPTFixture.accountID)

        let body = try #require(await recordedJSONBody(transport, at: 0))
        #expect(body["instructions"]?.stringValue == "Be useful.")
        #expect(body["tool_choice"] == .string("auto"))
        #expect(body["store"] == .bool(false))
        #expect(body["stream"] == .bool(true))
        // Stateless: the whole conversation rides `input`, never a server-side
        // handle.
        #expect(body["previous_response_id"] == nil)

        let tools = try #require(body["tools"]?.arrayValue)
        #expect(tools.count == 1)
        // FLAT: `name` sits beside `type`, with no `function` envelope.
        #expect(tools[0]["type"]?.stringValue == "function")
        #expect(tools[0]["name"]?.stringValue == "search_tracks")
        #expect(tools[0]["parameters"] == ToolFixture.strictSchema)
        #expect(tools[0]["strict"]?.boolValue == true)
        #expect(tools[0]["function"] == nil)

        let input = try #require(body["input"]?.arrayValue)
        #expect(input == [.object([
            "type": .string("message"),
            "role": .string("user"),
            "content": .array([.object([
                "type": .string("input_text"),
                "text": .string("make me a shoegaze mix"),
            ])]),
        ])])
    }

    @Test("The reasoning item is replayed VERBATIM alongside the call and its output")
    func reasoningItemIsReplayed() async throws {
        let recorder = ToolRecorder(["search_tracks": ["Found 5 tracks."]])
        let transport = FakeTokenTransport([
            .success(toolLoopResponse(Self.toolCallRound)),
            .success(toolLoopResponse(Self.answerRound)),
        ])

        _ = try await ToolLoopEngine().run(
            Self.request([recorder.tool("search_tracks")]),
            connector: Self.connector(transport)
        )

        let input = try #require(await recordedJSONBody(transport, at: 1)?["input"]?.arrayValue)
        #expect(input.count == 4)
        #expect(input[0]["type"]?.stringValue == "message")

        // The whole output list comes back, in order, including the item this
        // parser never interprets.
        #expect(input[1]["type"]?.stringValue == "reasoning")
        #expect(input[1]["id"]?.stringValue == "rs_01")
        #expect(input[1]["encrypted_content"]?.stringValue == "opaque-reasoning-blob")

        #expect(input[2]["type"]?.stringValue == "function_call")
        #expect(input[2]["call_id"]?.stringValue == "call_01")

        // Addressed by `call_id`, NOT by the item's own `id` — the two are
        // different strings on this API.
        #expect(input[3] == .object([
            "type": .string("function_call_output"),
            "call_id": .string("call_01"),
            "output": .string("Found 5 tracks."),
        ]))
    }

    @Test("A prior assistant turn is replayed as output_text, and a user turn as input_text")
    func proseHistoryUsesTheRightContentTypes() async throws {
        let transport = FakeTokenTransport([.success(toolLoopResponse(Self.answerRound))])
        _ = try await ToolLoopEngine().run(
            ToolLoopRequest(
                history: [.user("earlier"), .assistant("previous answer")],
                userText: "and now?",
                model: Self.model
            ),
            connector: Self.connector(transport)
        )

        let input = try #require(await recordedJSONBody(transport, at: 0)?["input"]?.arrayValue)
        #expect(input.count == 3)
        #expect(input[0]["content"]?.arrayValue?.first?["type"]?.stringValue == "input_text")
        // An assistant turn is modelled as replayed OUTPUT even arriving as input.
        #expect(input[1]["content"]?.arrayValue?.first?["type"]?.stringValue == "output_text")
        #expect(input[2]["content"]?.arrayValue?.first?["text"]?.stringValue == "and now?")
    }

    // MARK: - Failures

    @Test("An unreadable or empty output list is malformedResponse, never a crash")
    func unreadableRoundsMapToMalformedResponse() async throws {
        let bodies = [
            "<!DOCTYPE html><html>Attention Required! | Cloudflare</html>",
            "{\"status\":\"completed\"}",
            "{\"output\":[]}",
            "event: response.completed\ndata: {\"type\":\"response.completed\"}\n\n",
        ]
        for body in bodies {
            let transport = FakeTokenTransport([.success(toolLoopResponse(body))])
            await #expect(throws: ConnectorFailure.malformedResponse) {
                _ = try await ToolLoopEngine().run(Self.request([]), connector: Self.connector(transport))
            }
        }
    }

    @Test("A bot-mitigation challenge stays unreachable rather than becoming authExpired")
    func botMitigationIsNotAnExpiredSession() async throws {
        let challenge = HTTPResponse(
            statusCode: 403,
            headers: ["cf-mitigated": "challenge", "Content-Type": "text/html"],
            body: Data("<html>Attention Required!</html>".utf8)
        )
        let transport = FakeTokenTransport([.success(challenge)])

        await #expect(throws: ConnectorFailure.unreachable(underlying: ChatGPTConnector.botMitigationToken)) {
            _ = try await ToolLoopEngine().run(Self.request([]), connector: Self.connector(transport))
        }
    }

    @Test("A never-responding backend is bounded by the loop's per-round deadline")
    func neverRespondingBackendIsBounded() async throws {
        let transport = FakeTokenTransport([.neverRespond])
        await #expect(throws: ConnectorFailure.timeout) {
            _ = try await ToolLoopEngine(roundDeadlineSeconds: 0.05)
                .run(Self.request([]), connector: Self.connector(transport))
        }
    }

    @Test("An unconfigured credential never reaches the transport")
    func unconfiguredCredentialNeverCallsOut() async throws {
        let transport = FakeTokenTransport()
        await #expect(throws: ConnectorFailure.unconfigured) {
            _ = try await ToolLoopEngine().run(
                Self.request([]),
                connector: Self.connector(transport, token: "   ")
            )
        }
        #expect(await transport.recordedRequests.isEmpty)
    }
}
