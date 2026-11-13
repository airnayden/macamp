// ChatGPTStreamingTests — the 2026-09-06 backend break, pinned on the wire. ZERO
// live network: every suite drives `FakeTokenTransport` against checked-in bodies.
//
// Two regressions landed on `chatgpt.com/backend-api/codex` together, and both
// were MEASURED against the live backend with a real subscription credential
// before a line changed here:
//
//   1. `GET /models` without `client_version` is HTTP 400
//      `{"error":{"message":"[{'type': 'missing', 'loc': ('query',
//      'client_version'), 'msg': 'Field required', …}]"}}`. Worse than a hard
//      failure, the parameter GATES THE CATALOG: `0.45.0` answers 200 with
//      `{"models":[]}` and `1.0.0` answers 200 with the full list, so a wrong
//      value looks exactly like an account that owns no models.
//   2. `POST /responses` with `stream: false` is HTTP 400
//      `{"detail":"Stream must be set to true"}`. That broke chat, structured
//      output, plain completion AND the tool loop at once — every path through
//      this connector posts to `/responses`.
//
// The connector stays SINGLE-SHOT. Only the WIRE format is now SSE: the transport
// buffers the whole body, and one unwrapper reduces it to the terminal
// `response.completed` object so every existing decoder runs unchanged.
import AIConnectorKit
@testable import AIConnectorKitOAuth
import Foundation
import Testing

enum ChatGPTStreamFixture {
    static func sse(_ events: String, statusCode: Int = 200) -> HTTPResponse {
        HTTPResponse(
            statusCode: statusCode,
            headers: ["Content-Type": "text/event-stream"],
            body: Data(events.utf8)
        )
    }

    /// A realistic completed turn: creation, two text deltas, the terminal event
    /// carrying the WHOLE response object, and the `[DONE]` sentinel.
    static let textTurn = #"""
    event: response.created
    data: {"type":"response.created","sequence_number":0,"response":{"id":"resp_01","status":"in_progress","error":null,"output":[]}}

    event: response.output_text.delta
    data: {"type":"response.output_text.delta","sequence_number":1,"item_id":"msg_01","delta":"Midnight "}

    event: response.output_text.delta
    data: {"type":"response.output_text.delta","sequence_number":2,"item_id":"msg_01","delta":"Drive"}

    event: response.completed
    data: {"type":"response.completed","sequence_number":3,"response":{"id":"resp_01","status":"completed","error":null,"output":[{"id":"msg_01","type":"message","role":"assistant","content":[{"type":"output_text","text":"Midnight Drive"}]}]}}

    data: [DONE]

    """#

    /// The tool round, streamed. The function call is announced incrementally and
    /// then repeated COMPLETE inside the terminal event — which is the Responses
    /// API contract, and the reason a buffered reader needs no delta assembly.
    static let toolCallTurn = #"""
    event: response.output_item.added
    data: {"type":"response.output_item.added","output_index":0,"item":{"id":"fc_01","type":"function_call","name":"search_tracks","arguments":""}}

    event: response.function_call_arguments.delta
    data: {"type":"response.function_call_arguments.delta","item_id":"fc_01","delta":"{\"query\":"}

    event: response.completed
    data: {"type":"response.completed","response":{"id":"resp_01","status":"completed","error":null,"output":[{"id":"rs_01","type":"reasoning","summary":[],"encrypted_content":"opaque-reasoning-blob"},{"id":"fc_01","call_id":"call_01","type":"function_call","name":"search_tracks","arguments":"{\"query\":\"shoegaze\"}"}]}}

    data: [DONE]

    """#

    static let answerTurn = #"""
    event: response.completed
    data: {"type":"response.completed","response":{"id":"resp_02","status":"completed","error":null,"output":[{"id":"msg_02","type":"message","role":"assistant","content":[{"type":"output_text","text":"Here are five."}]}]}}

    """#

    /// A stream that carries progress and then stops. No terminal event, so there
    /// is no answer — and inventing one from the deltas would be a different
    /// connector.
    static let truncatedTurn = #"""
    event: response.created
    data: {"type":"response.created","response":{"id":"resp_01","status":"in_progress","error":null,"output":[]}}

    event: response.output_text.delta
    data: {"type":"response.output_text.delta","delta":"Midnight "}

    """#

    /// The measured quota shape. It normally arrives as a pre-stream HTTP 429,
    /// which ``ChatGPTConnector/validate(_:)`` already maps; this is the same
    /// condition reported mid-stream instead.
    static let usageLimitTurn = #"""
    event: response.failed
    data: {"type":"response.failed","response":{"id":"resp_01","status":"failed","error":{"type":"usage_limit_reached","message":"You have hit your usage limit.","resets_in_seconds":420}}}

    """#
}

@Suite("ChatGPTBackendRegressionTests")
struct ChatGPTBackendRegressionTests {
    @Test("The catalog request carries the measured client_version, which gates the catalog itself")
    func catalogRequestCarriesTheMeasuredClientVersion() async throws {
        let transport = FakeTokenTransport([
            .success(ChatGPTConnectorFixture.json("{\"models\":[{\"slug\":\"gpt-fixture-sol\"}]}")),
        ])
        let models = try await ChatGPTConnectorFixture.connector(transport: transport).listModels()

        #expect(models.map(\.id) == ["gpt-fixture-sol"])
        #expect(await transport.recordedRequests.first?.url?.absoluteString
            == "https://chatgpt.com/backend-api/codex/models?client_version="
            + ChatGPTConnector.catalogClientVersion)
        // A PINNED capability level, deliberately not MacAMP's own version — a
        // routine marketing-version bump must never change which models a
        // listener can reach.
        #expect(ChatGPTConnector.catalogClientVersion == "1.0.0")
    }

    @Test("The missing-parameter 400 keeps its status, its diagnostic body and the provider's own sentence")
    func missingClientVersionKeepsTheMeasuredDiagnostic() async throws {
        // Verbatim from the live backend, minus the credential.
        let measured = "{\"error\":{\"message\":\"[{'type': 'missing', 'loc': ('query', 'client_version'), "
            + "'msg': 'Field required'}]\"}}"
        let transport = FakeTokenTransport([
            .success(ChatGPTConnectorFixture.json(measured, statusCode: 400)),
        ])
        // This measured body is `error.message`-shaped, so the displayable
        // sentence is populated from it — the shape the shell's failure banner
        // renders beneath its own copy.
        let sentence = "[{'type': 'missing', 'loc': ('query', 'client_version'), 'msg': 'Field required'}]"
        await #expect(throws: ConnectorFailure.httpStatus(400, body: measured, providerMessage: sentence)) {
            try await ChatGPTConnectorFixture.connector(transport: transport).listModels()
        }
    }

    @Test("The detail-shaped 400 survives too — the backend answers in two error dialects")
    func detailShapedErrorBodySurvives() async throws {
        // `{"detail": …}` is the OTHER shape this backend uses. `diagnosticBody`
        // retains raw text, so neither dialect needs a parser — and since
        // 2026-09-09 the `detail` sentence is ALSO the displayable one:
        // "Unsupported parameter: max_output_tokens" reaching a listener as a
        // bare "(400)" is what let a total outage ship undiagnosed.
        let measured = "{\"detail\":\"Stream must be set to true\"}"
        let transport = FakeTokenTransport([
            .success(ChatGPTConnectorFixture.json(measured, statusCode: 400)),
        ])
        let expected = ConnectorFailure.httpStatus(
            400,
            body: measured,
            providerMessage: "Stream must be set to true"
        )
        await #expect(throws: expected) {
            try await ChatGPTConnectorFixture.connector(transport: transport).completion(
                instructions: "i", prompt: "p", model: "m"
            )
        }
    }

    @Test("Every /responses request asks for a stream and accepts one")
    func responsesRequestsAskForAStream() async throws {
        let transport = FakeTokenTransport([.success(ChatGPTStreamFixture.sse(ChatGPTStreamFixture.textTurn))])
        _ = try await ChatGPTConnectorFixture.connector(transport: transport).completion(
            instructions: "name it", prompt: "late night", model: "gpt-fixture-max"
        )

        let body = try #require(await transport.recordedBody(0))
        #expect(body.contains("\"stream\":true"))
        #expect(body.contains("\"stream\":false") == false)
        // `store` is UNCHANGED: the listener's prompt still stays out of the
        // provider's conversation history.
        #expect(body.contains("\"store\":false"))
        #expect(await transport.recordedHeader("Accept", at: 0) == "text/event-stream")
    }

    @Test("The catalog request still accepts JSON — only /responses streams")
    func catalogRequestStillAcceptsJSON() async throws {
        let transport = FakeTokenTransport([.success(ChatGPTConnectorFixture.json("{\"data\":[]}"))])
        _ = try await ChatGPTConnectorFixture.connector(transport: transport).listModels()
        #expect(await transport.recordedHeader("Accept", at: 0) == "application/json")
    }
}

@Suite("ChatGPTStreamEnvelopeTests")
struct ChatGPTStreamEnvelopeTests {
    private static let model = "gpt-fixture-max"

    @Test("A streamed turn is unwrapped to its terminal response object")
    func streamedTurnIsUnwrappedToTheTerminalResponse() async throws {
        let transport = FakeTokenTransport([.success(ChatGPTStreamFixture.sse(ChatGPTStreamFixture.textTurn))])
        let text = try await ChatGPTConnectorFixture.connector(transport: transport).completion(
            instructions: "i", prompt: "p", model: Self.model
        )
        // The deltas are NOT assembled: the terminal event carries the complete
        // output, which is the Responses API contract and the whole reason a
        // buffered reader is sufficient here.
        #expect(text == "Midnight Drive")
    }

    @Test("An empty-output terminal is assembled from the output_item.done events")
    func emptyOutputTerminalIsAssembledFromDoneItems() async throws {
        // The measured 2026-09-09 drift: the terminal `response.completed` ships
        // `"output":[]` and the finished items arrive only as
        // `response.output_item.done` events — reasoning and function_call here,
        // exactly as captured live from gpt-5.5.
        let events = #"""
        event: response.created
        data: {"type":"response.created","sequence_number":0,"response":{"id":"resp_01","status":"in_progress","error":null,"output":[]}}

        event: response.output_item.done
        data: {"type":"response.output_item.done","item":{"id":"rs_01","type":"reasoning","content":[],"encrypted_content":"opaque"},"output_index":0,"sequence_number":1}

        event: response.output_item.done
        data: {"type":"response.output_item.done","item":{"id":"msg_01","type":"message","role":"assistant","content":[{"type":"output_text","text":"Midnight Drive"}]},"output_index":1,"sequence_number":2}

        event: response.completed
        data: {"type":"response.completed","sequence_number":3,"response":{"id":"resp_01","status":"completed","error":null,"output":[]}}

        data: [DONE]

        """#
        let transport = FakeTokenTransport([.success(ChatGPTStreamFixture.sse(events))])
        let text = try await ChatGPTConnectorFixture.connector(transport: transport).completion(
            instructions: "i", prompt: "p", model: Self.model
        )
        #expect(text == "Midnight Drive")
    }

    @Test("A populated terminal still wins — a flip back costs nothing")
    func populatedTerminalStillWins() throws {
        let events = #"""
        event: response.output_item.done
        data: {"type":"response.output_item.done","item":{"id":"msg_stale","type":"message","content":[{"type":"output_text","text":"stale"}]},"sequence_number":0}

        event: response.completed
        data: {"type":"response.completed","sequence_number":1,"response":{"id":"resp_01","status":"completed","error":null,"output":[{"id":"msg_01","type":"message","content":[{"type":"output_text","text":"fresh"}]}]}}

        """#
        let reduced = try ChatGPTConnector.completedResponse(in: Data(events.utf8))
        let output = try #require(AIJSONValue.decoded(from: reduced)?["output"]?.arrayValue)
        #expect(output.count == 1)
        #expect(output.first?["content"]?.arrayValue?.first?["text"]?.stringValue == "fresh")
    }

    @Test("A streamed structured turn reaches the same JSON extraction")
    func streamedStructuredTurnIsExtracted() async throws {
        let events = #"""
        event: response.completed
        data: {"type":"response.completed","response":{"status":"completed","error":null,"output":[{"type":"message","content":[{"type":"output_text","text":"{\"genres\":[\"shoegaze\"]}"}]}]}}

        """#
        let transport = FakeTokenTransport([.success(ChatGPTStreamFixture.sse(events))])
        let data = try await ChatGPTConnectorFixture.connector(transport: transport).structuredCompletion(
            schema: ChatGPTConnectorFixture.schema,
            instructions: "emit json",
            prompt: "late night",
            model: Self.model
        )

        let decoded = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(decoded["genres"] as? [String] == ["shoegaze"])
    }

    @Test("A streamed tool round decodes the function call and replays the reasoning item")
    func streamedToolRoundDecodesTheFunctionCall() async throws {
        let recorder = ToolRecorder(["search_tracks": ["Found 5 tracks."]])
        let transport = FakeTokenTransport([
            .success(ChatGPTStreamFixture.sse(ChatGPTStreamFixture.toolCallTurn)),
            .success(ChatGPTStreamFixture.sse(ChatGPTStreamFixture.answerTurn)),
        ])

        let outcome = try await ToolLoopEngine().run(
            ToolLoopRequest(
                instructions: "Be useful.",
                userText: "make me a shoegaze mix",
                tools: [recorder.tool("search_tracks", schema: ToolFixture.looseSchema)],
                model: Self.model
            ),
            connector: ChatGPTConnectorFixture.connector(transport: transport)
        )

        #expect(outcome.text == "Here are five.")
        #expect(outcome.termination == .answered)
        #expect(recorder.invocations == [
            ToolInvocation(name: "search_tracks", argumentsJSON: "{\"query\":\"shoegaze\"}"),
        ])

        let firstBody = try #require(await recordedJSONBody(transport, at: 0))
        #expect(firstBody["stream"] == .bool(true))
        #expect(await transport.recordedHeader("Accept", at: 0) == "text/event-stream")

        // Unwrapping must not cost the replay: the reasoning item still rides the
        // second request verbatim.
        let replayed = try #require(await recordedJSONBody(transport, at: 1)?["input"]?.arrayValue)
        #expect(replayed[1]["encrypted_content"]?.stringValue == "opaque-reasoning-blob")
        #expect(replayed[3]["call_id"]?.stringValue == "call_01")
    }

    @Test("A plain-JSON body still decodes, so a backend flip back cannot break us")
    func plainJSONBodyStillDecodes() async throws {
        let oneShot = FakeTokenTransport([.success(ChatGPTConnectorFixture.reply("Midnight Drive"))])
        let text = try await ChatGPTConnectorFixture.connector(transport: oneShot).completion(
            instructions: "i", prompt: "p", model: Self.model
        )
        #expect(text == "Midnight Drive")

        let round = #"""
        {"id":"resp_01","status":"completed","output":[
          {"id":"fc_01","call_id":"call_01","type":"function_call","name":"search_tracks",
           "arguments":"{\"query\":\"shoegaze\"}"}]}
        """#
        let looped = FakeTokenTransport([
            .success(toolLoopResponse(round)),
            .success(toolLoopResponse("{\"output\":[{\"type\":\"message\",\"content\":[{\"text\":\"Done.\"}]}]}")),
        ])
        let recorder = ToolRecorder()
        let outcome = try await ToolLoopEngine().run(
            ToolLoopRequest(userText: "hi", tools: [recorder.tool("search_tracks")], model: Self.model),
            connector: ChatGPTConnectorFixture.connector(transport: looped)
        )
        #expect(outcome.text == "Done.")
    }

    @Test("A stream that never terminates is a malformedResponse, never a guessed answer")
    func streamWithoutATerminalEventIsMalformed() async throws {
        for events in [ChatGPTStreamFixture.truncatedTurn, "data: [DONE]\n\n", ": keep-alive\n\n", ""] {
            let transport = FakeTokenTransport([.success(ChatGPTStreamFixture.sse(events))])
            await #expect(throws: ConnectorFailure.malformedResponse) {
                try await ChatGPTConnectorFixture.connector(transport: transport).completion(
                    instructions: "i", prompt: "p", model: Self.model
                )
            }
        }
    }

    @Test("A mid-stream quota failure is rateLimited, exactly as the pre-stream 429 is")
    func midStreamQuotaFailureIsRateLimited() async throws {
        let transport = FakeTokenTransport([.success(ChatGPTStreamFixture.sse(ChatGPTStreamFixture.usageLimitTurn))])
        await #expect(throws: ConnectorFailure.rateLimited(retryAfter: 420)) {
            try await ChatGPTConnectorFixture.connector(transport: transport).completion(
                instructions: "i", prompt: "p", model: Self.model
            )
        }
    }

    @Test("Any other mid-stream failure is a refusal where content was expected")
    func otherMidStreamFailuresAreMalformed() async throws {
        let events = #"""
        event: error
        data: {"type":"error","code":"server_error","message":"Something went wrong."}

        """#
        let transport = FakeTokenTransport([.success(ChatGPTStreamFixture.sse(events))])
        await #expect(throws: ConnectorFailure.malformedResponse) {
            try await ChatGPTConnectorFixture.connector(transport: transport).completion(
                instructions: "i", prompt: "p", model: Self.model
            )
        }
    }

    @Test("CRLF framing and multi-line data fields are read the way the SSE grammar defines them")
    func crlfAndMultiLineDataFieldsAreRead() async throws {
        // The grammar strips ONE leading space after `data:` and joins repeated
        // data lines with a newline. A reader that trimmed harder, or that only
        // ever expected `\n`, would drop a terminal event on a conforming stream.
        let events = "event: response.completed\r\n"
            + "data: {\"type\":\"response.completed\",\"response\":{\r\n"
            + "data: \"output_text\":\"Midnight Drive\",\"output\":[]}}\r\n"
            + "\r\n"
        let transport = FakeTokenTransport([.success(ChatGPTStreamFixture.sse(events))])
        let text = try await ChatGPTConnectorFixture.connector(transport: transport).completion(
            instructions: "i", prompt: "p", model: Self.model
        )
        #expect(text == "Midnight Drive")
    }
}
