// ClaudeOAuthFlow — the PKCE authorization-code grant, in two phases.
//
// ── WHY TWO PHASES ────────────────────────────────────────────────────────────
//
// The listener authorizes in a BROWSER, outside this process, so the grant
// cannot be one call:
//
//   1. ``authorizeRequest()`` mints the PKCE secret and an independent CSRF
//      `state`, and returns the URL to open plus the two values the caller must
//      retain.
//   2. ``exchange(pastedValue:request:)`` (or the `code`/`state` overload)
//      validates what came back and trades the code for tokens.
//
// The flow SEEDS credentials and then gets out of the way: it never refreshes,
// never persists, and never holds a token past the return statement.
// ``OAuthCredentialEngine`` owns storage, expiry and rotation. Splitting it this
// way means the login UI (todo 18) depends on the flow only, and the connector
// depends on the engine only — neither can accidentally acquire the other's job.
// This is the jarvis split (`oauth_login.ts` seeds; `credentials.ts` rotates).
//
// ── SECRECY ───────────────────────────────────────────────────────────────────
//
// The verifier, the authorization code and both tokens exist only as locals and
// as fields of redacting types. Nothing here logs, and ``OAuthFlowError`` carries
// no payload richer than an HTTP status.
import AIConnectorKit
import CryptoKit
import Foundation

/// Runs the Claude subscription PKCE grant against an injected configuration.
///
/// Provider-agnostic apart from its name and its default configuration: todo 19's
/// ChatGPT engine reuses this type by passing a different
/// ``OAuthEndpointConfiguration``.
public struct ClaudeOAuthFlow: Sendable {
    /// PKCE verifier entropy. 32 bytes is 43 base64url characters — the RFC 7636
    /// minimum, and what every reference client uses.
    public static let codeVerifierByteCount = 32

    /// CSRF `state` entropy, drawn INDEPENDENTLY of the verifier.
    ///
    /// Deriving `state` from the verifier (a hash, a prefix, the same bytes)
    /// would publish information about the verifier in a query string that
    /// travels through the browser's history, the referrer chain, and the
    /// provider's access logs. They protect different things and must not share
    /// entropy.
    public static let stateByteCount = 32

    /// The endpoints and parameters this flow talks to.
    public let configuration: OAuthEndpointConfiguration

    private let transport: any HTTPTransport
    private let randomBytes: @Sendable (Int) -> Data
    private let now: @Sendable () -> Date

    /// - Parameters:
    ///   - configuration: Endpoints and parameters. Defaults to the researched
    ///     Claude set — see ``OAuthEndpointConfiguration/claudeSubscription``.
    ///   - transport: The single network seam. Tests pass a scripted fake, so the
    ///     suite makes zero live requests.
    ///   - randomBytes: Entropy source. Injectable so a test can pin the verifier,
    ///     challenge and state to known values and assert the URL byte-for-byte.
    ///   - now: Wall clock, used only to stamp the token's expiry.
    public init(
        configuration: OAuthEndpointConfiguration = .claudeSubscription,
        transport: any HTTPTransport = URLSessionTransport(),
        randomBytes: @escaping @Sendable (Int) -> Data = ClaudeOAuthFlow.systemRandomBytes,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.configuration = configuration
        self.transport = transport
        self.randomBytes = randomBytes
        self.now = now
    }

    /// Phase 1's output: the URL to open, plus the two values phase 2 needs back.
    ///
    /// Redacts on description — it holds the PKCE verifier, which is a secret for
    /// the lifetime of the login attempt.
    public struct AuthorizeRequest: Sendable, Equatable {
        /// Open this in the listener's browser.
        public var url: URL

        /// SECRET. Proves to the token endpoint that the client which redeems the
        /// code is the one that requested it.
        public var codeVerifier: String

        /// CSRF nonce. Must come back unchanged, or the callback is not ours.
        public var state: String

        public init(url: URL, codeVerifier: String, state: String) {
            self.url = url
            self.codeVerifier = codeVerifier
            self.state = state
        }
    }

    /// Phase 1: mint the PKCE material and build the authorize URL.
    ///
    /// The caller opens ``AuthorizeRequest/url`` and RETAINS the whole value —
    /// both the verifier and the state are required to complete the grant.
    ///
    /// Query-item order is deterministic: the configuration's extras first (so
    /// Claude's `code=true` leads, matching the reference clients), then the
    /// standard OAuth parameters in RFC order.
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

    /// Phase 2, hosted-callback variant: split a pasted `code#state` and exchange it.
    ///
    /// The hosted redirect page renders the two values joined by `#`, which is
    /// what the listener copies. A loopback redirect delivers them as separate
    /// query parameters instead — use ``exchange(code:state:request:)`` there.
    public func exchange(pastedValue: String, request: AuthorizeRequest) async throws -> OAuthCredentials {
        let (code, state) = try Self.splitCodeAndState(pastedValue)
        return try await exchange(code: code, state: state, request: request)
    }

    /// Phase 2: validate `state`, then trade `code` for a full credential.
    ///
    /// The state check happens BEFORE the network call, on purpose: a code that
    /// arrived with a foreign state may belong to an attacker's session, and
    /// redeeming it would bind this listener's client to that account. Refusing
    /// costs a restarted login; redeeming costs the whole point of the parameter.
    ///
    /// - Throws: ``OAuthFlowError/stateMismatch`` on a foreign callback,
    ///   ``OAuthFlowError/tokenEndpointRejected(status:)`` on a non-2xx exchange,
    ///   ``OAuthFlowError/tokenResponseMissingRefreshToken`` when the grant would
    ///   not be renewable, or a ``ConnectorFailure`` from the transport — including
    ///   ``ConnectorFailure/timeout`` once the configured exchange deadline elapses.
    public func exchange(code: String, state: String, request: AuthorizeRequest) async throws -> OAuthCredentials {
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

        let token = try await send(configuration.tokenRequest(fields: fields))
        // Fatal only on an INITIAL exchange: this grant type always issues a
        // refresh token, so its absence means a session that could never renew.
        // The engine's refresh path treats the same absence as "keep the one we
        // already hold" — see `OAuthCredentialEngine.rotate`.
        guard let refreshToken = token.refreshToken else {
            throw OAuthFlowError.tokenResponseMissingRefreshToken
        }
        return OAuthCredentials(
            accessToken: token.accessToken,
            refreshToken: refreshToken,
            expiresAt: now().addingTimeInterval(token.expiresIn ?? configuration.defaultAccessTokenLifetime),
            subscriptionType: token.subscriptionType,
            scopes: token.scopes ?? configuration.scopes
        )
    }

    /// Cryptographically secure randomness, via CryptoKit's key generator.
    ///
    /// Public because it is the default argument of ``init(configuration:transport:randomBytes:now:)``
    /// — a default expression is evaluated in the CALLER's module, so it cannot
    /// name a private symbol.
    public static func systemRandomBytes(_ count: Int) -> Data {
        SymmetricKey(size: SymmetricKeySize(bitCount: count * 8)).withUnsafeBytes { Data($0) }
    }

    /// POSTs to the token endpoint under the configured deadline.
    ///
    /// The deadline wraps the WHOLE round-trip rather than relying on
    /// `URLSessionTransport`'s own timer, so an injected transport (a fake, or a
    /// future one) inherits the cap too.
    private func send(_ request: URLRequest) async throws -> OAuthTokenResponse {
        let transport = transport
        let response = try await withDeadline(seconds: configuration.tokenRequestDeadline) {
            try await transport.send(request)
        }
        guard response.isSuccess else {
            throw OAuthFlowError.tokenEndpointRejected(status: response.statusCode)
        }
        return try OAuthTokenResponse.decode(response.body)
    }

    /// `BASE64URL(SHA256(ASCII(verifier)))`, per RFC 7636 §4.2.
    ///
    /// The digest is taken over the ASCII bytes of the base64url verifier STRING,
    /// not over the raw entropy that produced it. That distinction is the whole
    /// interoperability contract: the server only ever receives the string, so it
    /// can only re-derive the challenge from the string. Hashing the pre-encoding
    /// bytes yields a challenge no provider will accept.
    private static func codeChallenge(for verifier: String) -> String {
        base64URLUnpadded(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// Base64url with padding stripped (RFC 4648 §5), which is what OAuth wants
    /// everywhere: `+` and `/` are not query-safe and `=` is not path-safe.
    private static func base64URLUnpadded(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Splits `code#state` on the FIRST `#`.
    ///
    /// First, not last: base64url never contains `#`, but the code is opaque and
    /// a future format change that introduced one must not silently reassign the
    /// halves.
    private static func splitCodeAndState(_ pasted: String) throws -> (code: String, state: String) {
        let trimmed = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let separator = trimmed.firstIndex(of: "#") else {
            throw OAuthFlowError.malformedCallbackValue
        }
        let code = String(trimmed[trimmed.startIndex ..< separator])
        let state = String(trimmed[trimmed.index(after: separator)...])
        guard code.isEmpty == false, state.isEmpty == false else {
            throw OAuthFlowError.malformedCallbackValue
        }
        return (code, state)
    }
}

extension ClaudeOAuthFlow.AuthorizeRequest: CustomStringConvertible, CustomDebugStringConvertible {
    /// Redacted: reports the authorize HOST only. Even the full URL is unsafe to
    /// print — its query carries the `code_challenge` and the `state`.
    public var description: String {
        "AuthorizeRequest(host: \(url.host() ?? "unknown"), codeVerifier: redacted, state: redacted)"
    }

    public var debugDescription: String {
        description
    }
}
