// AuthDescriptor — how a connector proves who it is.
//
// ── THE CASE NAME `subscription` IS LOAD-BEARING ───────────────────────────────
//
// The consumer-sign-in case is spelled `subscription`, NEVER `oauth`. This type
// ships in the CORE target, which carries no OAuth logic whatsoever — yet Swift
// emits enum case names into binary reflection metadata even in Release, so an
// `oauth`-spelled case here would put the string "oauth" into any binary that
// links the core alone.
//
// The naming survived the retirement of the link gate that first demanded it
// (`scripts/check-oauth-linkage.sh`, removed when MacAMP dropped its second,
// App-Store-safe macOS target). It is kept because it is honest — `subscription`
// is what the case MEANS, and OAuth is one implementation of it — and because a
// consumer embedding this package may well reinstate such a gate.
import Foundation

/// How a connector proves who it is to its provider.
///
/// The descriptor is metadata ONLY: it tells the settings UI which credential
/// field to render and tells the registry whether an unconfigured connector is
/// worth probing. It never carries the credential itself — secrets live in the
/// Keychain behind `SecretStore`, never in a value type that can be logged.
public enum AuthDescriptor: Sendable, Equatable, Hashable {
    /// No credential at all — a self-hosted endpoint the listener runs themselves.
    ///
    /// - Parameter defaultHost: The endpoint offered before the listener overrides
    ///   it, e.g. Ollama's `http://127.0.0.1:11434`.
    case none(defaultHost: URL)

    /// A static secret sent in a request header.
    ///
    /// - Parameter header: The header field the secret goes in — `x-api-key` for
    ///   Anthropic, `Authorization` for OpenAI's bearer scheme. Named rather than
    ///   assumed because the two providers genuinely disagree.
    case apiKey(header: String)

    /// A credential minted by a consumer sign-in flow and refreshed over time.
    ///
    /// Only connectors from `AIConnectorKitOAuth` ever report this, and that
    /// product is linked exclusively by the non-App-Store build.
    case subscription

    /// Whether the listener must supply a secret before this connector can be used.
    ///
    /// `false` for ``none(defaultHost:)`` — a self-hosted endpoint is reachable the
    /// moment its host is set. The registry uses this to decide whether a connector
    /// with no stored secret is `unconfigured` or merely un-probed.
    public var requiresStoredSecret: Bool {
        switch self {
        case .none: false
        case .apiKey, .subscription: true
        }
    }
}
