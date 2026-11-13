import Foundation

/// Build-wiring anchor for the reusable connector core.
///
/// The real contracts — `AIProviderConnector`, `AuthDescriptor`, `ModelInfo`,
/// `ConnectorFailure`, `JSONSchemaObject`, `HTTPTransport` and `withDeadline` —
/// land in the following todos. This enum exists so the target has a compilable
/// source from the moment the package is wired into the build, and so both CI
/// guards (`scripts/check-playercore-portability.sh`,
/// `scripts/check-hardcoded-strings.sh`) have something to scan.
///
/// This target may import Foundation, CryptoKit and Security ONLY. AppKit and
/// UIKit are a hard CI failure; PlayerCore imports belong in `AIConnectorBridge`.
public enum ConnectorKitInfo {
    /// Reverse-DNS prefix shared by every connector's Keychain service name.
    ///
    /// Per-connector services are formed as `"\(keychainServicePrefix).<connector-id>"`.
    public static let keychainServicePrefix = "com.macamp.aiconnectors"
}
