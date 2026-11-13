// OAuthCredentialEngine — the only thing that owns a stored subscription credential.
//
// ── THE ONE CORRECTNESS REQUIREMENT ───────────────────────────────────────────
//
// The provider's refresh token is SINGLE-USE: every successful refresh issues a
// replacement and invalidates the token that was presented. Two consequences
// drive this whole file.
//
//   1. WRITE-BACK IS MANDATORY, NOT AN OPTIMISATION. A refresh whose rotated
//      token is not persisted leaves the store holding a dead token. The listener
//      keeps working until the access token expires — up to eight hours later —
//      and is then logged out with no action of theirs to blame it on. So the
//      rotated blob is persisted BEFORE the new access token is handed out.
//
//   2. CONCURRENT REFRESHES MUST BE SINGLE-FLIGHTED. Two callers refreshing with
//      the same token means the second presents one the provider has already
//      invalidated; it fails, and worse, the winner's rotated token may be
//      overwritten by the loser's stale write. An `actor` alone does NOT prevent
//      this — actor methods suspend at every `await`, releasing isolation — so
//      the in-flight refresh is memoised as a `Task` that late callers join.
//
// ── UPDATE-ONLY WRITE-BACK ────────────────────────────────────────────────────
//
// ``rotate(_:with:)`` starts from the credential already stored and overwrites
// ONLY the fields the response actually carried. A refresh response that omits
// `refresh_token` therefore KEEPS the existing one rather than nulling it — some
// providers rotate on every refresh, some only occasionally, and treating
// "absent" as "revoked" would log the listener out on a perfectly good response.
// The mirror-image rule is that a seed must be COMPLETE (``seed(_:)`` rejects a
// partial one): update-only semantics cannot repair a blob that never had the
// field to begin with.
//
// ── TWO CREDENTIAL SOURCES, ONE ENGINE ────────────────────────────────────────
//
// A credential can also come from ANOTHER application the listener is already
// signed into (see ``ExternalCredentialSource``). That is a SOURCE, not a second
// engine: rotation is still single-use, still single-flighted, and still written
// back before the new access token is handed out — the only thing that varies is
// WHERE the write lands. Precedence is fixed and not configurable: MacAMP's own
// blob wins whenever one exists, and the external source is consulted only when
// this app has never been signed in. Anything else would let a stale reused
// session shadow a login the listener performed here.
//
// The origin-aware halves of that live in `OAuthCredentialEngine+External.swift`
// — split out because `type_body_length` is capped at 250 under
// `swiftlint --strict` and an extension's members do not count toward it.
import AIConnectorKit
import Foundation

/// Stores, renews and rotates one subscription credential.
///
/// An `actor` because the connector reads tokens from arbitrary tasks while the
/// login UI seeds from the main actor. Provider-agnostic: the Claude specifics
/// all live in the injected ``OAuthEndpointConfiguration``, so todo 19's ChatGPT
/// engine is this type with a different configuration and account name.
public actor OAuthCredentialEngine {
    /// Secret-store account for the Claude subscription blob, inside
    /// ``ConnectorOAuthInfo/keychainService``.
    public static let claudeAccount = "claude"

    /// The endpoints this engine refreshes against.
    public let configuration: OAuthEndpointConfiguration

    let store: any SecretStore
    let service: String
    let account: String

    /// Another application's login this engine may reuse, or `nil`.
    ///
    /// `internal` rather than `private` so the origin-aware extension in
    /// `OAuthCredentialEngine+External.swift` can reach it — a stored property
    /// must live in the main declaration, but the logic over it need not.
    let externalSource: (any ExternalCredentialSource)?

    private let transport: any HTTPTransport
    private let now: @Sendable () -> Date

    /// Set by ``signOut()``: stops this process consulting ``externalSource``
    /// without deleting a credential that is not ours. Cleared by ``seed(_:)``.
    var isExternalSuppressed = false

    /// Memoised in-flight refresh. See this file's header — an actor alone is not
    /// enough to make rotation safe.
    private var inFlightRefresh: Task<OAuthCredentials, Error>?

    /// - Parameters:
    ///   - store: Where the blob lives. Tests inject `InMemorySecretStore`.
    ///   - configuration: Endpoints and timings.
    ///   - transport: The single network seam.
    ///   - service: Secret-store service namespace.
    ///   - account: Slot within that namespace — one per signed-in provider.
    ///   - now: Wall clock. Injectable so expiry behaviour is testable without sleeping.
    ///   - externalSource: A credential another application already holds, consulted
    ///     ONLY when `store` is empty. `nil` — the default — keeps the engine
    ///     exactly as it behaved before reuse existed.
    public init(
        store: any SecretStore,
        configuration: OAuthEndpointConfiguration = .claudeSubscription,
        transport: any HTTPTransport = URLSessionTransport(),
        service: String = ConnectorOAuthInfo.keychainService,
        account: String = OAuthCredentialEngine.claudeAccount,
        now: @escaping @Sendable () -> Date = Date.init,
        externalSource: (any ExternalCredentialSource)? = nil
    ) {
        self.store = store
        self.configuration = configuration
        self.transport = transport
        self.service = service
        self.account = account
        self.now = now
        self.externalSource = externalSource
    }

    /// Persists a COMPLETE credential, replacing anything already stored.
    ///
    /// Called once per login with ``ClaudeOAuthFlow``'s exchange result. Rejects a
    /// blob missing either token: the write-back path is update-only, so a
    /// partial seed is not a smaller credential — it is a credential whose first
    /// rotation silently drops a field. Failing loudly here is the only place
    /// that mistake is still cheap.
    ///
    /// - Throws: ``OAuthFlowError/partialCredentialSeedRejected`` on an incomplete
    ///   blob, or a `SecretStoreError` from the backing store.
    public func seed(_ credentials: OAuthCredentials) async throws {
        guard credentials.accessToken.isEmpty == false, credentials.refreshToken.isEmpty == false else {
            throw OAuthFlowError.partialCredentialSeedRejected
        }
        // A login performed HERE outranks a reused one and un-suppresses reuse:
        // the app-owned blob now wins by precedence anyway, so leaving the latch
        // set would only strand the listener if they later removed it.
        isExternalSuppressed = false
        try await persistToOwnStore(credentials)
    }

    /// The stored credential, or `nil` when this provider was never signed into.
    ///
    /// - Throws: ``ConnectorFailure/authExpired`` when a blob EXISTS but cannot be
    ///   decoded. That is not a transport problem and not a missing configuration:
    ///   the bytes are there and unusable, and the only remedy is a fresh login —
    ///   which is exactly what `.authExpired` asks the shell to offer.
    public func storedCredentials() async throws -> OAuthCredentials? {
        try await storedCredentialReading()?.credentials
    }

    /// Whether a credential is available, without decoding or refreshing it.
    ///
    /// The cheap gate for a registry availability probe: it must not trigger a
    /// network refresh just to answer "is this connector set up?". A reused
    /// external credential counts — being signed into the other application IS
    /// being set up, which is the whole point of consulting it.
    public func hasStoredCredentials() async -> Bool {
        if let blob = try? await store.get(service: service, account: account), blob != nil {
            return true
        }
        return await externalReading() != nil
    }

    /// A usable bearer token, refreshing first if the stored one is near expiry.
    ///
    /// The lazy token source connectors call on every request. A still-fresh token
    /// costs one store read and no network at all.
    ///
    /// - Throws: ``ConnectorFailure/unconfigured`` when nothing is stored,
    ///   ``ConnectorFailure/authExpired`` when the provider refused the refresh.
    public func accessToken() async throws -> String {
        let current = try await requireCredentials()
        if current.credentials.isFresh(at: now(), buffer: configuration.expiryBuffer) {
            return current.credentials.accessToken
        }
        return try await refresh(from: current).accessToken
    }

    /// Refreshes regardless of the stored expiry, and returns the new token.
    ///
    /// This is the 401 handler's path: the provider has rejected a token our clock
    /// still considered fresh (revoked, or rotated by another client), so the
    /// expiry check must be bypassed rather than trusted. Callers retry ONCE — a
    /// loop here would hammer the token endpoint on a permanently dead session.
    @discardableResult
    public func forceRefresh() async throws -> String {
        let current = try await requireCredentials()
        return try await refresh(from: current).accessToken
    }

    /// Forgets the credential. Idempotent, matching ``SecretStore/delete(service:account:)``.
    ///
    /// A REUSED credential is never deleted — it belongs to another application,
    /// and destroying someone else's login to express "stop using it here" is not
    /// a trade this engine is willing to make. Instead the external source is
    /// suppressed for the life of this process; a relaunch finds the other app
    /// still signed in and reuses it again, which is the honest outcome of "we
    /// only ever borrowed this".
    public func signOut() async throws {
        inFlightRefresh?.cancel()
        inFlightRefresh = nil
        isExternalSuppressed = true
        try await store.delete(service: service, account: account)
    }

    private func requireCredentials() async throws -> StoredCredentialReading {
        guard let stored = try await storedCredentialReading() else {
            throw ConnectorFailure.unconfigured
        }
        return stored
    }

    /// Joins the in-flight refresh, or starts the only one.
    private func refresh(from current: StoredCredentialReading) async throws -> OAuthCredentials {
        if let existing = inFlightRefresh {
            return try await existing.value
        }
        let task = Task { try await self.performRefresh(from: current) }
        inFlightRefresh = task
        defer { inFlightRefresh = nil }
        return try await task.value
    }

    /// One `grant_type=refresh_token` round-trip, persisted before it is returned.
    ///
    /// FAILURE MAPPING — the distinction is deliberate:
    ///
    /// - The provider ANSWERED and refused (any non-2xx), or answered with
    ///   something carrying no access token ⇒ ``ConnectorFailure/authExpired``.
    ///   The session is over; the listener must sign in again.
    /// - The provider was never REACHED (`.unreachable`, `.timeout`, `.cancelled`
    ///   from the transport or the deadline) ⇒ propagated unchanged. Collapsing a
    ///   flaky network into `.authExpired` would throw away a perfectly valid
    ///   session and demand a re-login the listener cannot complete offline.
    private func performRefresh(from reading: StoredCredentialReading) async throws -> OAuthCredentials {
        let current = reading.credentials
        var fields: [(name: String, value: String)] = [
            ("grant_type", "refresh_token"),
            ("refresh_token", current.refreshToken),
            ("client_id", configuration.clientID),
        ]
        if configuration.sendsScopeInRefreshBody {
            let scopes = current.scopes.isEmpty ? configuration.scopes : current.scopes
            if scopes.isEmpty == false {
                fields.append(("scope", scopes.joined(separator: " ")))
            }
        }

        let request = configuration.tokenRequest(fields: fields)
        let transport = transport
        let response = try await withDeadline(seconds: configuration.tokenRequestDeadline) {
            try await transport.send(request)
        }
        guard response.isSuccess, let token = try? OAuthTokenResponse.decode(response.body) else {
            throw ConnectorFailure.authExpired
        }

        let rotated = rotate(current, with: token)
        // Persist BEFORE returning: a caller that used the new access token while
        // the store still held the dead refresh token would be authenticated now
        // and unrecoverable later.
        try await persist(rotated, to: reading.origin)
        return rotated
    }

    /// Update-only merge — see this file's header.
    ///
    /// Every field starts at its stored value and is overwritten only if the
    /// response supplied a replacement. `refresh_token` is the case that matters:
    /// absent means UNCHANGED, never revoked.
    private func rotate(_ current: OAuthCredentials, with token: OAuthTokenResponse) -> OAuthCredentials {
        var rotated = current
        rotated.accessToken = token.accessToken
        if let rotatedRefreshToken = token.refreshToken {
            rotated.refreshToken = rotatedRefreshToken
        }
        rotated.expiresAt = now().addingTimeInterval(token.expiresIn ?? configuration.defaultAccessTokenLifetime)
        if let tier = token.subscriptionType {
            rotated.subscriptionType = tier
        }
        if let scopes = token.scopes, scopes.isEmpty == false {
            rotated.scopes = scopes
        }
        return rotated
    }

    /// Writes the WHOLE blob in one ``SecretStore`` call, so no interruption can
    /// leave half a credential behind.
    func persistToOwnStore(_ credentials: OAuthCredentials) async throws {
        let data = try Self.encoder().encode(credentials)
        guard let blob = String(bytes: data, encoding: .utf8) else {
            throw SecretStoreError.malformedStoredValue(service: service, account: account)
        }
        try await store.set(blob, service: service, account: account)
    }

    /// Built per call rather than held in a `static let`: `JSONEncoder` is a
    /// non-`Sendable` class, so a shared static instance is a data race under
    /// Swift 6 strict concurrency.
    ///
    /// `.sortedKeys` makes the stored blob byte-stable, which is what lets a test
    /// assert on the persisted value directly. `.secondsSince1970` pins the date
    /// format as on-disk contract — the default `.deferredToDate` encodes a
    /// reference-date offset whose meaning is invisible in the stored JSON.
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
