// OAuthEndpointConfiguration — every endpoint and parameter of a subscription
// OAuth flow, expressed as DATA rather than as literals inside the flow logic.
//
// ── WHY NOTHING IS BAKED INTO THE FLOW ────────────────────────────────────────
//
// Claude's subscription (Pro/Max) OAuth is an UNOFFICIAL, undocumented surface.
// Anthropic has moved the token host, renamed the console domain, and rotated the
// required scope set at least three times across 2025-2026 — each time silently
// breaking every third-party client that hardcoded the previous answer. So
// ``ClaudeOAuthFlow`` and ``OAuthCredentialEngine`` read EVERY host, path, id,
// scope and body-encoding decision out of this value. When Anthropic moves
// something, the fix is one constant here (or an injected configuration from the
// shell) — never a change to the PKCE code, which is RFC-defined and stable.
//
// This mirrors the jarvis precedent, where the same constants are overridable at
// runtime through `JARVIS_OAUTH_*` environment variables for exactly this reason
// (`orchestrator/src/llm/core/auth/oauth_login.ts`).
//
// ── THE RESEARCHED CONSTANT SET ───────────────────────────────────────────────
//
// See ``OAuthEndpointConfiguration/claudeSubscription`` below: each constant
// carries its source and the date it was checked. The full research record,
// including the combinations known to FAIL, lives in
// `.omo/evidence/ai-provider-connectors/todo-17-claude-oauth.txt`.
import AIConnectorKit
import Foundation

/// Where a subscription OAuth flow talks, and in what dialect.
///
/// A plain `Sendable` value with `public var` members: a caller builds one from a
/// default and mutates the fields it needs (a test points ``tokenURL`` at a
/// fixture host; a future shell could expose an override). There is no builder
/// and no singleton, so two flows can run against two configurations in one
/// process without global state.
public struct OAuthEndpointConfiguration: Sendable, Equatable {
    /// How the token endpoint wants its POST body.
    ///
    /// Both dialects have been observed returning 200 from Anthropic's token
    /// host, and different reference implementations ship different choices — so
    /// this is a knob, not a constant. See the note on
    /// ``OAuthEndpointConfiguration/claudeSubscription``.
    public enum BodyEncoding: String, Sendable, Equatable, CaseIterable {
        /// `application/json`.
        case json
        /// `application/x-www-form-urlencoded`.
        case form

        /// The `Content-Type` this encoding sends.
        public var contentType: String {
            switch self {
            case .json: "application/json"
            case .form: "application/x-www-form-urlencoded"
            }
        }
    }

    /// Where the listener authorizes, in a browser.
    public var authorizeURL: URL

    /// Where the authorization code is exchanged, and where refreshes are POSTed.
    public var tokenURL: URL

    /// The `redirect_uri` sent on BOTH the authorize request and the exchange.
    ///
    /// A `String`, not a `URL`: the two flavours in the wild are a hosted
    /// callback page (manual `code#state` paste) and a loopback
    /// `http://127.0.0.1:<port>/callback`, and the exchange must echo back
    /// byte-identically whatever was sent to authorize. Round-tripping through
    /// `URL` risks normalising a trailing slash and failing the server's exact
    /// string comparison.
    public var redirectURI: String

    /// The public OAuth client id. Not a secret — it ships in every client.
    public var clientID: String

    /// Scopes requested at authorize time, in order. Joined with a single space.
    public var scopes: [String]

    /// Provider-specific query items appended to the authorize URL, in order,
    /// BEFORE the standard OAuth ones.
    ///
    /// For Claude this carries `code=true`, which is what makes the authorize
    /// page display a pasteable `code#state` instead of redirecting.
    public var extraAuthorizeQueryItems: [URLQueryItem]

    /// Dialect for the token endpoint's POST body (exchange and refresh alike).
    public var tokenBodyEncoding: BodyEncoding

    /// `User-Agent` for the token endpoint, or `nil` to send none.
    ///
    /// NOT cosmetic: the token host fingerprints this header, and a client
    /// sending an unexpected agent is rate-limited (HTTP 429) rather than
    /// authenticated.
    public var tokenRequestUserAgent: String?

    /// Whether the `state` value is echoed in the exchange body.
    ///
    /// Anthropic's exchange accepts it; a stricter RFC 6749 server would ignore
    /// it. Kept injectable so todo 19's provider can turn it off.
    public var sendsStateInExchangeBody: Bool

    /// Whether the scope list is repeated in the refresh body.
    public var sendsScopeInRefreshBody: Bool

    /// Access-token lifetime assumed when a token response omits `expires_in`.
    public var defaultAccessTokenLifetime: TimeInterval

    /// How long before real expiry a token is treated as stale.
    ///
    /// Absorbs clock skew and the latency of the request the token is about to
    /// authenticate — without it, a token that passes the freshness check can
    /// still expire in flight.
    public var expiryBuffer: TimeInterval

    /// Hard cap on one token-endpoint round-trip (exchange or refresh).
    public var tokenRequestDeadline: TimeInterval

    /// The space-separated `scope` parameter value.
    public var scopeParameterValue: String {
        scopes.joined(separator: " ")
    }

    /// - Parameters:
    ///   - authorizeURL: Browser authorize endpoint.
    ///   - tokenURL: Exchange + refresh endpoint.
    ///   - redirectURI: Sent verbatim to both, so the server's exact-match check passes.
    ///   - clientID: Public client id.
    ///   - scopes: Requested scopes, in order.
    public init(
        authorizeURL: URL,
        tokenURL: URL,
        redirectURI: String,
        clientID: String,
        scopes: [String],
        extraAuthorizeQueryItems: [URLQueryItem] = [],
        tokenBodyEncoding: BodyEncoding = .json,
        tokenRequestUserAgent: String? = nil,
        sendsStateInExchangeBody: Bool = true,
        sendsScopeInRefreshBody: Bool = true,
        defaultAccessTokenLifetime: TimeInterval = 28800,
        expiryBuffer: TimeInterval = 60,
        tokenRequestDeadline: TimeInterval = 15
    ) {
        self.authorizeURL = authorizeURL
        self.tokenURL = tokenURL
        self.redirectURI = redirectURI
        self.clientID = clientID
        self.scopes = scopes
        self.extraAuthorizeQueryItems = extraAuthorizeQueryItems
        self.tokenBodyEncoding = tokenBodyEncoding
        self.tokenRequestUserAgent = tokenRequestUserAgent
        self.sendsStateInExchangeBody = sendsStateInExchangeBody
        self.sendsScopeInRefreshBody = sendsScopeInRefreshBody
        self.defaultAccessTokenLifetime = defaultAccessTokenLifetime
        self.expiryBuffer = expiryBuffer
        self.tokenRequestDeadline = tokenRequestDeadline
    }
}

public extension OAuthEndpointConfiguration {
    // swiftlint:disable line_length
    /// The Claude Pro/Max subscription flow, as verified on **2026-08-21**.
    ///
    /// EVERY constant below was checked against current reference
    /// implementations on that date. Anthropic ships no documentation for this
    /// flow, so "verified" means "at least two independent working clients agree,
    /// and at least one of them derived the value empirically". Re-verify before
    /// shipping a release; the full record (including the failing combinations)
    /// is in `.omo/evidence/ai-provider-connectors/todo-17-claude-oauth.txt`.
    ///
    /// | Constant | Value | Attested by (checked 2026-08-21) |
    /// |---|---|---|
    /// | `client_id` | `9d1c250a-…962f5e` | `askalf/dario` `src/cc-oauth-detect.ts` (extracted from the Claude Code
    /// v2.1.104 PROD block); `V1ki/dsh-plugin-subscriptions` `src/providers/claude.ts`; jarvis `credentials.ts:52` |
    /// | authorize | `https://claude.ai/oauth/authorize` | `askalf/dario` — empirically verified against Claude Code
    /// v2.1.116, which opens this host directly; jarvis `oauth_login.ts` |
    /// | token | `https://platform.claude.com/v1/oauth/token` | `askalf/dario` (from the CC binary); jarvis
    /// `credentials.ts:50` |
    /// | redirect | `https://platform.claude.com/oauth/code/callback` | `askalf/dario` `MANUAL_REDIRECT_URI`; jarvis
    /// `oauth_login.ts` |
    /// | scopes | the six below | `askalf/dario` + `V1ki/dsh-plugin-subscriptions` (both on the 6-scope set as of
    /// 2026-08) |
    /// | `code=true` | required | `V1ki/dsh-plugin-subscriptions` `buildAuthorizeUrl`; jarvis `oauth_login.ts` |
    /// | body | JSON | `V1ki/dsh-plugin-subscriptions`; jarvis. Form also returns 200 — see below. |
    /// | rotation | refresh token is SINGLE-USE | jarvis `verified-oauth.md` (live-validated 2026-06-18);
    /// `askalf/dario` `isTerminalRefreshFailure` |
    ///
    /// THE PLAN'S CANDIDATES WERE STALE. `.omo/plans/ai-provider-connectors.md`
    /// named `console.anthropic.com/v1/oauth/token` for exchange; Anthropic has
    /// since renamed that console domain, and `platform.claude.com` is what
    /// current clients use. `api.anthropic.com/v1/oauth/token` — the other
    /// obvious guess — is a KNOWN-FAILING host (400/401): `api.anthropic.com`
    /// serves the Messages API, not the OAuth token endpoint. The authorize host
    /// `claude.com/cai/oauth/authorize` appears in older clients and now fails
    /// post-redirect validation with "Invalid request format"; `claude.ai` is the
    /// live one.
    ///
    /// SCOPES ARE THE MOST VOLATILE CONSTANT. Anthropic has rotated between a
    /// five- and a six-scope requirement repeatedly (dario shipped 6 → 5 → 6
    /// across its 3.x line, tracking upstream). Six is current. A live
    /// "Invalid request format" from the authorize page is the signature of a
    /// scope-set mismatch — drop `org:create_api_key` and retry. Because the
    /// whole set is injectable, that is a configuration change, not a release.
    /// (jarvis currently ships the five-scope variant; this default follows the
    /// two sources that were re-checked on 2026-08-21.)
    ///
    /// BODY ENCODING is `.json` because that is what both current reference
    /// clients send on the exchange. jarvis's live probe (2026-06-18) found the
    /// token host answers 200 to BOTH JSON and form encodings, so `.form` is a
    /// supported fallback rather than a rewrite.
    ///
    /// THE USER-AGENT IS LOAD-BEARING. jarvis's live validation found the token
    /// endpoint fingerprints this header and rate-limits (429) a client that does
    /// not look like the reference implementation's HTTP stack. This is a
    /// single-source finding, which is precisely why it is a configuration field:
    /// if the fingerprint changes, so does one line here.
    static var claudeSubscription: OAuthEndpointConfiguration {
        OAuthEndpointConfiguration(
            authorizeURL: URL(string: "https://claude.ai/oauth/authorize") ?? fallbackURL,
            tokenURL: URL(string: "https://platform.claude.com/v1/oauth/token") ?? fallbackURL,
            redirectURI: "https://platform.claude.com/oauth/code/callback",
            clientID: "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
            scopes: [
                "org:create_api_key",
                "user:profile",
                "user:inference",
                "user:sessions:claude_code",
                "user:mcp_servers",
                "user:file_upload",
            ],
            extraAuthorizeQueryItems: [URLQueryItem(name: "code", value: "true")],
            tokenBodyEncoding: .json,
            tokenRequestUserAgent: "axios/1.13.6"
        )
    }

    // swiftlint:enable line_length

    /// Unreachable in practice — the two literals above are valid URLs, and
    /// `URLSessionTransport` would fail this host immediately if they ever
    /// weren't. Exists only so the defaults need no force-unwrap; the kit bans
    /// `force_unwrapping` and a `fatalError` here would turn a typo into a crash
    /// on a listener's Mac.
    private static var fallbackURL: URL {
        URL(fileURLWithPath: "/")
    }
}

extension OAuthEndpointConfiguration {
    /// Builds a POST to ``tokenURL`` carrying `fields` in the configured dialect.
    ///
    /// The single place a token-endpoint request is constructed, shared by the
    /// exchange (``ClaudeOAuthFlow``) and the refresh (``OAuthCredentialEngine``)
    /// so the two can never drift on encoding, `Content-Type`, or the
    /// fingerprinted `User-Agent`.
    ///
    /// `fields` is an ORDERED array, not a dictionary: form bodies must encode
    /// deterministically for a test to assert on the exact bytes, and
    /// `JSONSerialization` on a dictionary does not promise key order either.
    func tokenRequest(fields: [(name: String, value: String)]) -> URLRequest {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue(tokenBodyEncoding.contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let agent = tokenRequestUserAgent {
            request.setValue(agent, forHTTPHeaderField: "User-Agent")
        }
        request.httpBody = Self.body(for: fields, encoding: tokenBodyEncoding)
        return request
    }

    private static func body(
        for fields: [(name: String, value: String)],
        encoding: BodyEncoding
    ) -> Data {
        switch encoding {
        case .json:
            jsonBody(for: fields)
        case .form:
            formBody(for: fields)
        }
    }

    /// Hand-rolled rather than `JSONSerialization`, so field ORDER survives into
    /// the bytes and a fixture test can compare the body verbatim.
    private static func jsonBody(for fields: [(name: String, value: String)]) -> Data {
        let pairs = fields.map { "\(escapedJSON($0.name)):\(escapedJSON($0.value))" }
        return Data("{\(pairs.joined(separator: ","))}".utf8)
    }

    private static func escapedJSON(_ text: String) -> String {
        var escaped = ""
        for character in text.unicodeScalars {
            switch character {
            case "\"": escaped += "\\\""
            case "\\": escaped += "\\\\"
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            default:
                if character.value < 0x20 {
                    escaped += String(format: "\\u%04x", character.value)
                } else {
                    escaped.unicodeScalars.append(character)
                }
            }
        }
        return "\"\(escaped)\""
    }

    private static func formBody(for fields: [(name: String, value: String)]) -> Data {
        let pairs = fields.map { "\(formEscaped($0.name))=\(formEscaped($0.value))" }
        return Data(pairs.joined(separator: "&").utf8)
    }

    /// `application/x-www-form-urlencoded` percent-encoding.
    ///
    /// The allowed set is spelled out rather than borrowed from
    /// `.urlQueryAllowed`, which permits `+`, `&` and `=` — every one of which
    /// would corrupt a body carrying a base64url PKCE verifier or a token.
    private static func formEscaped(_ text: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }
}
