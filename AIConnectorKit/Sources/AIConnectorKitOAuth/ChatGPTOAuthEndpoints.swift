// ChatGPTOAuthEndpoints.swift — the researched ChatGPT/Codex constant set, split
// out of `ChatGPTOAuthFlow.swift`.
//
// Split for one mechanical reason: `.swiftlint.yml` does not override
// `file_length`, so SwiftLint's 400-line ceiling applies and CI runs `--strict`.
// The repo has done exactly this before (`AnthropicWireTypes.swift`,
// `AppSettings+DesignTokens.swift`). This file owns no behaviour — it is one
// `static var` and its research record, which makes it the block that moves.
//
// The record itself is load-bearing, not decoration: the plan mandates
// research-at-implementation-time with source + date for every constant, because
// this is an UNOFFICIAL, undocumented, actively-shifting surface. The same
// discipline todo 17 applied to Claude.
import AIConnectorKit
import Foundation

public extension OAuthEndpointConfiguration {
    // swiftlint:disable line_length
    /// The ChatGPT/Codex subscription flow, RE-VERIFIED **2026-08-24**.
    ///
    /// ── WHY THIS SET CHANGED ──────────────────────────────────────────────────
    ///
    /// The 2026-08-21 revision of this table shipped `originator=macamp` and a
    /// determination that the connector could not be driven end to end. Both were
    /// reversed on 2026-08-24 for a reason outside the code: on **2026-08-21**
    /// OpenAI's Codex lead publicly ENDORSED third-party open-source clients using
    /// "Sign in with ChatGPT" per-user OAuth. That removes the impersonation
    /// objection that made `originator=codex_cli_rs` unacceptable — sending the
    /// value the endorsed flow expects is now using a sanctioned integration path
    /// rather than pretending to be OpenAI's binary — and it is also what the
    /// authorize endpoint requires to serve the simplified consent screen.
    ///
    /// ── SOURCES (checked 2026-08-24) ──────────────────────────────────────────
    ///
    /// S1 = `openai/codex` at HEAD `d21794d` (2026-08-24) — first-party.
    /// S2 = `opencode` at HEAD `611cc73` — an independent client shipping the same
    /// flow. S3 = the 2026-08-21 endorsement thread. S1 and S2 agree on every
    /// constant below except the scope set, where they DELIBERATELY differ (see
    /// the scope note).
    ///
    /// | Constant | Value | Attested by |
    /// |---|---|---|
    /// | `client_id` | `app_EMoamEEZ73f0CkXaXp7hrann` | S1 `CLIENT_ID`, S2 |
    /// | authorize | `https://auth.openai.com/oauth/authorize` | S1 `build_authorize_url`, S2 |
    /// | token | `https://auth.openai.com/oauth/token` | S1 exchange + `REFRESH_TOKEN_URL`, S2 |
    /// | redirect | `http://localhost:1455/auth/callback` | S1 `DEFAULT_PORT` 1455, fallback 1457 |
    /// | scopes | the six below | S1; S2 ships four — see below |
    /// | extras | `id_token_add_organizations`, `codex_cli_simplified_flow`, `originator` | S1, S2 |
    /// | `originator` | `codex_cli_rs` | S1; endorsed by S3 |
    /// | body | form-urlencoded | S1, S2 |
    /// | `expires_in` | ABSENT — expiry is the access token's JWT `exp` | S1 `TokenResponse` |
    /// | verifier | 64 bytes | S1 `pkce.rs`. Claude's is 32 — do not assume they match. |
    /// | API base | `https://chatgpt.com/backend-api/codex` | S1, S2 `codex.ts` |
    ///
    /// ── THE SCOPE SET IS SIX, NOT FOUR ────────────────────────────────────────
    ///
    /// S2 requests only `openid profile email offline_access`. That shorter string
    /// authenticates fine and then fails at USE time: the completion endpoint
    /// answers HTTP 429 `insufficient_quota` on accounts whose plan gates
    /// connector invocation, because the token carries no `api.connectors.*`
    /// grant. The two extra scopes are therefore not optional decoration, and this
    /// default follows S1. Because `scopes` is injectable, a rotation is a
    /// configuration change rather than a release.
    ///
    /// ── `tokenRequestUserAgent` STAYS `nil` ───────────────────────────────────
    ///
    /// Unlike Anthropic's token host (see ``claudeSubscription``), this endpoint
    /// does not fingerprint the agent, and no source shows a client that must send
    /// one. Sending nothing is both accurate and one less constant to re-verify.
    static var chatGPTSubscription: OAuthEndpointConfiguration {
        OAuthEndpointConfiguration(
            authorizeURL: URL(string: "https://auth.openai.com/oauth/authorize") ?? chatGPTFallbackURL,
            tokenURL: URL(string: "https://auth.openai.com/oauth/token") ?? chatGPTFallbackURL,
            redirectURI: chatGPTRedirectURI(port: chatGPTPrimaryCallbackPort),
            clientID: "app_EMoamEEZ73f0CkXaXp7hrann",
            scopes: [
                "openid",
                "profile",
                "email",
                "offline_access",
                "api.connectors.read",
                "api.connectors.invoke",
            ],
            extraAuthorizeQueryItems: [
                URLQueryItem(name: "id_token_add_organizations", value: "true"),
                URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
                URLQueryItem(name: "originator", value: chatGPTOriginator),
            ],
            tokenBodyEncoding: .form,
            tokenRequestUserAgent: nil,
            // Upstream sends exactly grant_type/code/redirect_uri/client_id/
            // code_verifier on the exchange. An echoed `state` is accepted by
            // RFC 6749 servers but is not part of the observed request, and the
            // whole point of matching the observed request is that a bot-
            // mitigated endpoint compares it against a known shape.
            sendsStateInExchangeBody: false,
            // No `expires_in` in the response, so ``OAuthCredentialEngine``'s
            // refresh falls back to this. Eight hours matches the JWT lifetimes
            // observed in the upstream token type; the exchange path does better
            // by reading `exp` directly.
            defaultAccessTokenLifetime: 28800
        )
    }

    // swiftlint:enable line_length

    /// The `originator` the authorize endpoint expects.
    ///
    /// Sent verbatim because it selects the simplified consent screen that
    /// `codex_cli_simplified_flow=true` opts into; a different value drops the
    /// request onto the generic app-authorization page, which the loopback
    /// redirect is not registered for.
    static var chatGPTOriginator: String {
        "codex_cli_rs"
    }

    /// The loopback port the redirect is registered against.
    static var chatGPTPrimaryCallbackPort: Int {
        1455
    }

    /// The one alternative upstream accepts when 1455 is already bound.
    ///
    /// NOT an arbitrary "next free port": the redirect URI is registered
    /// server-side, so only these two values survive the authorize endpoint's
    /// exact-match check. A listener that fell back to an ephemeral port would
    /// bind a socket the provider will never connect to.
    static var chatGPTFallbackCallbackPort: Int {
        1457
    }

    /// The `redirect_uri` for a given loopback port, in the ONE spelling both ends
    /// must agree on byte-for-byte.
    static func chatGPTRedirectURI(port: Int) -> String {
        "http://localhost:\(port)/auth/callback"
    }

    /// Unreachable in practice — both literals above are valid absolute URLs.
    /// Exists only so the default needs no force-unwrap: the kit bans
    /// `force_unwrapping`, and a `fatalError` would turn a typo into a crash on a
    /// listener's Mac.
    private static var chatGPTFallbackURL: URL {
        URL(fileURLWithPath: "/")
    }
}

public extension ChatGPTOAuthFlow {
    /// A copy of this flow whose `redirect_uri` names `port`.
    ///
    /// The loopback port cannot be decided until a socket is actually BOUND — 1455
    /// may be taken, in which case only 1457 will do — and the authorize URL has to
    /// carry the port that is really listening, byte-identically to what the
    /// exchange later echoes. Rebuilding the flow is how that lands in one place.
    ///
    /// Lives HERE rather than beside the flow's own methods because
    /// `ChatGPTOAuthFlow.swift` sits at SwiftLint's 400-line ceiling, and because
    /// the port constants it reads are this file's.
    func boundToLoopback(port: Int) -> ChatGPTOAuthFlow {
        var rebound = configuration
        rebound.redirectURI = OAuthEndpointConfiguration.chatGPTRedirectURI(port: port)
        return ChatGPTOAuthFlow(
            configuration: rebound,
            transport: transport,
            randomBytes: randomBytes,
            now: now
        )
    }
}
