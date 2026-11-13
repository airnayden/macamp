import AIConnectorKit
import Foundation

/// Build-wiring anchor for the subscription-credential target.
///
/// This target is linked into `macampMac` (macOS only, never iOS).
/// The exclusion is a LINK-time decision made in `iOS/Project.swift`, not a
/// compile flag: `#if` cannot reach into package code, so keeping these engines
/// out of the iOS binary requires them to live in a product that binary never
/// links. See `scripts/check-ios-oauth-linkage.sh`.
public enum ConnectorOAuthInfo {
    /// Keychain service namespace for subscription credentials.
    ///
    /// Derived from ``ConnectorKitInfo/keychainServicePrefix`` — referencing it is
    /// the compile-time proof that the `AIConnectorKit` edge links.
    public static let keychainService = ConnectorKitInfo.keychainServicePrefix + ".subscription"
}
