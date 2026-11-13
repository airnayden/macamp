import Foundation
import Services

/// Build-wiring anchor for the MacAMP-specific half of the connector stack.
///
/// The canonical query schema, the payload-budgeted prompt builder and the
/// PlayerCore seam conformers land in the following todos. This enum exists so
/// the target has a compilable source while the build wiring is proven.
///
/// `AIConnectorBridge` is the ONLY kit target permitted to import PlayerCore —
/// keeping `AIConnectorKit` liftable into another app unchanged.
public enum ConnectorBridgeInfo {
    /// The PlayerCore seam a connector-backed parser has to satisfy.
    ///
    /// Naming it here is the compile-time proof that the
    /// `.product(name: "Services", package: "PlayerCore")` edge really links —
    /// the edge SwiftPM would silently spell `package: "macamp"` without the
    /// explicit dependency name in `Package.swift`.
    public typealias QueryParsingSeam = any NaturalLanguageQueryParsing
}
