// ChatGPTOAuthFlow — the ChatGPT/Codex subscription PKCE grant.
//
// ── WHAT THIS MIRRORS, AND WHERE IT DELIBERATELY DIVERGES ─────────────────────
//
// Structurally this is ``ClaudeOAuthFlow``: two-phase authorization-code grant
// with PKCE, endpoints injected through ``OAuthEndpointConfiguration``, exchange
// bounded by ``withDeadline(seconds:operation:)``, and NOTHING persisted —
// ``OAuthCredentialEngine`` (unmodified, provider-agnostic) owns storage, expiry
// and rotation. Three provider facts force a separate type rather than a second
// default configuration on the Claude one:
//
//   1. THE REDIRECT IS A LOOPBACK LISTENER, not a hosted paste page — so phase 2
//      takes the callback URL, and there is no `code#state` splitting.
//   2. THE TOKEN RESPONSE CARRIES NO `expires_in`. Upstream reads the access
//      token's own JWT `exp` claim instead, so this does too.
//   3. THE RESPONSE CARRIES AN `id_token` whose claims hold the account id the
//      completion endpoint needs as a header. It has nowhere to live in
//      ``OAuthCredentials``, so the exchange returns a ``Session``.
//
// SECRECY: the verifier, the code, the id_token and both tokens exist only as
// locals or as fields of redacting types. Nothing logs, every error is an
// ``OAuthFlowError`` carrying no payload richer than an HTTP status, and the
// id_token is dropped the statement after its claims are read.
import AIConnectorKit
import CryptoKit
import Foundation

/// Runs the ChatGPT subscription PKCE grant against an injected configuration.
public struct ChatGPTOAuthFlow: Sendable {
    /// PKCE verifier entropy, in bytes.
    ///
    /// 64, not Claude's 32. RFC 7636 permits 32–96 bytes of entropy and upstream
    /// draws 64; the challenge is a SHA-256 digest either way, so the only
    /// observable difference is the verifier's length in the exchange body — and
    /// that is exactly the kind of detail a request-shape comparison notices.
    public static let codeVerifierByteCount = 64

    /// CSRF `state` entropy, drawn INDEPENDENTLY of the verifier.
    ///
    /// Deriving one from the other would publish information about the verifier
    /// in a query string that travels through browser history, the referrer
    /// chain and the provider's access logs.
    public static let stateByteCount = 32

    /// The namespace ChatGPT's JWTs nest their account claims under.
    ///
    /// A URI-shaped claim key, per the JWT private-claim convention. The claims
    /// inside it are `chatgpt_account_id`, `chatgpt_plan_type` and
    /// `chatgpt_user_id`; only the first two are read here.
    public static let identityClaimNamespace = "https://api.openai.com/auth"

    /// The endpoints and parameters this flow talks to.
    public let configuration: OAuthEndpointConfiguration

    let transport: any HTTPTransport
    let randomBytes: @Sendable (Int) -> Data
    let now: @Sendable () -> Date

    /// - Parameters:
    ///   - configuration: Endpoints and parameters. Defaults to the researched
    ///     set — see ``OAuthEndpointConfiguration/chatGPTSubscription``.
    ///   - transport: The single network seam. Tests pass a scripted fake, so the
    ///     suite makes zero live requests.
    ///   - randomBytes: Entropy source. Injectable so a test can pin the verifier
    ///     and state to known values and assert the URL exactly.
    ///   - now: Wall clock. Used only when a token carries no readable `exp`.
    public init(
        configuration: OAuthEndpointConfiguration = .chatGPTSubscription,
        transport: any HTTPTransport = URLSessionTransport(),
        randomBytes: @escaping @Sendable (Int) -> Data = ChatGPTOAuthFlow.systemRandomBytes,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.configuration = configuration
        self.transport = transport
        self.randomBytes = randomBytes
        self.now = now
    }

    /// Phase 1's output: the URL to open, plus the two values phase 2 needs back.
    ///
    /// Redacts on description — it holds the PKCE verifier, a secret for the
    /// lifetime of the login attempt.
    public struct AuthorizeRequest: Sendable, Equatable {
        /// Open this in the listener's browser.
        public var url: URL

        /// SECRET. Proves the client redeeming the code is the one that asked.
        public var codeVerifier: String

        /// CSRF nonce. Must come back unchanged, or the callback is not ours.
        public var state: String

        public init(url: URL, codeVerifier: String, state: String) {
            self.url = url
            self.codeVerifier = codeVerifier
            self.state = state
        }
    }

    /// Phase 2's output: the credential, plus the account identity derived from
    /// the `id_token`.
    ///
    /// ``accountID`` is NOT a secret — it names the ChatGPT workspace the tokens
    /// belong to, and the completion endpoint requires it as a plain header. It
    /// is returned rather than persisted because ``OAuthCredentials`` is todo
    /// 17's on-disk contract and widening it would strand every stored blob;
    /// ``ChatGPTConnector`` re-derives the same value from the live access token
    /// on each call, so nothing has to remember it.
    public struct Session: Sendable, Equatable {
        /// The full, renewable credential — hand this to ``OAuthCredentialEngine/seed(_:)``.
        public var credentials: OAuthCredentials

        /// `chatgpt_account_id`, or `nil` when the id_token was absent or opaque.
        public var accountID: String?

        public init(credentials: OAuthCredentials, accountID: String?) {
            self.credentials = credentials
            self.accountID = accountID
        }
    }

    /// Phase 1: mint the PKCE material and build the authorize URL.
    ///
    /// The caller opens ``AuthorizeRequest/url`` and RETAINS the whole value —
    /// both the verifier and the state are required to finish the grant.
    ///
    /// Query-item order is deterministic: the configuration's extras first, then
    /// the standard OAuth parameters in RFC order.
    public func authorizeRequest() throws -> AuthorizeRequest {
        let verifier = Self.base64URLUnpadded(randomBytes(Self.codeVerifierByteCount))
        let state = Self.base64URLUnpadded(randomBytes(Self.stateByteCount))

        guard var components = URLComponents(url: configuration.authorizeURL, resolvingAgainstBaseURL: false) else {
            throw OAuthFlowError.authorizeRequestUnbuildable
        }
        components.queryItems = configuration.extraAuthorizeQueryItems + [
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: configuration.redirectURI),
            URLQueryItem(name: "scope", value: configuration.scopeParameterValue),
            URLQueryItem(name: "code_challenge", value: Self.codeChallenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        guard let url = components.url else {
            throw OAuthFlowError.authorizeRequestUnbuildable
        }
        return AuthorizeRequest(url: url, codeVerifier: verifier, state: state)
    }

    /// Phase 2, loopback variant: pull `code` and `state` out of the callback URL.
    ///
    /// The redirect is `http://localhost:<port>/auth/callback`, so a one-shot
    /// listener receives the values as query parameters rather than as a pasted
    /// string. A callback carrying an `error` parameter is refused HERE, before
    /// any exchange, because there is no code to redeem and the error text is the
    /// provider's, not something this type is willing to carry.
    public func exchange(callbackURL: URL, request: AuthorizeRequest) async throws -> Session {
        guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              let items = components.queryItems
        else {
            throw OAuthFlowError.malformedCallbackValue
        }
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }
        guard value("error") == nil else {
            throw OAuthFlowError.malformedCallbackValue
        }
        guard let code = value("code"), let state = value("state") else {
            throw OAuthFlowError.malformedCallbackValue
        }
        return try await exchange(code: code, state: state, request: request)
    }

    /// Phase 2: validate `state`, then trade `code` for a full credential.
    ///
    /// The state check happens BEFORE the network call: a code that arrived with
    /// a foreign state may belong to an attacker's session, and redeeming it
    /// would bind this listener's client to that account.
    ///
    /// - Throws: ``OAuthFlowError/stateMismatch`` on a foreign callback,
    ///   ``OAuthFlowError/tokenEndpointRejected(status:)`` on a non-2xx exchange,
    ///   ``OAuthFlowError/tokenResponseMissingRefreshToken`` when the grant would
    ///   not be renewable, or a ``ConnectorFailure`` from the transport —
    ///   including ``ConnectorFailure/timeout`` once the deadline elapses.
    public func exchange(code: String, state: String, request: AuthorizeRequest) async throws -> Session {
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        let state = state.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.isEmpty == false, state.isEmpty == false else {
            throw OAuthFlowError.malformedCallbackValue
        }
        guard state == request.state else {
            throw OAuthFlowError.stateMismatch
        }

        var fields: [(name: String, value: String)] = [
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", configuration.redirectURI),
            ("client_id", configuration.clientID),
            ("code_verifier", request.codeVerifier),
        ]
        if configuration.sendsStateInExchangeBody {
            fields.append(("state", state))
        }

        let body = try await send(configuration.tokenRequest(fields: fields))
        let token = try OAuthTokenResponse.decode(body)
        // Fatal only on an INITIAL exchange: this grant type always issues a
        // refresh token, so its absence means a session that could never renew.
        // The engine's refresh path treats the same absence as "keep the one we
        // already hold" — see `OAuthCredentialEngine.rotate`.
        guard let refreshToken = token.refreshToken else {
            throw OAuthFlowError.tokenResponseMissingRefreshToken
        }

        let identity = Self.identityToken(in: body)
        let credentials = OAuthCredentials(
            accessToken: token.accessToken,
            refreshToken: refreshToken,
            expiresAt: expiry(for: token),
            subscriptionType: token.subscriptionType ?? identity.flatMap { Self.planType(inJWT: $0) },
            scopes: token.scopes ?? configuration.scopes
        )
        return Session(
            credentials: credentials,
            accountID: identity.flatMap { Self.accountIdentifier(inJWT: $0) }
        )
    }

    /// Cryptographically secure randomness, via CryptoKit's key generator.
    ///
    /// Public because it is the default argument of the initializer — a default
    /// expression is evaluated in the CALLER's module, so it cannot name a
    /// private symbol.
    public static func systemRandomBytes(_ count: Int) -> Data {
        SymmetricKey(size: SymmetricKeySize(bitCount: count * 8)).withUnsafeBytes { Data($0) }
    }

    /// `chatgpt_account_id` from a ChatGPT-issued JWT, or `nil`.
    ///
    /// The signature is NOT verified, and deliberately so: this process is the
    /// token's OWNER, not its audience. Verification would need OpenAI's JWKS —
    /// a network call, on a code path whose whole job is to read a header value
    /// the server will re-validate anyway. A forged token here buys an attacker
    /// a wrong `ChatGPT-Account-Id`, which the endpoint rejects.
    public static func accountIdentifier(inJWT token: String) -> String? {
        namespacedClaim("chatgpt_account_id", inJWT: token)
    }

    /// `chatgpt_plan_type` (`plus`, `pro`, `team`, …) from a ChatGPT JWT, or `nil`.
    public static func planType(inJWT token: String) -> String? {
        namespacedClaim("chatgpt_plan_type", inJWT: token)
    }

    /// The `exp` claim as a `Date`, or `nil` when absent or unreadable.
    ///
    /// This is the ONLY expiry signal the provider gives: its token response
    /// carries no `expires_in`.
    public static func expiry(inJWT token: String) -> Date? {
        guard let seconds = payload(inJWT: token)?["exp"] as? NSNumber else { return nil }
        return Date(timeIntervalSince1970: seconds.doubleValue)
    }

    /// Prefers `expires_in`, then the access token's `exp`, then the configured
    /// default — in that order, because each is strictly less authoritative than
    /// the one before it.
    private func expiry(for token: OAuthTokenResponse) -> Date {
        if let lifetime = token.expiresIn {
            return now().addingTimeInterval(lifetime)
        }
        if let claimed = Self.expiry(inJWT: token.accessToken) {
            return claimed
        }
        return now().addingTimeInterval(configuration.defaultAccessTokenLifetime)
    }

    /// POSTs to the token endpoint under the configured deadline, returning the
    /// RAW body.
    ///
    /// Raw rather than decoded because the exchange needs one field
    /// (``id_token``) that ``OAuthTokenResponse`` does not model — that type is
    /// todo 17's, shared with the refresh path, and widening it for a
    /// ChatGPT-only claim would push provider specifics into shared code.
    ///
    /// The deadline wraps the WHOLE round-trip rather than relying on
    /// `URLSessionTransport`'s own timer, so an injected transport inherits it.
    private func send(_ request: URLRequest) async throws -> Data {
        let transport = transport
        let response = try await withDeadline(seconds: configuration.tokenRequestDeadline) {
            try await transport.send(request)
        }
        guard response.isSuccess else {
            throw OAuthFlowError.tokenEndpointRejected(status: response.statusCode)
        }
        return response.body
    }

    /// The `id_token` string from a token-endpoint body, without retaining the
    /// rest of the payload.
    private static func identityToken(in body: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: body),
              let json = object as? [String: Any],
              let token = json["id_token"] as? String,
              token.isEmpty == false
        else {
            return nil
        }
        return token
    }

    private static func namespacedClaim(_ name: String, inJWT token: String) -> String? {
        guard let namespace = payload(inJWT: token)?[identityClaimNamespace] as? [String: Any],
              let value = namespace[name] as? String,
              value.isEmpty == false
        else {
            return nil
        }
        return value
    }

    /// Decodes a JWT's payload segment. Returns `nil` for anything that is not
    /// three base64url segments whose middle one is a JSON object — an opaque
    /// token is a normal outcome, not an error.
    private static func payload(inJWT token: String) -> [String: Any]? {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3, let data = base64URLDecoded(String(segments[1])) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// `BASE64URL(SHA256(ASCII(verifier)))`, per RFC 7636 §4.2.
    ///
    /// The digest is taken over the ASCII bytes of the base64url verifier STRING,
    /// not over the raw entropy behind it. The server only ever receives the
    /// string, so it can only re-derive the challenge from the string.
    private static func codeChallenge(for verifier: String) -> String {
        base64URLUnpadded(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// Base64url with padding stripped (RFC 4648 §5): `+` and `/` are not
    /// query-safe and `=` is not path-safe.
    private static func base64URLUnpadded(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// The inverse, restoring the `=` padding `Data(base64Encoded:)` insists on.
    private static func base64URLDecoded(_ text: String) -> Data? {
        var padded = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        padded += String(repeating: "=", count: (4 - padded.count % 4) % 4)
        return Data(base64Encoded: padded)
    }
}

extension ChatGPTOAuthFlow.AuthorizeRequest: CustomStringConvertible, CustomDebugStringConvertible {
    /// Redacted: reports the authorize HOST only. Even the full URL is unsafe to
    /// print — its query carries the `code_challenge` and the `state`.
    public var description: String {
        "ChatGPTAuthorizeRequest(host: \(url.host() ?? "unknown"), codeVerifier: redacted, state: redacted)"
    }

    public var debugDescription: String {
        description
    }
}

extension ChatGPTOAuthFlow.Session: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// Redacted. ``OAuthCredentials`` redacts itself, but a synthesised
    /// description here would still be one refactor away from printing a token,
    /// and `dump` bypasses `CustomStringConvertible` entirely — which is what
    /// `CustomReflectable` closes.
    public var description: String {
        "ChatGPTSession(credentials: \(credentials), accountID: \(accountID ?? "unknown"))"
    }

    public var debugDescription: String {
        description
    }

    public var customMirror: Mirror {
        Mirror(self, children: ["description": description], displayStyle: .struct)
    }
}
