// ClaudeSubscriptionToolLoopTests — the subscription route's tool round.
//
// The wire shape itself is `AnthropicToolLoopTests`' job; this suite asserts only
// the three things the subscription wrapper adds, because those are the three
// that a `chatTurn` written as a fifth independent method would have silently
// omitted:
//
//   1. the `anthropic-beta` flag that unlocks bearer auth on `/v1/messages`,
//   2. the Claude Code identity line leading the system prompt,
//   3. exactly ONE forced refresh and ONE retry on a 401 — never a loop.
//
// TWO TRANSPORTS, as in `ClaudeSubscriptionConnectorTests`: "how many Messages
// calls" and "how many refreshes" must be separate, unambiguous counts.
import AIConnectorKit
@testable import AIConnectorKitOAuth
import Foundation
import Testing

@Suite("ClaudeSubscriptionToolLoopTests")
struct ClaudeSubscriptionToolLoopTests {
    private static let instructions = "Answer with the library."
    private static let userText = "make me a shoegaze mix"

    private static func request(_ tools: [AITool]) -> ToolLoopRequest {
        ToolLoopRequest(
            instructions: instructions,
            userText: userText,
            tools: tools,
            model: "claude-sonnet-4-5"
        )
    }

    private static let toolUseRound = """
    {"id":"msg_01","stop_reason":"tool_use","content":[
      {"type":"tool_use","id":"toolu_01","name":"search_tracks","input":{"query":"shoegaze"}}]}
    """

    private static let answerRound = """
    {"id":"msg_02","stop_reason":"end_turn","content":[{"type":"text","text":"Here are five."}]}
    """

    private static let unauthorized = HTTPResponse(
        statusCode: 401,
        body: Data(#"{"error":{"type":"authentication_error"}}"#.utf8)
    )

    // MARK: - Happy path

    @Test("A two-round turn rides the subscription route with the engine-supplied token")
    func twoRoundTurnCompletes() async throws {
        let recorder = ToolRecorder(["search_tracks": ["Found 5 tracks."]])
        let context = await SubscriptionToolContext.signedIn(api: [
            .success(toolLoopResponse(Self.toolUseRound)),
            .success(toolLoopResponse(Self.answerRound)),
        ])

        let outcome = try await ToolLoopEngine().run(
            Self.request([recorder.tool("search_tracks")]),
            connector: context.connector
        )

        #expect(outcome.text == "Here are five.")
        #expect(outcome.termination == .answered)
        #expect(outcome.rounds == 2)
        #expect(recorder.invocations.map(\.name) == ["search_tracks"])

        #expect(await context.api.recordedRequests.count == 2)
        #expect(await context.api.recordedHeader("Authorization", at: 0) == "Bearer \(OAuthFixture.accessToken)")
        // The seeded credential is fresh against the fixed clock — nothing refreshed.
        #expect(await context.token.recordedRequests.isEmpty)
    }

    @Test("Every tool round carries BOTH anthropic-beta flags the CLI sends")
    func everyRoundCarriesBothBetaFlags() async throws {
        let recorder = ToolRecorder()
        let context = await SubscriptionToolContext.signedIn(api: [
            .success(toolLoopResponse(Self.toolUseRound)),
            .success(toolLoopResponse(Self.answerRound)),
        ])

        _ = try await ToolLoopEngine().run(
            Self.request([recorder.tool("search_tracks")]),
            connector: context.connector
        )

        for index in 0 ... 1 {
            let beta = try #require(
                await context.api.recordedHeader(ClaudeSubscriptionConnector.betaHeaderField, at: index)
            )
            #expect(beta.contains(ClaudeSubscriptionConnector.oauthAPIBeta))
            #expect(beta.contains(ClaudeSubscriptionConnector.claudeCodeBeta))
        }
    }

    @Test("The identity line is the ONLY system block, verbatim, on every round")
    func systemPromptCarriesTheIdentityBlockAlone() async throws {
        let recorder = ToolRecorder()
        let context = await SubscriptionToolContext.signedIn(api: [
            .success(toolLoopResponse(Self.toolUseRound)),
            .success(toolLoopResponse(Self.answerRound)),
        ])

        _ = try await ToolLoopEngine().run(
            Self.request([recorder.tool("search_tracks")]),
            connector: context.connector
        )

        // MEASURED 2026-09-06 against the live OAuth edge: a CONCATENATED string
        // is refused (HTTP 429 `rate_limit_error`) and a discrete block is
        // accepted (HTTP 200). `hasPrefix` on a joined string would pass for the
        // refused shape too, so the assertion is on the BLOCK, not on the prefix.
        // The COUNT is the fingerprinting mitigation on top of that: a second
        // block is a system prompt Claude Code would never send.
        for index in 0 ... 1 {
            let blocks = try #require(await recordedJSONBody(context.api, at: index)?["system"]?.arrayValue)
            #expect(blocks.count == 1)
            #expect(blocks.first?["type"]?.stringValue == "text")
            #expect(blocks.first?["text"]?.stringValue == ClaudeSubscriptionConnector.claudeCodeSystemPreamble)
        }
    }

    @Test("The framing rides the OLDEST message, exactly once, on every round of a multi-turn transcript")
    func framingRidesTheOldestMessageExactlyOnce() async throws {
        let recorder = ToolRecorder(["search_tracks": ["Found 5 tracks."]])
        let context = await SubscriptionToolContext.signedIn(api: [
            .success(toolLoopResponse(Self.toolUseRound)),
            .success(toolLoopResponse(Self.answerRound)),
        ])
        let request = ToolLoopRequest(
            instructions: Self.instructions,
            history: [.user("what did I listen to last week"), .assistant("Mostly shoegaze.")],
            userText: Self.userText,
            tools: [recorder.tool("search_tracks")],
            model: "claude-sonnet-4-5"
        )

        _ = try await ToolLoopEngine().run(request, connector: context.connector)

        for index in 0 ... 1 {
            // Counted over the RAW body, which also proves the text is no longer
            // in `system`: the loop runs up to twenty rounds against a growing
            // transcript, so a non-idempotent prepend would show up as a rising
            // count rather than as a failure on round one.
            let body = try #require(await context.api.recordedBody(index))
            #expect(body.components(separatedBy: Self.instructions).count - 1 == 1)

            let contents = try #require(await proseContents(context.api, at: index))
            #expect(contents.first == "\(Self.instructions)\n\nwhat did I listen to last week")
            // The turn being answered is LAST and stays untouched — prepending
            // there would re-state the framing on every round.
            #expect(contents.last == Self.userText)
        }
    }

    @Test("An already-framed caller does not put the identity line on the wire twice")
    func callerSuppliedFramingIsNotDoubled() async throws {
        let preamble = ClaudeSubscriptionConnector.claudeCodeSystemPreamble
        let context = await SubscriptionToolContext.signedIn(api: [
            .success(toolLoopResponse(Self.answerRound)),
        ])
        let request = ToolLoopRequest(
            instructions: "\(preamble)\n\n\(Self.instructions)",
            userText: Self.userText,
            tools: [],
            model: "claude-sonnet-4-5"
        )

        _ = try await ToolLoopEngine().run(request, connector: context.connector)

        let blocks = try #require(await recordedJSONBody(context.api, at: 0)?["system"]?.arrayValue)
        #expect(blocks == [.object([
            "type": .string("text"),
            "text": .string(preamble),
        ])])
        // The whole point: the line appears in block 0 and NOWHERE else — least
        // of all in the prose, which is where the caller's copy would have landed.
        let body = try #require(await context.api.recordedBody(0))
        #expect(body.components(separatedBy: preamble).count - 1 == 1)
        let contents = try #require(await proseContents(context.api, at: 0))
        #expect(contents == ["\(Self.instructions)\n\n\(Self.userText)"])
    }

    @Test("The tool list still reaches the wire through the wrapper")
    func toolsSurviveTheWrapper() async throws {
        let recorder = ToolRecorder()
        let context = await SubscriptionToolContext.signedIn(api: [
            .success(toolLoopResponse(Self.answerRound)),
        ])

        _ = try await ToolLoopEngine().run(
            Self.request([recorder.tool("search_tracks", schema: ToolFixture.looseSchema)]),
            connector: context.connector
        )

        let tools = try #require(await recordedJSONBody(context.api, at: 0)?["tools"]?.arrayValue)
        #expect(tools[0]["name"]?.stringValue == "search_tracks")
        #expect(tools[0]["input_schema"] == ToolFixture.looseSchema)
        // The real `search_tracks` shape cannot honour strict mode.
        #expect(tools[0]["strict"]?.boolValue == false)
    }

    // MARK: - The 401 contract

    @Test("A 401 on a tool round forces EXACTLY one refresh and one retry")
    func aRejectedTokenRefreshesOnceAndRetriesOnce() async throws {
        let recorder = ToolRecorder(["search_tracks": ["Found 5 tracks."]])
        let context = await SubscriptionToolContext.signedIn(
            api: [
                .success(Self.unauthorized),
                .success(toolLoopResponse(Self.toolUseRound)),
                .success(toolLoopResponse(Self.answerRound)),
            ],
            token: [.success(OAuthFixture.tokenResponse(
                accessToken: OAuthFixture.rotatedAccessToken,
                refreshToken: OAuthFixture.rotatedRefreshToken
            ))]
        )

        let outcome = try await ToolLoopEngine().run(
            Self.request([recorder.tool("search_tracks")]),
            connector: context.connector
        )

        #expect(outcome.text == "Here are five.")
        // Rejected, retried, then a second normal round: three API calls, ONE
        // refresh.
        #expect(await context.api.recordedRequests.count == 3)
        #expect(await context.token.recordedRequests.count == 1)
        // The retry — and every round after it — uses the rotated token.
        #expect(await context.api.recordedHeader("Authorization", at: 1)
            == "Bearer \(OAuthFixture.rotatedAccessToken)")
    }

    @Test("A second 401 surfaces unchanged rather than looping the token endpoint")
    func aPermanentlyDeadSessionDoesNotLoop() async throws {
        let context = await SubscriptionToolContext.signedIn(
            api: [.success(Self.unauthorized), .success(Self.unauthorized)],
            token: [.success(OAuthFixture.tokenResponse(
                accessToken: OAuthFixture.rotatedAccessToken,
                refreshToken: OAuthFixture.rotatedRefreshToken
            ))]
        )

        await #expect(throws: ConnectorFailure.authExpired) {
            _ = try await ToolLoopEngine().run(Self.request([]), connector: context.connector)
        }
        #expect(await context.api.recordedRequests.count == 2)
        #expect(await context.token.recordedRequests.count == 1)
    }
}

/// A signed-in subscription stack with separate API and token transports.
private struct SubscriptionToolContext {
    let engine: OAuthCredentialEngine
    let connector: ClaudeSubscriptionConnector
    let api: FakeTokenTransport
    let token: FakeTokenTransport

    static func signedIn(
        api apiScripts: [FakeTokenTransport.Script] = [],
        token tokenScripts: [FakeTokenTransport.Script] = []
    ) async -> SubscriptionToolContext {
        let api = FakeTokenTransport(apiScripts)
        let token = FakeTokenTransport(tokenScripts)
        let engine = OAuthCredentialEngine(
            store: InMemorySecretStore(),
            configuration: OAuthFixture.testConfiguration(),
            transport: token,
            now: TestClock().now
        )
        try? await engine.seed(OAuthFixture.credentials())
        return SubscriptionToolContext(
            engine: engine,
            connector: ClaudeSubscriptionConnector(
                engine: engine,
                transport: api,
                baseURL: URL(fileURLWithPath: "/fixture-anthropic")
            ),
            api: api,
            token: token
        )
    }
}
