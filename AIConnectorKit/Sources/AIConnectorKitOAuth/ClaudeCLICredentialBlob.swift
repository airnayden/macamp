// ClaudeCLICredentialBlob — reading and PATCHING the Claude Code CLI's stored
// credential envelope without disturbing anything else inside it.
//
// ── TWO SHAPES, BOTH LIVE ─────────────────────────────────────────────────────
//
// The CLI has shipped two envelopes and both are in the wild:
//
//   wrapped  {"claudeAiOauth": {"accessToken": …, "refreshToken": …,
//                               "expiresAt": <epoch ms>, "subscriptionType": …,
//                               "scopes": […]}, …}
//   flat     {"accessToken": …, "refreshToken": …, "expiresAt": <epoch ms>,
//            "subscriptionType": …}
//
// Which one a given install uses is recorded in ``ExternalCredentialOrigin`` at
// read time and replayed at write time, because rewriting a flat blob as a
// wrapped one (or the reverse) logs the OWNING application out — the one outcome
// reuse must never produce.
//
// ── `expiresAt` IS MILLISECONDS ───────────────────────────────────────────────
//
// A JavaScript `Date.now()` value, not a POSIX second count. Reading it as
// seconds puts expiry ~55,000 years in the future, which would make every token
// look permanently fresh and turn the first 401 into a hard logout instead of a
// refresh. The conversion is therefore in exactly one place, here.
//
// ── MCP ENTRIES ARE NOT LOGINS ────────────────────────────────────────────────
//
// The same service-name family also stores per-MCP-server OAuth grants under an
// `mcpOAuth` key. Those authenticate a TOOL to a third-party server; they are not
// the listener's Claude session and carry no usable inference token. They are
// skipped by name rather than merely failing the access-token guard, so the rule
// is greppable and can be asserted directly.
//
// ── PATCHING IS FIELD-SCOPED ──────────────────────────────────────────────────
//
// A write-back replaces `accessToken`, `refreshToken` and `expiresAt` and nothing
// else. Every other key — including ones this app has never heard of, which a
// newer CLI is free to add — is carried through byte-for-byte in value terms.
import Foundation

/// Parses and patches the Claude Code CLI's credential JSON.
enum ClaudeCLICredentialBlob {
    /// The wrapper key of the nested envelope.
    static let wrapperKey = "claudeAiOauth"

    /// The key that marks a per-MCP-server grant rather than a user login.
    static let mcpKey = "mcpOAuth"

    static let accessTokenKey = "accessToken"
    static let refreshTokenKey = "refreshToken"
    static let expiresAtKey = "expiresAt"
    static let subscriptionTypeKey = "subscriptionType"
    static let scopesKey = "scopes"

    /// One decoded envelope, plus the shape a write-back must reproduce.
    struct Parsed: Equatable {
        var credentials: OAuthCredentials
        var isWrapped: Bool
    }

    /// The credential inside `data`, or `nil` when there is not a usable one.
    ///
    /// `nil` covers every "nothing to reuse here" case alike — not JSON, an MCP
    /// grant, a signed-out placeholder, a half-written file — because the caller
    /// treats them identically: move on to the next candidate.
    static func parse(_ data: Data) -> Parsed? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        guard isMCPOnly(root) == false else { return nil }

        let wrapped = root[wrapperKey] as? [String: Any]
        let node = wrapped ?? root
        guard let accessToken = nonEmptyString(node[accessTokenKey]),
              let refreshToken = nonEmptyString(node[refreshTokenKey])
        else {
            return nil
        }
        return Parsed(
            credentials: OAuthCredentials(
                accessToken: accessToken,
                refreshToken: refreshToken,
                expiresAt: date(fromEpochMilliseconds: node[expiresAtKey]),
                subscriptionType: nonEmptyString(node[subscriptionTypeKey]),
                scopes: scopes(node[scopesKey])
            ),
            isWrapped: wrapped != nil
        )
    }

    /// Whether this envelope holds only per-MCP-server grants — see the header.
    static func isMCPOnly(_ root: [String: Any]) -> Bool {
        root[mcpKey] != nil && root[wrapperKey] == nil && nonEmptyString(root[accessTokenKey]) == nil
    }

    /// `original` with the three rotating fields replaced, in the SAME shape.
    ///
    /// - Returns: `nil` when `original` is not the shape `isWrapped` claims — a
    ///   write-back against a blob that changed underneath us is refused rather
    ///   than guessed, because guessing means overwriting another application's
    ///   credential with a structure it cannot read.
    static func patched(_ original: Data, with credentials: OAuthCredentials, isWrapped: Bool) -> Data? {
        guard var root = (try? JSONSerialization.jsonObject(with: original)) as? [String: Any] else { return nil }
        if isWrapped {
            guard var node = root[wrapperKey] as? [String: Any] else { return nil }
            apply(credentials, to: &node)
            root[wrapperKey] = node
        } else {
            guard root[wrapperKey] == nil else { return nil }
            apply(credentials, to: &root)
        }
        return try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    private static func apply(_ credentials: OAuthCredentials, to node: inout [String: Any]) {
        node[accessTokenKey] = credentials.accessToken
        node[refreshTokenKey] = credentials.refreshToken
        node[expiresAtKey] = epochMilliseconds(credentials.expiresAt)
    }

    static func epochMilliseconds(_ date: Date) -> Int {
        Int((date.timeIntervalSince1970 * 1000).rounded())
    }

    /// An absent or unreadable expiry reads as the UNIX epoch — i.e. long expired
    /// — so the engine refreshes before first use instead of trusting a token
    /// whose lifetime nobody stated.
    private static func date(fromEpochMilliseconds value: Any?) -> Date {
        let milliseconds: Double
        if let number = value as? NSNumber {
            milliseconds = number.doubleValue
        } else if let text = value as? String, let parsed = Double(text) {
            milliseconds = parsed
        } else {
            return Date(timeIntervalSince1970: 0)
        }
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }

    private static func scopes(_ value: Any?) -> [String] {
        if let list = value as? [String] { return list.filter { $0.isEmpty == false } }
        if let text = value as? String {
            return text.split(separator: " ").map(String.init)
        }
        return []
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let text = value as? String, text.isEmpty == false else { return nil }
        return text
    }
}
