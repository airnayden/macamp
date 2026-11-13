// MCPServerConfigCoding — how the configured MCP servers become a defaults value,
// and the one thing the blob is never allowed to say.
//
// ── A CORRUPT BLOB IS AN EMPTY LIST, NEVER A TRAP ────────────────────────────
//
// `AppSettings` is built during launch, before any window exists, so a `try!` here
// would turn a hand-edited plist or a value written by an older build into a crash
// with nowhere to report it. Every decode failure resolves to `[]` — the same
// "degrade, never trap" rule the connector keys already follow, and the reason
// `AIConnectorSettingsTests` seeds each of those keys with a type it can never
// legitimately hold.
//
// ── THE BLOB CANNOT GRANT CONSENT ────────────────────────────────────────────
//
// ``MCPServerDescriptor/isConsented`` is encoded along with everything else — it
// is one `Codable` value type and carving a field out of the synthesized coding
// would be more machinery than the guarantee is worth. So the guarantee is made
// at the READ instead: ``decode(_:consentedIDs:)`` OVERWRITES the flag from the
// separate consent record on every load, and the encoded copy is inert.
//
// That matters because an MCP server can run programs on this Mac with the
// listener's full permissions (macampMac is not sandboxed). `UserDefaults` is
// writable by anything running as the user, so a blob claiming `isConsented: true`
// is exactly the input this file must not believe.
import AIConnectorMCP
import Foundation

/// Encodes and decodes the configured MCP servers for `UserDefaults`.
enum MCPServerConfigCoding {
    /// The defaults value for `servers`, or `nil` when it cannot be encoded.
    ///
    /// `nil` removes the key rather than leaving a stale list behind, which is the
    /// safer of the two failures: nothing configured beats something half-written.
    static func encode(_ servers: [MCPServerDescriptor]) -> Data? {
        try? JSONEncoder().encode(servers)
    }

    /// The configured servers, with consent taken from `consentedIDs` rather than
    /// from the blob. Any decode failure yields an empty list.
    static func decode(_ data: Data?, consentedIDs: Set<String>) -> [MCPServerDescriptor] {
        guard let data, let decoded = try? JSONDecoder().decode([MCPServerDescriptor].self, from: data) else {
            return []
        }
        return decoded.map { $0.reconciled(against: consentedIDs) }
    }
}

extension MCPServerDescriptor {
    /// This descriptor with ``isConsented`` set from the authoritative record.
    func reconciled(against consentedIDs: Set<String>) -> MCPServerDescriptor {
        var reconciled = self
        reconciled.isConsented = consentedIDs.contains(id.uuidString)
        return reconciled
    }
}

// MARK: - MCPServerConsentStoring

/// Records which external MCP servers the listener has accepted the trust
/// disclosure for.
///
/// A protocol for the reason ``LibraryBrowsingConsentStoring`` is one: the claim
/// under test is that an unconsented server is never contacted, and a negative
/// claim about writes cannot be checked from the end state alone.
@MainActor
protocol MCPServerConsentStoring: AnyObject {
    func hasMCPConsent(forServerID serverID: UUID) -> Bool
    func recordMCPConsent(forServerID serverID: UUID)
    func revokeMCPConsent(forServerID serverID: UUID)
}

extension AppSettings: MCPServerConsentStoring {
    func hasMCPConsent(forServerID serverID: UUID) -> Bool {
        mcpConsentedServerIDs.contains(serverID.uuidString)
    }

    func recordMCPConsent(forServerID serverID: UUID) {
        mcpConsentedServerIDs.insert(serverID.uuidString)
        reconcileMCPConsent()
    }

    func revokeMCPConsent(forServerID serverID: UUID) {
        mcpConsentedServerIDs.remove(serverID.uuidString)
        reconcileMCPConsent()
    }

    /// Re-projects the consent record onto the in-memory descriptors.
    ///
    /// Called after every consent change so ``MCPServerDescriptor/isUsable`` — the
    /// gate everything downstream reads — agrees with the record without anyone
    /// having to remember to set the flag by hand.
    func reconcileMCPConsent() {
        let consented = mcpConsentedServerIDs
        mcpServers = mcpServers.map { $0.reconciled(against: consented) }
    }
}
