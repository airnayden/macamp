// ClaudeSubscriptionConnectorTests — the subscription route, end to end, offline.
//
// TWO TRANSPORTS, DELIBERATELY. The connector and the engine each get their own
// ``FakeTokenTransport``, so "how many times did we call the Messages API" and
// "how many times did we refresh" are separate, unambiguous counts. Sharing one
// transport would make the central assertion of this suite — exactly one retry —
// a matter of decoding a mixed request log.
//
// Every fake secret is prefixed `test-token-`, per this target's convention.
import AIConnectorKit
@testable import AIConnectorKitOAuth
import Foundation
import Testing

@Suite("Claude subscription connector")
struct ClaudeSubscriptionConnectorTests {
    // MARK: - Identity

    @Test("Its identity is distinct from the API-key route's, so the two never share a secret")
    func identityIsDistinctFromTheApiKeyRoute() async {
        let context = await SubscriptionContext.signedIn()
        let connector = context.connector

        #expect(connector.id == "claude-subscription")
        #expect(connector.id != AnthropicConnector.connectorID)
        #expect(connector.authDescriptor == .subscription)
        #expect(
            ConnectorSecretService.name(forConnectorID: connector.id)
                != ConnectorSecretService.name(forConnectorID: AnthropicConnector.connectorID)
        )
    }

    // MARK: - Happy path

    @Test("It round-trips against the fixture transport with the engine-supplied token")
    func roundTripsWithTheEngineSuppliedToken() async throws {
        let context = await SubscriptionContext.signedIn(api: [.success(SubscriptionFixture.modelsResponse())])

        let models = try await context.connector.listModels()

        #expect(models.map(\.id) == ["claude-sonnet-4-5", "claude-opus-4-1"])
        let requests = await context.api.recordedRequests
        #expect(requests.count == 1)
        let authorization = await context.api.recordedHeader("Authorization", at: 0)
        #expect(authorization == "Bearer \(OAuthFixture.accessToken)")
        let version = await context.api.recordedHeader("anthropic-version", at: 0)
        #expect(version == AnthropicConnector.anthropicVersion)
        // No refresh: the seeded credential is still fresh against the fixed clock.
        let refreshes = await context.token.recordedRequests
        #expect(refreshes.isEmpty)
    }

    @Test("Every request carries BOTH anthropic-beta flags the CLI sends")
    func requestsCarryBothBetaFlags() async throws {
        let context = await SubscriptionContext.signedIn(api: [.success(SubscriptionFixture.modelsResponse())])

        _ = try await context.connector.listModels()

        let beta = try #require(
            await context.api.recordedHeader(ClaudeSubscriptionConnector.betaHeaderField, at: 0)
        )
        // Asserted as MEMBERSHIP of the comma-joined list as well as verbatim, so a
        // future third feature widens the header without silently dropping one of
        // these two — the pair IS the fingerprinting mitigation.
        #expect(beta.split(separator: ",").map(String.init) == [
            ClaudeSubscriptionConnector.oauthAPIBeta,
            ClaudeSubscriptionConnector.claudeCodeBeta,
        ])
        #expect(beta.contains(ClaudeSubscriptionConnector.oauthAPIBeta))
        #expect(beta.contains(ClaudeSubscriptionConnector.claudeCodeBeta))
    }

    @Test("Structured completion sends the identity line as the ONLY system block")
    func structuredCompletionSendsAnIdentityOnlySystemBlock() async throws {
        let context = await SubscriptionContext.signedIn(api: [.success(SubscriptionFixture.toolUseResponse())])

        let payload = try await context.connector.structuredCompletion(
            schema: SubscriptionFixture.schema,
            instructions: "Answer with a playlist query.",
            prompt: "something upbeat",
            model: "claude-sonnet-4-5"
        )

        #expect(String(bytes: payload, encoding: .utf8) == #"{"genres":["Jazz"]}"#)
        let body = await context.api.recordedBody(0)
        let blocks = try #require(systemBlocks(inBody: body))
        #expect(blocks == [ClaudeSubscriptionConnector.claudeCodeSystemPreamble])
        // Nothing is lost — the framing now opens the user turn instead.
        #expect(userContents(inBody: body) == ["Answer with a playlist query.\n\nsomething upbeat"])
    }

    @Test("Plain completion sends the identity line as the ONLY system block")
    func completionSendsAnIdentityOnlySystemBlock() async throws {
        let context = await SubscriptionContext.signedIn(api: [.success(SubscriptionFixture.textResponse())])

        _ = try await context.connector.completion(
            instructions: "Name this playlist.",
            prompt: "tracks",
            model: "claude-sonnet-4-5"
        )

        let body = await context.api.recordedBody(0)
        let blocks = try #require(systemBlocks(inBody: body))
        #expect(blocks == [ClaudeSubscriptionConnector.claudeCodeSystemPreamble])
        #expect(userContents(inBody: body) == ["Name this playlist.\n\ntracks"])
    }

    @Test("Framing is idempotent — an already-framed caller does not repeat the identity line")
    func framingIsIdempotent() async throws {
        let context = await SubscriptionContext.signedIn(api: [.success(SubscriptionFixture.textResponse())])
        let preamble = ClaudeSubscriptionConnector.claudeCodeSystemPreamble

        _ = try await context.connector.completion(
            instructions: "\(preamble)\n\nName this playlist.",
            prompt: "tracks",
            model: "claude-sonnet-4-5"
        )

        let body = await context.api.recordedBody(0)
        let blocks = try #require(systemBlocks(inBody: body))
        #expect(blocks == [preamble])
        // The line appears in block 0 and NOWHERE else — relocating the caller's
        // copy into the prose would put the fingerprint back on the wire twice.
        let contents = try #require(userContents(inBody: body))
        #expect(contents == ["Name this playlist.\n\ntracks"])
        #expect(contents.contains { $0.contains(preamble) } == false)
    }

    @Test("Blank instructions still send the identity block alone, never an empty second block")
    func blankInstructionsStillCarryTheIdentityBlock() async throws {
        let context = await SubscriptionContext.signedIn(api: [.success(SubscriptionFixture.textResponse())])

        _ = try await context.connector.completion(instructions: "  ", prompt: "tracks", model: "claude-sonnet-4-5")

        let body = await context.api.recordedBody(0)
        let blocks = try #require(systemBlocks(inBody: body))
        #expect(blocks == [ClaudeSubscriptionConnector.claudeCodeSystemPreamble])
    }

    @Test("A nil preamble restores the plain-string system field the API-key route sends")
    func aNilPreambleSendsThePlainStringField() async throws {
        let context = await SubscriptionContext.signedIn(
            api: [.success(SubscriptionFixture.textResponse())],
            systemPreamble: nil
        )

        _ = try await context.connector.completion(
            instructions: "Name this playlist.",
            prompt: "tracks",
            model: "claude-sonnet-4-5"
        )

        let body = await context.api.recordedBody(0)
        #expect(systemStringField(inBody: body) == "Name this playlist.")
        #expect(systemBlocks(inBody: body) == nil)
        // Relocation is gated on the preamble: with no identity block there is no
        // fingerprint to keep clean, and the escape hatch must stay lossless.
        #expect(userContents(inBody: body) == ["tracks"])
    }

    // MARK: - The 401 contract

    @Test("A persistent 401 refreshes exactly once and then surfaces .authExpired")
    func aPersistent401RefreshesOnceThenFails() async throws {
        let context = await SubscriptionContext.signedIn(
            api: [.success(SubscriptionFixture.unauthorized()), .success(SubscriptionFixture.unauthorized())],
            token: [.success(SubscriptionFixture.rotatedTokenResponse())]
        )

        await #expect(throws: ConnectorFailure.authExpired) {
            _ = try await context.connector.listModels()
        }

        // The whole point of the suite: two API attempts, never a third, and
        // exactly one rotation between them.
        let apiRequests = await context.api.recordedRequests
        #expect(apiRequests.count == 2)
        let refreshRequests = await context.token.recordedRequests
        #expect(refreshRequests.count == 1)
    }

    @Test("The retry presents the rotated token, not the one that was rejected")
    func theRetryPresentsTheRotatedToken() async throws {
        let context = await SubscriptionContext.signedIn(
            api: [.success(SubscriptionFixture.unauthorized()), .success(SubscriptionFixture.modelsResponse())],
            token: [.success(SubscriptionFixture.rotatedTokenResponse())]
        )

        let models = try await context.connector.listModels()

        #expect(models.isEmpty == false)
        let first = await context.api.recordedHeader("Authorization", at: 0)
        let second = await context.api.recordedHeader("Authorization", at: 1)
        #expect(first == "Bearer \(OAuthFixture.accessToken)")
        #expect(second == "Bearer \(OAuthFixture.rotatedAccessToken)")
    }

    @Test("A refused refresh surfaces .authExpired without a second API attempt")
    func aRefusedRefreshFailsWithoutRetrying() async throws {
        let context = await SubscriptionContext.signedIn(
            api: [.success(SubscriptionFixture.unauthorized())],
            token: [.success(HTTPResponse(statusCode: 400, body: Data(#"{"error":"invalid_grant"}"#.utf8)))]
        )

        await #expect(throws: ConnectorFailure.authExpired) {
            _ = try await context.connector.listModels()
        }

        let apiRequests = await context.api.recordedRequests
        #expect(apiRequests.count == 1)
    }

    @Test("An unreachable token endpoint propagates unchanged — a flaky network is not a logout")
    func anUnreachableRefreshPropagatesUnchanged() async throws {
        let unreachable = ConnectorFailure.unreachable(underlying: ConnectorFailure.DiagnosticToken.networkUnavailable)
        let context = await SubscriptionContext.signedIn(
            api: [.success(SubscriptionFixture.unauthorized())],
            token: [.failure(unreachable)]
        )

        await #expect(throws: unreachable) {
            _ = try await context.connector.listModels()
        }

        let apiRequests = await context.api.recordedRequests
        #expect(apiRequests.count == 1)
    }

    // MARK: - Unconfigured

    @Test("A connector that was never signed into fails before any transport call")
    func anUnconfiguredConnectorNeverReachesTheNetwork() async throws {
        let context = SubscriptionContext.signedOut()

        let signedIn = await context.connector.isSignedIn()
        #expect(signedIn == false)
        await #expect(throws: ConnectorFailure.unconfigured) {
            _ = try await context.connector.listModels()
        }

        let apiRequests = await context.api.recordedRequests
        #expect(apiRequests.isEmpty)
        let refreshRequests = await context.token.recordedRequests
        #expect(refreshRequests.isEmpty)
    }

    @Test("A signed-in connector reports so without decoding or refreshing")
    func aSignedInConnectorReportsSo() async {
        let context = await SubscriptionContext.signedIn()

        let signedIn = await context.connector.isSignedIn()

        #expect(signedIn)
        let refreshRequests = await context.token.recordedRequests
        #expect(refreshRequests.isEmpty)
    }
}

// MARK: - Scaffolding

/// One assembled subscription stack: engine, connector, and the two transports
/// each of them talks through.
private struct SubscriptionContext {
    let engine: OAuthCredentialEngine
    let connector: ClaudeSubscriptionConnector
    let api: FakeTokenTransport
    let token: FakeTokenTransport

    /// A stack whose engine already holds a FRESH credential against the fixed
    /// clock, so nothing refreshes unless a 401 forces it.
    static func signedIn(
        api apiScripts: [FakeTokenTransport.Script] = [],
        token tokenScripts: [FakeTokenTransport.Script] = [],
        systemPreamble: String? = ClaudeSubscriptionConnector.claudeCodeSystemPreamble
    ) async -> SubscriptionContext {
        let context = make(api: apiScripts, token: tokenScripts, systemPreamble: systemPreamble)
        try? await context.engine.seed(OAuthFixture.credentials())
        return context
    }

    /// A stack with an empty store — the "never signed in" state.
    static func signedOut() -> SubscriptionContext {
        make(api: [], token: [], systemPreamble: ClaudeSubscriptionConnector.claudeCodeSystemPreamble)
    }

    private static func make(
        api apiScripts: [FakeTokenTransport.Script],
        token tokenScripts: [FakeTokenTransport.Script],
        systemPreamble: String?
    ) -> SubscriptionContext {
        let api = FakeTokenTransport(apiScripts)
        let token = FakeTokenTransport(tokenScripts)
        let engine = OAuthCredentialEngine(
            store: InMemorySecretStore(),
            configuration: OAuthFixture.testConfiguration(),
            transport: token,
            now: TestClock().now
        )
        return SubscriptionContext(
            engine: engine,
            connector: ClaudeSubscriptionConnector(
                engine: engine,
                transport: api,
                baseURL: URL(fileURLWithPath: "/fixture-anthropic"),
                systemPreamble: systemPreamble
            ),
            api: api,
            token: token
        )
    }
}

private enum SubscriptionFixture {
    /// Minimal schema — this suite asserts on auth and retry, not on encoding
    /// (`AnthropicConnectorTests` owns the wire-shape proof).
    static let schema = JSONSchemaObject(
        properties: [.init(name: "genres", schema: .array(of: .string()))]
    )

    static func modelsResponse() -> HTTPResponse {
        json("""
        {"data":[
          {"id":"claude-sonnet-4-5","display_name":"Claude Sonnet 4.5"},
          {"id":"claude-opus-4-1","display_name":"Claude Opus 4.1"}
        ]}
        """)
    }

    static func toolUseResponse() -> HTTPResponse {
        json("""
        {"content":[
          {"type":"text","text":"Here you go."},
          {"type":"tool_use","name":"\(AnthropicConnector.structuredToolName)","input":{"genres":["Jazz"]}}
        ]}
        """)
    }

    static func textResponse() -> HTTPResponse {
        json(#"{"content":[{"type":"text","text":"Late Night Jazz"}]}"#)
    }

    /// What the Messages API answers with a token the edge no longer accepts.
    static func unauthorized() -> HTTPResponse {
        HTTPResponse(statusCode: 401, body: Data(#"{"error":{"type":"authentication_error"}}"#.utf8))
    }

    static func rotatedTokenResponse() -> HTTPResponse {
        OAuthFixture.tokenResponse(
            accessToken: OAuthFixture.rotatedAccessToken,
            refreshToken: OAuthFixture.rotatedRefreshToken
        )
    }

    private static func json(_ text: String) -> HTTPResponse {
        HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: Data(text.utf8))
    }
}

/// The `text` of each block in a recorded body's top-level `system` ARRAY, or
/// `nil` when `system` is absent or is a plain string.
///
/// Takes the already-decoded UTF-8 `String` rather than reaching into the actor
/// for a dictionary: `[String: Any]` is not `Sendable`, so it cannot cross an
/// actor boundary at all. The parse therefore happens on this side of the hop.
private func systemBlocks(inBody body: String?) -> [String]? {
    guard let blocks = systemValue(inBody: body) as? [[String: Any]] else { return nil }
    return blocks.compactMap { $0["text"] as? String }
}

/// The top-level `system` field when it is a plain string — the shape the
/// API-key route sends and the subscription route must NOT.
private func systemStringField(inBody body: String?) -> String? {
    systemValue(inBody: body) as? String
}

/// The `content` of each message in a recorded body — where the caller's framing
/// now travels, so a "system is identity-only" assertion can also prove the
/// framing was MOVED rather than dropped.
private func userContents(inBody body: String?) -> [String]? {
    guard let messages = jsonObject(inBody: body)?["messages"] as? [[String: Any]] else { return nil }
    return messages.compactMap { $0["content"] as? String }
}

private func systemValue(inBody body: String?) -> Any? {
    jsonObject(inBody: body)?["system"]
}

private func jsonObject(inBody body: String?) -> [String: Any]? {
    guard let body,
          let object = try? JSONSerialization.jsonObject(with: Data(body.utf8))
    else {
        return nil
    }
    return object as? [String: Any]
}
