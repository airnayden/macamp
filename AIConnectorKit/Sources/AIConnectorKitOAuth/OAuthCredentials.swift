// OAuthCredentials — the FULL credential blob, and the leak-free failure vocabulary.
//
// ── WHY ONE BLOB AND NOT FOUR SECRETS ─────────────────────────────────────────
//
// Access token, refresh token, expiry and subscription tier are persisted as ONE
// JSON value in ONE ``SecretStore`` slot. Storing them separately would make a
// rotation a multi-write transaction against a store that offers no transaction:
// a process killed between the access-token write and the refresh-token write
// leaves a credential that authenticates once and can never be renewed, which
// presents to the listener as a random logout days later.
//
// The same reasoning forbids a PARTIAL seed. ``OAuthCredentialEngine``'s
// write-back is deliberately update-only — it patches the rotating fields into
// whatever is already stored — so seeding half a blob would make the first
// rotation silently drop the other half. This is the jarvis full-blob rationale
// (`orchestrator/src/llm/core/auth/oauth_login.ts`), ported.
//
// ── NOTHING HERE MAY REACH A LOG ──────────────────────────────────────────────
//
// ``OAuthCredentials`` carries two live secrets, so its `description`,
// `debugDescription` and `Mirror` are all overridden to redact them: the default
// synthesised behaviour prints every stored property, which would put a bearer
// token into any `print`, `os_log("\(creds)")` or `dump` a future caller writes.
// ``OAuthFlowError`` carries no secret material in ANY case — see the note there.
import AIConnectorKit
import Foundation

/// A complete, renewable subscription credential.
///
/// `Codable` because the whole value is the persisted blob. Field names are
/// stable on-disk contract: renaming one strands every already-signed-in
/// listener, so ``CodingKeys`` pins them explicitly rather than tracking the
/// Swift property names.
public struct OAuthCredentials: Codable, Sendable, Equatable {
    /// Bearer token for provider calls. Short-lived (8 hours, typically).
    public var accessToken: String

    /// Renews ``accessToken``. SINGLE-USE: the provider invalidates it the moment
    /// it issues a replacement, so whatever holds this value must persist the
    /// rotated one or the next refresh fails permanently.
    public var refreshToken: String

    /// When ``accessToken`` stops being accepted.
    public var expiresAt: Date

    /// Subscription tier when the provider disclosed one (`"max"`, `"pro"`).
    ///
    /// Optional because the token response does not reliably carry it. Absence is
    /// normal and must never fail a login — it only costs a nicer account label.
    public var subscriptionType: String?

    /// Scopes the credential was granted, in the order the provider echoed them.
    public var scopes: [String]

    public init(
        accessToken: String,
        refreshToken: String,
        expiresAt: Date,
        subscriptionType: String? = nil,
        scopes: [String] = []
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.subscriptionType = subscriptionType
        self.scopes = scopes
    }

    private enum CodingKeys: String, CodingKey {
        case accessToken
        case refreshToken
        case expiresAt
        case subscriptionType
        case scopes
    }

    /// True when the token has more than `buffer` of life left at `now`.
    ///
    /// The buffer absorbs clock skew and the latency of the request this token is
    /// about to authenticate: a token judged fresh with two seconds remaining
    /// expires mid-flight and costs a 401 round-trip.
    public func isFresh(at now: Date, buffer: TimeInterval) -> Bool {
        expiresAt.timeIntervalSince(now) > buffer
    }
}

extension OAuthCredentials: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// Redacted. Reports only non-secret facts: whether each token is present,
    /// when the credential expires, and the tier.
    public var description: String {
        let tier = subscriptionType ?? "unknown"
        return "OAuthCredentials(access: \(Self.presence(accessToken)), "
            + "refresh: \(Self.presence(refreshToken)), "
            + "expiresAt: \(expiresAt.timeIntervalSince1970), "
            + "subscriptionType: \(tier), scopes: \(scopes.count))"
    }

    public var debugDescription: String {
        description
    }

    /// Overrides what `dump(_:)` and `Mirror(reflecting:)` see.
    ///
    /// `CustomStringConvertible` alone does not cover reflection, and reflection
    /// is the other route by which a stored property reaches a console.
    public var customMirror: Mirror {
        Mirror(self, children: ["description": description], displayStyle: .struct)
    }

    private static func presence(_ token: String) -> String {
        token.isEmpty ? "absent" : "present"
    }
}

/// Everything that can go wrong inside the OAuth grant itself.
///
/// NO CASE CARRIES SECRET MATERIAL — not a token, not the PKCE verifier, not the
/// authorization code, and deliberately not the token endpoint's response body
/// either. That last exclusion is why this type exists instead of reusing
/// ``ConnectorFailure/httpStatus(_:body:)``: an OAuth error body routinely echoes
/// the code or the grant that was rejected, so a `body:` payload here would be a
/// credential leak with a plausible-looking justification. Only the status
/// survives, and `OAuthSecretLeakTests` pins that for every case.
///
/// Not `LocalizedError`, matching ``ConnectorFailure``: the kit ships no
/// user-visible copy. The shell maps a case to localized text.
public enum OAuthFlowError: Error, Sendable, Equatable, Hashable {
    /// The pasted callback value was not the expected `code#state` shape, or
    /// either half was empty.
    case malformedCallbackValue

    /// The `state` that came back does not match the one this attempt sent. The
    /// callback belongs to a different login — possibly someone else's. Refuse
    /// it and restart; never exchange a code that arrived with a foreign state.
    case stateMismatch

    /// The configured authorize endpoint could not be turned into a URL with the
    /// requested query. Signals a malformed ``OAuthEndpointConfiguration``, not a
    /// provider problem.
    case authorizeRequestUnbuildable

    /// The token endpoint answered with a non-2xx status.
    ///
    /// - Parameter status: The HTTP status, and nothing else.
    case tokenEndpointRejected(status: Int)

    /// The token endpoint answered 2xx with something that is not a JSON object.
    case tokenResponseUnreadable

    /// The response parsed but carried no `access_token`.
    case tokenResponseMissingAccessToken

    /// The response carried no `refresh_token` on an initial exchange.
    ///
    /// Fatal HERE and only here: an authorization-code grant always issues one,
    /// so its absence means a session that could never be renewed. On a REFRESH
    /// the same absence is benign — the engine keeps the token it already holds.
    case tokenResponseMissingRefreshToken

    /// ``OAuthCredentialEngine/seed(_:)`` was handed a blob missing a token.
    ///
    /// Refused rather than stored, because the engine's write-back is update-only:
    /// a partial seed is not a smaller credential, it is one whose first rotation
    /// silently drops whatever the seed omitted.
    case partialCredentialSeedRejected
}

/// One decoded token-endpoint response.
///
/// Internal: this type holds live secrets for the few statements between parsing
/// and persistence, and nothing outside this module should be able to hold one.
/// Its `description` is redacted for the same reason ``OAuthCredentials``' is.
struct OAuthTokenResponse {
    var accessToken: String
    var refreshToken: String?
    var expiresIn: TimeInterval?
    var scopes: [String]?
    var subscriptionType: String?

    /// Parses `data`, or throws the matching ``OAuthFlowError``.
    ///
    /// Hand-decoded through `JSONSerialization` rather than `Decodable` because
    /// the shape is loose in ways a synthesised decoder handles badly:
    /// `expires_in` arrives as a number or a numeric string depending on the
    /// host, `scope` is one space-separated string, and `subscription_type` sits
    /// at the root on some responses and nested under `account` on others. A
    /// throwing `Decodable` would collapse all of that into one
    /// `DataCorrupted` — and the whole point is to distinguish "not JSON" from
    /// "JSON without an access token".
    static func decode(_ data: Data) throws -> OAuthTokenResponse {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let json = object as? [String: Any]
        else {
            throw OAuthFlowError.tokenResponseUnreadable
        }
        guard let accessToken = json["access_token"] as? String, accessToken.isEmpty == false else {
            throw OAuthFlowError.tokenResponseMissingAccessToken
        }
        return OAuthTokenResponse(
            accessToken: accessToken,
            refreshToken: nonEmptyString(json["refresh_token"]),
            expiresIn: seconds(json["expires_in"]),
            scopes: nonEmptyString(json["scope"]).map { $0.split(separator: " ").map(String.init) },
            subscriptionType: subscriptionType(in: json)
        )
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let text = value as? String, text.isEmpty == false else { return nil }
        return text
    }

    private static func seconds(_ value: Any?) -> TimeInterval? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return TimeInterval(text) }
        return nil
    }

    /// Root first, then nested under `account` — both shapes are observed.
    private static func subscriptionType(in json: [String: Any]) -> String? {
        if let tier = nonEmptyString(json["subscription_type"]) { return tier }
        guard let account = json["account"] as? [String: Any] else { return nil }
        return nonEmptyString(account["subscription_type"])
    }
}

extension OAuthTokenResponse: CustomStringConvertible {
    var description: String {
        let refresh: String = refreshToken == nil ? "absent" : "present"
        let lifetime: String = expiresIn.map { "\($0)" } ?? "default"
        let scopeCount: Int = scopes?.count ?? 0
        return "OAuthTokenResponse(access: present, refresh: \(refresh), "
            + "expiresIn: \(lifetime), scopes: \(scopeCount))"
    }
}
