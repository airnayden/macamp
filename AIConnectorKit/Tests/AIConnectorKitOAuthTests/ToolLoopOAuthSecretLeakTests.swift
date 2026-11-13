// ToolLoopOAuthSecretLeakTests — the leak proof for the tool-calling path on the
// two SUBSCRIPTION connectors.
//
// Higher stakes than the API-key half: an OAuth stack holds a refresh token as
// well as an access token, and the refresh token is the long-lived one. So both
// are asserted, and both are asserted across a ROTATION — the moment a second
// pair of credentials exists and a naive diagnostic is most likely to capture one.
//
// Same structural argument as the kit's `ToolLoopSecretLeakTests`: a credential
// rides a HEADER, never a body, so nothing the loop derives from bodies can carry
// one. Asserted per connector rather than claimed.
import AIConnectorKit
@testable import AIConnectorKitOAuth
import Foundation
import Testing

@Suite("ToolLoopOAuthSecretLeakTests")
struct ToolLoopOAuthSecretLeakTests {
    private static let secrets = [
        OAuthFixture.accessToken,
        OAuthFixture.refreshToken,
        OAuthFixture.rotatedAccessToken,
        OAuthFixture.rotatedRefreshToken,
        ChatGPTFixture.accessToken,
        ChatGPTFixture.refreshToken,
        "test-token-",
    ]

    private func assertNoLeak(_ rendered: String, _ context: Comment) {
        for secret in Self.secrets {
            #expect(rendered.contains(secret) == false, context)
        }
    }

    private func assertNoLeakEverywhere(_ value: some Any, _ label: String) {
        assertNoLeak(String(describing: value), "describing \(label)")
        assertNoLeak("\(value)", "interpolating \(label)")
        assertNoLeak(String(reflecting: value), "reflecting \(label)")
        var dumped = ""
        dump(value, to: &dumped)
        assertNoLeak(dumped, "dump of \(label)")
    }

    private static func request(_ tools: [AITool]) -> ToolLoopRequest {
        ToolLoopRequest(
            instructions: "Be useful.",
            userText: "make me a shoegaze mix",
            tools: tools,
            model: "fixture-model"
        )
    }

    private static let chatGPTRounds = [
        #"""
        {"id":"resp_01","output":[
          {"id":"fc_01","call_id":"call_01","type":"function_call","name":"search_tracks",
           "arguments":"{\"query\":\"shoegaze\"}"}]}
        """#,
        """
        {"id":"resp_02","output":[{"type":"message","role":"assistant",
         "content":[{"type":"output_text","text":"Here are five."}]}]}
        """,
    ]

    private static let anthropicRounds = [
        """
        {"id":"msg_01","stop_reason":"tool_use","content":[
          {"type":"tool_use","id":"toolu_01","name":"search_tracks","input":{"query":"shoegaze"}}]}
        """,
        """
        {"id":"msg_02","stop_reason":"end_turn","content":[{"type":"text","text":"Here are five."}]}
        """,
    ]

    // MARK: - ChatGPT

    @Test("The ChatGPT tool loop keeps the bearer token out of every body and every value it produces")
    func chatGPTToolLoopIsSecretFree() async throws {
        let recorder = ToolRecorder(["search_tracks": ["Found 5 tracks."]])
        let transport = FakeTokenTransport(Self.chatGPTRounds.map { .success(toolLoopResponse($0)) })
        let connector = ChatGPTConnector(
            bearerToken: { ChatGPTFixture.accessToken },
            transport: transport
        )

        let outcome = try await ToolLoopEngine().run(
            Self.request([recorder.tool("search_tracks")]),
            connector: connector
        )

        #expect(outcome.termination == .answered)
        // The token IS sent — in a header — which is what makes the body
        // assertion a statement about placement rather than about a connector
        // that forgot to authenticate.
        #expect(await transport.recordedHeader("Authorization", at: 0)
            == "Bearer \(ChatGPTFixture.accessToken)")
        let sentCount = await transport.recordedRequests.count
        for index in 0 ..< sentCount {
            let body = await transport.recordedBody(index)
            assertNoLeak(body ?? "", "ChatGPT request body \(index)")
        }
        assertNoLeakEverywhere(outcome, "ChatGPT outcome")
        assertNoLeakEverywhere(outcome.events, "ChatGPT events")
    }

    @Test("A refused ChatGPT tool round renders no credential through any route")
    func refusedChatGPTRoundIsSecretFree() async throws {
        let transport = FakeTokenTransport([
            .success(toolLoopResponse("{\"error\":\"unauthorized\"}", statusCode: 401)),
        ])
        let connector = ChatGPTConnector(
            bearerToken: { ChatGPTFixture.accessToken },
            transport: transport
        )

        do {
            _ = try await ToolLoopEngine().run(Self.request([]), connector: connector)
            Issue.record("A 401 must throw")
        } catch {
            assertNoLeakEverywhere(error, "the refused round")
            assertNoLeak(error.localizedDescription, "localizedDescription of the refused round")
        }
    }

    // MARK: - Claude subscription

    @Test("The subscription tool loop keeps BOTH tokens out of every body, across a rotation")
    func claudeSubscriptionToolLoopIsSecretFreeAcrossRotation() async throws {
        let recorder = ToolRecorder(["search_tracks": ["Found 5 tracks."]])
        let api = FakeTokenTransport([
            // A 401 first, so the whole rotation path runs and a SECOND pair of
            // credentials exists while the loop is mid-turn.
            .success(HTTPResponse(statusCode: 401, body: Data(#"{"error":{"type":"authentication_error"}}"#.utf8))),
            .success(toolLoopResponse(Self.anthropicRounds[0])),
            .success(toolLoopResponse(Self.anthropicRounds[1])),
        ])
        let token = FakeTokenTransport([
            .success(OAuthFixture.tokenResponse(
                accessToken: OAuthFixture.rotatedAccessToken,
                refreshToken: OAuthFixture.rotatedRefreshToken
            )),
        ])
        let engine = OAuthCredentialEngine(
            store: InMemorySecretStore(),
            configuration: OAuthFixture.testConfiguration(),
            transport: token,
            now: TestClock().now
        )
        try await engine.seed(OAuthFixture.credentials())
        let connector = ClaudeSubscriptionConnector(
            engine: engine,
            transport: api,
            baseURL: URL(fileURLWithPath: "/fixture-anthropic")
        )

        let outcome = try await ToolLoopEngine().run(
            Self.request([recorder.tool("search_tracks")]),
            connector: connector
        )

        #expect(outcome.termination == .answered)
        #expect(await token.recordedRequests.count == 1)
        // The Messages bodies never carry either token…
        let sentCount = await api.recordedRequests.count
        for index in 0 ..< sentCount {
            let body = await api.recordedBody(index)
            assertNoLeak(body ?? "", "subscription request body \(index)")
        }
        // …and neither do any of the values the loop produced.
        assertNoLeakEverywhere(outcome, "subscription outcome")
        assertNoLeakEverywhere(outcome.events, "subscription events")
    }

    @Test("A permanently dead subscription session renders no credential when it finally gives up")
    func deadSubscriptionSessionIsSecretFree() async throws {
        let unauthorized = HTTPResponse(
            statusCode: 401,
            body: Data(#"{"error":{"type":"authentication_error"}}"#.utf8)
        )
        let api = FakeTokenTransport([.success(unauthorized), .success(unauthorized)])
        let token = FakeTokenTransport([
            .success(OAuthFixture.tokenResponse(
                accessToken: OAuthFixture.rotatedAccessToken,
                refreshToken: OAuthFixture.rotatedRefreshToken
            )),
        ])
        let engine = OAuthCredentialEngine(
            store: InMemorySecretStore(),
            configuration: OAuthFixture.testConfiguration(),
            transport: token,
            now: TestClock().now
        )
        try await engine.seed(OAuthFixture.credentials())
        let connector = ClaudeSubscriptionConnector(
            engine: engine,
            transport: api,
            baseURL: URL(fileURLWithPath: "/fixture-anthropic")
        )

        do {
            _ = try await ToolLoopEngine().run(Self.request([]), connector: connector)
            Issue.record("A permanently rejected session must throw")
        } catch {
            assertNoLeakEverywhere(error, "the dead session")
            assertNoLeak(error.localizedDescription, "localizedDescription of the dead session")
        }
    }
}
