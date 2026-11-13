// AnthropicTruncationTests — a `/v1/messages` answer that stopped at `max_tokens`,
// and the raised ceilings that make it rare. ZERO live network.
//
// The failure this pins is the quiet one: `stop_reason: "max_tokens"` arrives
// inside a perfectly ordinary HTTP 200 with a `content` array that parses
// cleanly, so before this build every reader treated the fragment as the whole
// answer. Someone who asked for 43 songs got 20 and no sign the rest existed.
import AIConnectorKit
import Foundation
import Testing

@Suite("AnthropicTruncationTests")
struct AnthropicTruncationTests {
    private static let apiKey = "sk-ant-api03-test-key"
    private static let model = "claude-fixture-4"

    private static func connector(_ transport: FakeHTTPTransport) -> AnthropicConnector {
        AnthropicConnector(auth: .apiKey(provider: { AnthropicTruncationTests.apiKey }), transport: transport)
    }

    /// A cut-off round: real prose, no error object, and the one field that says
    /// the answer is not finished.
    private static let cutOffRound = """
    {"id":"msg_01","type":"message","role":"assistant","model":"claude-fixture-4",
     "stop_reason":"max_tokens",
     "content":[{"type":"text","text":"1. Midnight Drive\\n2. Neon"}]}
    """

    private static let answerRound = """
    {"id":"msg_02","type":"message","role":"assistant","stop_reason":"end_turn",
     "content":[{"type":"text","text":"Here are five."}]}
    """

    // MARK: - Detection

    @Test("A max_tokens stop is a truncation, never a partial answer passed off as whole")
    func maxTokensStopIsTruncated() async {
        let transport = FakeHTTPTransport(scripts: [.success(jsonResponse(Self.cutOffRound))])
        let recorder = ToolRecorder()

        await #expect(throws: ConnectorFailure.truncated) {
            try await ToolLoopEngine().run(
                ToolLoopRequest(
                    instructions: "Be useful.",
                    userText: "list every shoegaze track",
                    tools: [recorder.tool("search_tracks", schema: ToolFixture.looseSchema)],
                    model: Self.model
                ),
                connector: Self.connector(transport)
            )
        }
    }

    /// One round, answered by a body carrying `field` verbatim in place of a stop
    /// reason. Driven through the PUBLIC connector surface, like every other test
    /// in this target — the detector is not reached around.
    private static func text(stoppingWith field: String) async throws -> String {
        let round = """
        {"id":"msg_01","type":"message","role":"assistant",\(field)
         "content":[{"type":"text","text":"Here are five."}]}
        """
        let transport = FakeHTTPTransport(scripts: [.success(jsonResponse(round))])
        let recorder = ToolRecorder()
        let outcome = try await ToolLoopEngine().run(
            ToolLoopRequest(userText: "hi", tools: [recorder.tool("search_tracks")], model: model),
            connector: connector(transport)
        )
        return outcome.text
    }

    @Test("Only max_tokens reads as truncation — every other stop still answers")
    func onlyMaxTokensReadsAsTruncation() async throws {
        // `refusal` is in this list on purpose: the model declining IS an answer,
        // and telling that listener to "ask for fewer items" would be nonsense.
        for reason in ["end_turn", "tool_use", "stop_sequence", "pause_turn", "refusal"] {
            let answered = try await Self.text(stoppingWith: "\"stop_reason\":\"\(reason)\",")
            #expect(answered == "Here are five.", "\(reason) must still answer")
        }
        // A body that states no stop reason at all is not a cut-off answer either.
        let unstated = try await Self.text(stoppingWith: "")
        #expect(unstated == "Here are five.")
    }

    @Test("An ordinary round is untouched — detection costs the happy path nothing")
    func anOrdinaryRoundStillAnswers() async throws {
        let transport = FakeHTTPTransport(scripts: [.success(jsonResponse(Self.answerRound))])
        let recorder = ToolRecorder()

        let outcome = try await ToolLoopEngine().run(
            ToolLoopRequest(userText: "hi", tools: [recorder.tool("search_tracks")], model: Self.model),
            connector: Self.connector(transport)
        )
        #expect(outcome.text == "Here are five.")
    }

    // MARK: - The raised ceilings

    @Test("The ceilings are 4096 for the one-shot paths and 8192 for a conversation")
    func ceilingsAreRaised() {
        #expect(AnthropicConnector.maxTokensForStructuredCompletion == 4096)
        #expect(AnthropicConnector.maxTokensForCompletion == 4096)
        #expect(AnthropicConnector.maxTokensForToolLoop == 8192)
    }

    @Test("The raised tool-loop ceiling reaches the wire, not just the constant")
    func theToolLoopBodyCarriesTheRaisedCeiling() async throws {
        let transport = FakeHTTPTransport(scripts: [.success(jsonResponse(Self.answerRound))])
        let recorder = ToolRecorder()

        _ = try await ToolLoopEngine().run(
            ToolLoopRequest(userText: "hi", tools: [recorder.tool("search_tracks")], model: Self.model),
            connector: Self.connector(transport)
        )

        let sent = try #require(await transport.recordedRequests.first?.httpBody)
        let body = try #require(AIJSONValue.decoded(from: sent))
        #expect(body["max_tokens"]?.intValue == 8192)
    }
}
