// AIConnectorSettingsProviding — the provider-ROUTING half of the AI preferences.
//
// `AISettingsProviding` (PlayerCore, `Services`) declares the seven on/off switches
// the Intelligence pane already owns, and this file deliberately does NOT widen it.
// Those seven are feature GATES that PlayerCore itself reads to decide whether an
// AI capability may run at all; everything below is provider ROUTING that only the
// connector stack cares about. Keeping them apart means PlayerCore never learns
// what a connector is, and a shell that ships no connector UI (iOS today) simply
// never conforms to this protocol.
//
// EVERYTHING DECLARED HERE IS NON-SECRET and is expected to land in `UserDefaults`.
// API keys, bearer tokens and OAuth refresh blobs live in the Keychain behind
// `SecretStore`, and no requirement may ever be added here that carries one — the
// macOS witness is pinned by a test asserting that no persisted key in the
// `…settings.ai.connector.*` namespace contains "key", "token" or "secret".
//
// `@MainActor` + `AnyObject` mirrors `AISettingsProviding`, for the same mechanical
// reason rather than as a style choice: the conformer is a
// `@MainActor @Observable public final class`, and under Swift 6 strict concurrency
// a main-actor-isolated stored property cannot witness a nonisolated requirement.
// `AnyObject` is what lets the `{ get set }` requirements be satisfied by a value
// held behind a `let` reference (the shell injects one shared settings instance).
//
// No imports: the surface is stdlib types only, so this file is as liftable as the
// core target even though it lives in the bridge.

/// Which connector answers assistant requests, which model it uses, and where a
/// local Ollama server lives.
///
/// The unconfigured state — `selectedConnectorID == nil` — is the shipped default
/// and means "Apple Intelligence", i.e. exactly the pre-connector behaviour with
/// zero network traffic. A connector is never selected implicitly.
@MainActor
public protocol AIConnectorSettingsProviding: AnyObject {
    /// The connector the assistant routes through, or `nil` for the built-in Apple
    /// Intelligence tier.
    ///
    /// This is a raw persisted string, NOT a validated selection: a connector that
    /// was configured by a newer build, or removed from the registry, still reads
    /// back verbatim. Resolve it through ``resolvedConnectorID(among:)`` before
    /// acting on it so an unknown id degrades to the Apple Intelligence default.
    var selectedConnectorID: String? { get set }

    /// The model `connectorID` last had selected, or `nil` when the user has not
    /// chosen one (the connector then picks its own default).
    ///
    /// Selections are kept PER CONNECTOR rather than as one global model name:
    /// connector model namespaces do not overlap, so switching provider and back
    /// must not silently hand a provider a model id it has never heard of.
    func selectedModel(for connectorID: String) -> String?

    /// Records `model` as `connectorID`'s selection; `nil` clears it.
    func setSelectedModel(_ model: String?, for connectorID: String)

    /// The Ollama server's base URL as the user typed it, or `nil` to use the
    /// connector's own default host.
    ///
    /// Stored as a plain `String?` rather than a `URL` so a half-typed host
    /// round-trips instead of being silently dropped; parsing and validation
    /// belong to the connector, which is the layer that can report a failure.
    var ollamaHost: String? { get set }
}

public extension AIConnectorSettingsProviding {
    /// ``selectedConnectorID`` resolved against the connectors actually registered,
    /// or `nil` when it names none of them.
    ///
    /// This is the one place "an unknown persisted connector id degrades to the
    /// Apple Intelligence default" is implemented, so the composition root never
    /// has to decide what an unrecognised id means. Storage stays lossless — the
    /// raw id is left untouched, so a connector that is temporarily unregistered
    /// (a link-gated OAuth build, a feature still loading) is re-selected as soon
    /// as it registers again.
    func resolvedConnectorID(among registered: some Collection<String>) -> String? {
        guard let selected = selectedConnectorID, registered.contains(selected) else { return nil }
        return selected
    }
}
