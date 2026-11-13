// MCPServerConfigStore — the single writer for an MCP server's configuration AND
// its credentials, so the two can never drift apart.
//
// ── WHY ONE TYPE OWNS BOTH HALVES ────────────────────────────────────────────
//
// The configuration lives in `UserDefaults` and the credentials live in the
// Keychain, and each half is meaningless alone: a descriptor without its token
// cannot connect, and a token whose descriptor is gone is an unreachable secret
// that no surface can ever offer to delete. Splitting the writes across two call
// sites is what makes that drift possible, so there is exactly one.
//
// Every mutation therefore settles BOTH stores before returning:
//
//   save    writes the descriptor, stores the supplied values, and deletes the
//           accounts the NEW configuration no longer declares (a renamed
//           environment variable must not leave its old token behind)
//   remove  deletes every account the server owned, drops the descriptor, and
//           revokes its consent — so re-adding the same server asks again
//
// ── NOTHING HERE IS LOGGED ───────────────────────────────────────────────────
//
// There is no logger in this file and there must never be one. `SecretStoreError`
// is safe to render (it carries an address and an `OSStatus`, never a value), but
// a well-meant "failed to store %@" at a call site is one interpolation away from
// putting a bearer token in the system log, where it is readable and archived.
import AIConnectorKit
import AIConnectorMCP
import Foundation

/// Adds, updates and removes the external MCP servers the assistant may call.
@MainActor
final class MCPServerConfigStore {
    private let settings: AppSettings
    private let secrets: any SecretStore

    init(settings: AppSettings, secrets: any SecretStore) {
        self.settings = settings
        self.secrets = secrets
    }

    /// Every configured server, in the order the listener arranged them.
    var servers: [MCPServerDescriptor] {
        settings.mcpServers
    }

    /// The servers that may actually be contacted — enabled AND consented.
    var usableServers: [MCPServerDescriptor] {
        servers.filter(\.isUsable)
    }

    func server(id serverID: UUID) -> MCPServerDescriptor? {
        servers.first { $0.id == serverID }
    }

    /// Adds `descriptor`, or replaces the stored server with the same id, and
    /// commits `secretValues` to the Keychain under that server's namespace.
    ///
    /// - Parameters:
    ///   - descriptor: The configuration to persist. Its ``isConsented`` is
    ///     ignored — consent is granted only through ``recordConsent(forServerID:)``.
    ///   - secretValues: Credential VALUES keyed by the account names the endpoint
    ///     declares. Accounts absent from the new configuration are purged.
    func save(_ descriptor: MCPServerDescriptor, secretValues: [String: String] = [:]) async throws {
        let previousAccounts = server(id: descriptor.id)?.secretAccountNames ?? []
        let reconciled = descriptor.reconciled(against: settings.mcpConsentedServerIDs)

        try await purge(
            accounts: Set(previousAccounts).subtracting(reconciled.secretAccountNames),
            forServerID: reconciled.id
        )
        for account in reconciled.secretAccountNames {
            guard let value = secretValues[account] else { continue }
            try await secrets.set(value, service: reconciled.secretService, account: account)
        }

        if let index = servers.firstIndex(where: { $0.id == reconciled.id }) {
            settings.mcpServers[index] = reconciled
        } else {
            settings.mcpServers.append(reconciled)
        }
    }

    /// Forgets a server completely: its credentials, its configuration, and its
    /// consent. Re-adding the same endpoint later raises the disclosure again.
    func remove(serverID: UUID) async throws {
        if let stored = server(id: serverID) {
            try await purge(accounts: Set(stored.secretAccountNames), forServerID: serverID)
        }
        settings.mcpServers.removeAll { $0.id == serverID }
        settings.revokeMCPConsent(forServerID: serverID)
    }

    func setEnabled(_ isEnabled: Bool, forServerID serverID: UUID) {
        guard let index = servers.firstIndex(where: { $0.id == serverID }) else { return }
        settings.mcpServers[index].isEnabled = isEnabled
    }

    func hasConsent(forServerID serverID: UUID) -> Bool {
        settings.hasMCPConsent(forServerID: serverID)
    }

    func recordConsent(forServerID serverID: UUID) {
        settings.recordMCPConsent(forServerID: serverID)
    }

    /// The stored value for one of `serverID`'s declared accounts, or `nil`.
    func secret(named account: String, forServerID serverID: UUID) async throws -> String? {
        try await secrets.get(service: MCPServerSecretService.name(forServerID: serverID), account: account)
    }

    /// Every credential `descriptor` declares, keyed by account name, for the code
    /// that builds its transport. Accounts with nothing stored are omitted rather
    /// than yielding an empty string, so a missing token reads as missing.
    func resolvedSecrets(for descriptor: MCPServerDescriptor) async throws -> [String: String] {
        var resolved: [String: String] = [:]
        for account in descriptor.secretAccountNames {
            guard let value = try await secrets.get(service: descriptor.secretService, account: account) else {
                continue
            }
            resolved[account] = value
        }
        return resolved
    }

    private func purge(accounts: Set<String>, forServerID serverID: UUID) async throws {
        let service = MCPServerSecretService.name(forServerID: serverID)
        for account in accounts {
            try await secrets.delete(service: service, account: account)
        }
    }
}
