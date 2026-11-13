import Foundation

/// The one way a connector's secret material reaches disk.
///
/// A secret is addressed by a `service` + `account` pair, mirroring the two
/// generic-password attributes the Keychain itself indexes on:
///
/// - `service` is the per-connector namespace, built by
///   ``ConnectorSecretService/name(forConnectorID:)`` — e.g.
///   `com.macamp.aiconnectors.anthropic`.
/// - `account` names the slot inside that namespace: `"apiKey"` for a plain
///   key, or a single blob slot for subscription OAuth (access + refresh +
///   expiry are persisted together, so a refresh rotation can never write half
///   a credential).
///
/// Values are `String` rather than `Data` because every consumer stores text —
/// an API key, or a JSON blob it encodes itself. The store never inspects,
/// logs, or transforms the value.
///
/// Every method is `async` so an actor (``InMemorySecretStore``) can witness the
/// protocol directly, and `throws` so a Keychain failure surfaces as a typed
/// ``SecretStoreError`` instead of a silently-empty read. A missing secret is
/// **not** an error: ``get(service:account:)`` returns `nil`. Callers that
/// require one use ``require(service:account:)``.
public protocol SecretStore: Sendable {
    /// Reads the secret at `service` + `account`, or `nil` when none is stored.
    func get(service: String, account: String) async throws -> String?

    /// Writes `value`, replacing any secret already stored at `service` + `account`.
    func set(_ value: String, service: String, account: String) async throws

    /// Removes the secret at `service` + `account`. Deleting a secret that does
    /// not exist succeeds — "gone" is the requested end state either way.
    func delete(service: String, account: String) async throws
}

public extension SecretStore {
    /// Reads a secret that must exist, throwing ``SecretStoreError/notFound(service:account:)``
    /// when it does not.
    ///
    /// This is the read for code paths that have already decided the connector
    /// is configured (a token refresh, an authenticated request). Using it
    /// instead of force-unwrapping ``get(service:account:)`` keeps "the user
    /// removed the key mid-session" on the error path rather than the crash path.
    func require(service: String, account: String) async throws -> String {
        guard let secret = try await get(service: service, account: account) else {
            throw SecretStoreError.notFound(service: service, account: account)
        }
        return secret
    }
}

/// Failures a ``SecretStore`` can report.
///
/// No case carries secret material — only the address of the secret and the
/// backend status code. `String(describing:)` of any value here is safe to log.
public enum SecretStoreError: Error, Equatable, Sendable {
    /// ``SecretStore/require(service:account:)`` found no secret at this address.
    case notFound(service: String, account: String)

    /// The stored bytes are not valid UTF-8, so they cannot be the string that
    /// was written. Treated as a hard failure rather than a lossy decode: a
    /// half-decoded API key would fail authentication in a far less obvious place.
    case malformedStoredValue(service: String, account: String)

    /// A `SecItem*` call failed with an unexpected status.
    case keychainFailure(operation: KeychainOperation, status: OSStatus)

    /// Which Keychain call failed. Named (not `Operation`) to avoid shadowing
    /// `Foundation.Operation` at use sites.
    public enum KeychainOperation: String, Equatable, Sendable {
        case read
        case write
        case delete
    }
}

/// Builds the Keychain service namespace shared by every connector.
///
/// Kept backend-neutral on purpose: tests inject ``InMemorySecretStore`` but
/// must address secrets with the exact same service names production uses, so
/// a namespace bug shows up in the fake run rather than only against the real
/// Keychain.
public enum ConnectorSecretService {
    /// `com.macamp.aiconnectors.<connector-id>`.
    ///
    /// The prefix has a single definition — ``ConnectorKitInfo/keychainServicePrefix`` —
    /// so a rename cannot orphan already-stored secrets in one place only.
    public static func name(forConnectorID connectorID: String) -> String {
        "\(ConnectorKitInfo.keychainServicePrefix).\(connectorID)"
    }
}
