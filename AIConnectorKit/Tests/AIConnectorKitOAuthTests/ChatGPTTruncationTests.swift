// ChatGPTTruncationTests — a turn the model cut short at its own output ceiling,
// pinned on the wire. ZERO live network.
//
// ── THE PRE-PIN THIS SUITE REPLACED ──────────────────────────────────────────
//
// Before the fix, the assertion in `incompleteTerminalIsTruncated` read
// `ConnectorFailure.malformedResponse` and PASSED: `completedResponse(in:)`
// reduced a stream to its terminal `response.completed` event and nothing else,
// so a `response.incomplete` terminal was never recognised, the loop ended with
// no terminal at all, and the connector reported "the payload did not match the
// contract". The shell renders that as the generic "couldn't answer that" —
// which is the one sentence that cannot help someone whose list was too long.
// The transition of this file's expectation from `.malformedResponse` to
// `.truncated` IS the behaviour change; the run capturing both is in
// `.omo/evidence/task-10-bugfix-batch-10.txt`.
//
// ── THE CEILING WAS LIVE-REFUSED, SO ONLY DETECTION REMAINS ──────────────────
//
// `max_output_tokens` shipped LIVE-UNVERIFIED with the recorded escape hatch
// "if the live backend answers 400 naming the field, remove the field and keep
// the detection". MEASURED 2026-09-09: HTTP 400 `{"detail":"Unsupported
// parameter: max_output_tokens"}` on every model — every request failed, so the
// field is gone. The `ChatGPTOutputCeilingTests` below now pin its ABSENCE from
// all three `/responses` bodies; the truncation detection stays unchanged.
import AIConnectorKit
@testable import AIConnectorKitOAuth
import Foundation
import Testing

enum ChatGPTTruncationFixture {
    /// The measured shape of a `/responses` turn that ran out of output budget:
    /// a terminal `response.incomplete` on an HTTP 200, carrying REAL partial
    /// output and no error object anywhere.
    static let incompleteTurn = #"""
    event: response.created
    data: {"type":"response.created","response":{"id":"resp_01","status":"in_progress","error":null,"output":[]}}

    event: response.incomplete
    data: {"type":"response.incomplete","response":{"id":"resp_01","status":"incomplete","error":null,"incomplete_details":{"reason":"max_output_tokens"},"output":[{"id":"msg_01","type":"message","role":"assistant","content":[{"type":"output_text","text":"1. Midnight Drive"}]}]}}

    data: [DONE]

    """#

    /// The same terminal event for a DIFFERENT reason. Truncation copy says "ask
    /// for fewer items", which would be wrong advice here, so this must not read
    /// as truncation.
    static let contentFilterTurn = #"""
    event: response.incomplete
    data: {"type":"response.incomplete","response":{"id":"resp_01","status":"incomplete","error":null,"incomplete_details":{"reason":"content_filter"},"output":[]}}

    """#

    /// The plain-JSON form of the same condition, for the backend-flip tolerance
    /// `completedResponse(in:)` deliberately keeps.
    static let incompleteObject = #"""
    {"id":"resp_01","status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},
     "output":[{"type":"message","content":[{"type":"output_text","text":"1. Midnight Drive"}]}]}
    """#

    static let toolCallRound = #"""
    {"id":"resp_01","status":"completed","output":[
      {"id":"fc_01","call_id":"call_01","type":"function_call","name":"search_tracks",
       "arguments":"{\"query\":\"shoegaze\"}"}]}
    """#

    static let answerRound = """
    {"id":"resp_02","status":"completed","output":[
      {"id":"msg_01","type":"message","role":"assistant",
       "content":[{"type":"output_text","text":"Here are five."}]}]}
    """
}

@Suite("ChatGPTTruncationTests")
struct ChatGPTTruncationTests {
    private static let model = "gpt-fixture-max"

    @Test("An incomplete terminal event is a truncation, not a malformed response")
    func incompleteTerminalIsTruncated() {
        #expect(throws: ConnectorFailure.truncated) {
            try ChatGPTConnector.completedResponse(in: Data(ChatGPTTruncationFixture.incompleteTurn.utf8))
        }
    }

    @Test("A cut-off answer reaches the caller as truncated through the whole one-shot path")
    func oneShotCompletionReportsTruncation() async {
        let transport = FakeTokenTransport([
            .success(ChatGPTStreamFixture.sse(ChatGPTTruncationFixture.incompleteTurn)),
        ])
        await #expect(throws: ConnectorFailure.truncated) {
            try await ChatGPTConnectorFixture.connector(transport: transport).completion(
                instructions: "i", prompt: "list 43 songs", model: Self.model
            )
        }
    }

    @Test("A cut-off tool round reaches the caller as truncated too")
    func toolLoopReportsTruncation() async {
        let recorder = ToolRecorder(["search_tracks": ["Found 43 tracks."]])
        let transport = FakeTokenTransport([
            .success(ChatGPTStreamFixture.sse(ChatGPTStreamFixture.toolCallTurn)),
            .success(ChatGPTStreamFixture.sse(ChatGPTTruncationFixture.incompleteTurn)),
        ])

        await #expect(throws: ConnectorFailure.truncated) {
            try await ToolLoopEngine().run(
                ToolLoopRequest(
                    instructions: "Be useful.",
                    userText: "list every shoegaze track",
                    tools: [recorder.tool("search_tracks", schema: ToolFixture.looseSchema)],
                    model: Self.model
                ),
                connector: ChatGPTConnectorFixture.connector(transport: transport)
            )
        }
    }

    @Test("The plain-JSON form of the same condition is caught too, so a backend flip cannot hide it")
    func plainJSONIncompleteObjectIsTruncated() {
        #expect(throws: ConnectorFailure.truncated) {
            try ChatGPTConnector.completedResponse(in: Data(ChatGPTTruncationFixture.incompleteObject.utf8))
        }
    }

    @Test("An incomplete turn stopped for another reason keeps today's behaviour")
    func aNonBudgetIncompleteIsNotTruncation() {
        // "Ask for fewer items" is wrong advice for a content filter, so this must
        // land somewhere else — it keeps the pre-existing malformed reading.
        #expect(throws: ConnectorFailure.malformedResponse) {
            try ChatGPTConnector.completedResponse(in: Data(ChatGPTTruncationFixture.contentFilterTurn.utf8))
        }
    }

    @Test("A completed turn is untouched — detection costs the happy path nothing")
    func aCompletedTurnStillAnswers() async throws {
        let transport = FakeTokenTransport([.success(ChatGPTStreamFixture.sse(ChatGPTStreamFixture.textTurn))])
        let text = try await ChatGPTConnectorFixture.connector(transport: transport).completion(
            instructions: "i", prompt: "p", model: Self.model
        )
        #expect(text == "Midnight Drive")
    }
}

@Suite("ChatGPTOutputCeilingTests")
struct ChatGPTOutputCeilingTests {
    private static let model = "gpt-fixture-max"

    /// The path the chat ask actually travels, so this is the assertion that
    /// matters most.
    @Test("The TOOL-LOOP body does NOT carry max_output_tokens — the backend refuses it")
    func toolLoopBodyOmitsTheCeiling() async throws {
        let recorder = ToolRecorder()
        let transport = FakeTokenTransport([
            .success(toolLoopResponse(ChatGPTTruncationFixture.toolCallRound)),
            .success(toolLoopResponse(ChatGPTTruncationFixture.answerRound)),
        ])

        _ = try await ToolLoopEngine().run(
            ToolLoopRequest(
                instructions: "Be useful.",
                userText: "make me a shoegaze mix",
                tools: [recorder.tool("search_tracks")],
                model: Self.model
            ),
            connector: ChatGPTConnector(bearerToken: { ChatGPTFixture.accessToken }, transport: transport)
        )

        let body = try #require(await recordedJSONBody(transport, at: 0))
        #expect(body["max_output_tokens"] == nil)
        // Every round, not just the first — a later round would 400 identically.
        let second = try #require(await recordedJSONBody(transport, at: 1))
        #expect(second["max_output_tokens"] == nil)
    }

    @Test("The ONE-SHOT body does not carry it either, under any spelling")
    func oneShotBodyOmitsTheCeiling() async throws {
        let transport = FakeTokenTransport([.success(ChatGPTStreamFixture.sse(ChatGPTStreamFixture.textTurn))])
        _ = try await ChatGPTConnectorFixture.connector(transport: transport).completion(
            instructions: "name it", prompt: "late night", model: Self.model
        )

        let body = try #require(await transport.recordedBody(0))
        #expect(body.contains("max_output_tokens") == false)
        #expect(body.contains("maxOutputTokens") == false)
    }

    @Test("The structured body does not carry it — same endpoint, same refusal")
    func structuredBodyOmitsTheCeiling() async throws {
        let events = #"""
        event: response.completed
        data: {"type":"response.completed","response":{"status":"completed","error":null,"output":[{"type":"message","content":[{"type":"output_text","text":"{\"genres\":[\"shoegaze\"]}"}]}]}}

        """#
        let transport = FakeTokenTransport([.success(ChatGPTStreamFixture.sse(events))])
        _ = try await ChatGPTConnectorFixture.connector(transport: transport).structuredCompletion(
            schema: ChatGPTConnectorFixture.schema,
            instructions: "emit json",
            prompt: "late night",
            model: Self.model
        )

        let body = try #require(await transport.recordedBody(0))
        #expect(body.contains("max_output_tokens") == false)
    }
}
