// Hermetic proof of the ChatGPT/Codex PKCE grant. ZERO live network, ZERO real
// entropy, ZERO real clock — the same discipline as the Claude suites, and for
// the same reason: PKCE and rotation can only be asserted EXACTLY when every
// non-deterministic input is injected.
//
// Every fake secret here is prefixed `test-token-`, including the signature
// segment of the fixture JWT, so `ChatGPTSecretLeakTests` can grep for one
// literal and catch a leak through any rendering route.
import AIConnectorKit
@testable import AIConnectorKitOAuth
import CryptoKit
import Foundation
import Testing

enum ChatGPTFixture {
    static let accessToken = "test-token-chatgpt-access-alpha"
    static let refreshToken = "test-token-chatgpt-refresh-alpha"
    static let rotatedAccessToken = "test-token-chatgpt-access-beta"
    static let rotatedRefreshToken = "test-token-chatgpt-refresh-beta"
    static let authorizationCode = "test-token-chatgpt-authcode-gamma"

    /// NOT `test-token-` prefixed on purpose: an account id is a workspace name,
    /// not a credential, and the leak suite must not be taught to treat it as one.
    static let accountID = "acct-fixture-alpha"

    static let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    /// 64 bytes — ChatGPT's verifier budget, twice Claude's.
    static let verifierEntropy = Data(repeating: 0x03, count: 64)
    static let stateEntropy = Data(repeating: 0x04, count: 32)

    /// A syntactically real JWT whose payload carries the namespaced claims, and
    /// whose SIGNATURE segment is a literal `test-token-` marker so the whole
    /// string is still grep-detectable if it ever escapes into an error.
    static func identityToken(
        expiresAt: Date? = ChatGPTFixture.epoch.addingTimeInterval(3600),
        accountID: String? = ChatGPTFixture.accountID,
        planType: String? = "pro"
    ) -> String {
        var claims: [String: Any] = [:]
        if let expiresAt {
            claims["exp"] = expiresAt.timeIntervalSince1970
        }
        var namespaced: [String: Any] = [:]
        if let accountID {
            namespaced["chatgpt_account_id"] = accountID
        }
        if let planType {
            namespaced["chatgpt_plan_type"] = planType
        }
        if namespaced.isEmpty == false {
            claims[ChatGPTOAuthFlow.identityClaimNamespace] = namespaced
        }
        let payload = (try? JSONSerialization.data(withJSONObject: claims)) ?? Data()
        let header = Data("{\"alg\":\"RS256\",\"typ\":\"JWT\"}".utf8)
        return "\(expectedBase64URL(header)).\(expectedBase64URL(payload)).test-token-chatgpt-signature"
    }

    /// The upstream token response: `id_token`, `access_token`, `refresh_token`,
    /// and NO `expires_in`.
    static func tokenResponse(
        accessToken: String = ChatGPTFixture.accessToken,
        refreshToken: String? = ChatGPTFixture.refreshToken,
        identityToken: String? = ChatGPTFixture.identityToken()
    ) -> HTTPResponse {
        var fields = ["\"access_token\": \"\(accessToken)\""]
        if let refreshToken {
            fields.append("\"refresh_token\": \"\(refreshToken)\"")
        }
        if let identityToken {
            fields.append("\"id_token\": \"\(identityToken)\"")
        }
        return HTTPResponse(
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            body: Data("{\(fields.joined(separator: ","))}".utf8)
        )
    }

    /// Points the researched configuration at unroutable fixture hosts, so no
    /// suite can reach OpenAI even by accident.
    static func testConfiguration(deadline: TimeInterval = 15) -> OAuthEndpointConfiguration {
        var configuration = OAuthEndpointConfiguration.chatGPTSubscription
        configuration.authorizeURL = URL(fileURLWithPath: "/fixture-chatgpt-authorize")
        configuration.tokenURL = URL(fileURLWithPath: "/fixture-chatgpt-token")
        configuration.tokenRequestDeadline = deadline
        return configuration
    }

    static func flow(
        transport: FakeTokenTransport,
        configuration: OAuthEndpointConfiguration = ChatGPTFixture.testConfiguration(),
        clock: TestClock = TestClock()
    ) -> ChatGPTOAuthFlow {
        ChatGPTOAuthFlow(
            configuration: configuration,
            transport: transport,
            randomBytes: ScriptedRandomBytes([verifierEntropy, stateEntropy]).provider,
            now: clock.now
        )
    }
}
