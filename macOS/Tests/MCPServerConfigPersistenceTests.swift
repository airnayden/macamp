// MCPServerConfigPersistenceTests — the four claims that keep a configured MCP
// server safe to write down.
//
// Each is a property that would look correct in the Preferences pane while being
// wrong on disk:
//
//   1. A configuration that does not survive relaunch. The listener typed a URL
//      and an argument vector once; a blob that decodes to nothing loses it
//      silently, so the round trip is asserted through a SECOND `AppSettings`
//      built over the same suite rather than against the live object.
//   2. A stored consent. A server may run programs on this Mac, so consent must
//      default to false — and, more sharply, a JSON blob that CLAIMS consent must
//      not be believed. The blob is written by hand for exactly that case.
//   3. A secret that reached the plist. `UserDefaults` is world-readable to
//      anything running as the user and is swept into backups. The persisted
//      domain is therefore searched for the secret's own bytes, not merely for a
//      key that sounds like one.
//   4. A removal that leaves the Keychain behind. `InMemorySecretStore` counts
//      what it holds without being told the addresses, so "nothing left" can be
//      asserted the way the real Keychain would have to answer it.
//
// Plus the failure QA this todo names: a corrupted blob degrades to an empty list
// instead of trapping at launch.
import AIConnectorKit
import AIConnectorMCP
import Foundation
@testable import MacAMP
import Testing

@Suite("MCP server config persistence")
@MainActor
struct MCPServerConfigPersistenceTests {
    @Test("a configured server survives a relaunch, transport and all")
    func serversRoundTripThroughDefaults() async throws {
        let store = Self.store(named: "\(Self.suitePrefix).roundTrip")
        let settings = AppSettings(defaults: store)
        let config = MCPServerConfigStore(settings: settings, secrets: InMemorySecretStore())

        try await config.save(Self.stdioServer(named: "Alpha"))

        let reloaded = AppSettings(defaults: store)
        let server = try #require(reloaded.mcpServers.first)
        #expect(reloaded.mcpServers.count == 1)
        #expect(server.name == "Alpha")
        #expect(server.endpoint == .stdio(
            command: "npx",
            arguments: ["-y", "@example/mcp"],
            environmentKeys: ["EXAMPLE_API_KEY"]
        ))
    }

    @Test("consent is false until it is recorded, and a blob cannot claim it")
    func consentDefaultsToFalse() async throws {
        let name = "\(Self.suitePrefix).consent"
        let store = Self.store(named: name)
        let settings = AppSettings(defaults: store)
        let config = MCPServerConfigStore(settings: settings, secrets: InMemorySecretStore())
        let descriptor = Self.stdioServer(named: "Alpha", isEnabled: true)

        try await config.save(descriptor)
        #expect(settings.hasMCPConsent(forServerID: descriptor.id) == false)
        #expect(settings.mcpServers.first?.isConsented == false)
        #expect(settings.mcpServers.first?.isUsable == false)

        // A hand-edited plist claiming consent is the case worth catching: the
        // record is the authority, and the blob is never read as granting it.
        var forged = descriptor
        forged.isConsented = true
        try store.set(JSONEncoder().encode([forged]), forKey: Self.serversKey)

        let reloaded = AppSettings(defaults: store)
        #expect(reloaded.mcpServers.first?.isConsented == false)
        #expect(reloaded.mcpServers.first?.isUsable == false)
    }

    @Test("recorded consent survives a relaunch and makes an enabled server usable")
    func recordedConsentPersists() async throws {
        let store = Self.store(named: "\(Self.suitePrefix).consentGranted")
        let settings = AppSettings(defaults: store)
        let config = MCPServerConfigStore(settings: settings, secrets: InMemorySecretStore())
        let descriptor = Self.stdioServer(named: "Alpha", isEnabled: true)

        try await config.save(descriptor)
        config.recordConsent(forServerID: descriptor.id)

        #expect(settings.mcpServers.first?.isUsable == true)
        #expect(config.usableServers.map(\.id) == [descriptor.id])

        let reloaded = AppSettings(defaults: store)
        #expect(reloaded.hasMCPConsent(forServerID: descriptor.id))
        #expect(reloaded.mcpServers.first?.isConsented == true)
    }

    @Test("a secret reaches the store and never the persisted defaults")
    func secretsGoToTheSecretStoreNotTheBlob() async throws {
        let name = "\(Self.suitePrefix).secrets"
        let store = Self.store(named: name)
        let settings = AppSettings(defaults: store)
        let secrets = InMemorySecretStore()
        let config = MCPServerConfigStore(settings: settings, secrets: secrets)
        let descriptor = Self.stdioServer(named: "Alpha")

        try await config.save(descriptor, secretValues: ["EXAMPLE_API_KEY": Self.secretValue])

        let held = try await secrets.get(
            service: MCPServerSecretService.name(forServerID: descriptor.id),
            account: "EXAMPLE_API_KEY"
        )
        #expect(held == Self.secretValue)
        #expect(await secrets.storedSecretCount == 1)

        let rendered = Self.readablePersistedDomain(named: name)
        #expect(rendered.contains("EXAMPLE_API_KEY"), "the NAME is configuration and must persist")
        #expect(rendered.contains(Self.secretValue) == false, "the VALUE must never reach the plist")
    }

    @Test("removing a server purges every secret it owned")
    func removalPurgesSecrets() async throws {
        let store = Self.store(named: "\(Self.suitePrefix).removal")
        let settings = AppSettings(defaults: store)
        let secrets = InMemorySecretStore()
        let config = MCPServerConfigStore(settings: settings, secrets: secrets)
        let stdio = Self.stdioServer(named: "Alpha")
        let http = Self.httpServer(named: "Beta")

        try await config.save(stdio, secretValues: ["EXAMPLE_API_KEY": Self.secretValue])
        try await config.save(http, secretValues: ["Authorization": "Bearer \(Self.secretValue)"])
        config.recordConsent(forServerID: stdio.id)
        #expect(await secrets.storedSecretCount == 2)

        try await config.remove(serverID: stdio.id)

        #expect(settings.mcpServers.map(\.id) == [http.id])
        #expect(settings.hasMCPConsent(forServerID: stdio.id) == false)
        #expect(await secrets.storedSecretCount == 1)
        let orphan = try await secrets.get(
            service: MCPServerSecretService.name(forServerID: stdio.id),
            account: "EXAMPLE_API_KEY"
        )
        #expect(orphan == nil)
    }

    @Test("renaming a credential drops the entry the configuration no longer explains")
    func rewritingSecretKeysPurgesTheOldAccount() async throws {
        let store = Self.store(named: "\(Self.suitePrefix).rekey")
        let settings = AppSettings(defaults: store)
        let secrets = InMemorySecretStore()
        let config = MCPServerConfigStore(settings: settings, secrets: secrets)
        let descriptor = Self.stdioServer(named: "Alpha")

        try await config.save(descriptor, secretValues: ["EXAMPLE_API_KEY": Self.secretValue])

        var renamed = descriptor
        renamed.endpoint = .stdio(command: "npx", arguments: ["-y", "@example/mcp"], environmentKeys: ["EXAMPLE_TOKEN"])
        try await config.save(renamed, secretValues: ["EXAMPLE_TOKEN": Self.secretValue])

        #expect(settings.mcpServers.count == 1)
        #expect(await secrets.storedSecretCount == 1)
        let stale = try await secrets.get(
            service: MCPServerSecretService.name(forServerID: descriptor.id),
            account: "EXAMPLE_API_KEY"
        )
        #expect(stale == nil)
    }

    @Test("a corrupted blob degrades to an empty list instead of trapping")
    func corruptedBlobDegrades() {
        let name = "\(Self.suitePrefix).corrupt"
        let store = Self.store(named: name)
        store.set(Data("{ this is not a server list".utf8), forKey: Self.serversKey)

        #expect(AppSettings(defaults: store).mcpServers.isEmpty)

        store.set(["not", "even", "data"], forKey: Self.serversKey)
        #expect(AppSettings(defaults: store).mcpServers.isEmpty)

        store.set(42, forKey: Self.consentKey)
        #expect(AppSettings(defaults: store).mcpConsentedServerIDs.isEmpty)
    }

    // MARK: Helpers

    private static let suitePrefix = "com.example.macamp.tests.mcpServerConfig"
    private static let serversKey = AppSettingsKeys.mcpServers
    private static let consentKey = AppSettingsKeys.mcpConsentedServerIds
    private static let secretValue = "sk-not-a-real-token-0123456789"

    /// The persisted domain rendered as searchable text, with `Data` values DECODED.
    ///
    /// `String(describing:)` alone prints a `Data` as hex, which would make the
    /// "no secret reached the plist" assertion pass even if the secret were sitting
    /// in the blob — the plaintext simply would not appear in a hex dump. Decoding
    /// first is what makes the search mean what it claims.
    private static func readablePersistedDomain(named name: String) -> String {
        let domain = UserDefaults(suiteName: name)?.persistentDomain(forName: name) ?? [:]
        return domain
            .map { key, value in "\(key)=\(readable(value))" }
            .joined(separator: "\n")
    }

    private static func readable(_ value: Any) -> String {
        guard let data = value as? Data else { return String(describing: value) }
        return String(data: data, encoding: .utf8) ?? data.base64EncodedString()
    }

    private static func store(named name: String) -> UserDefaults {
        guard let store = UserDefaults(suiteName: name) else { return .standard }
        store.removePersistentDomain(forName: name)
        return store
    }

    private static func stdioServer(named name: String, isEnabled: Bool = false) -> MCPServerDescriptor {
        MCPServerDescriptor(
            name: name,
            endpoint: .stdio(
                command: "npx",
                arguments: ["-y", "@example/mcp"],
                environmentKeys: ["EXAMPLE_API_KEY"]
            ),
            isEnabled: isEnabled
        )
    }

    private static func httpServer(named name: String) -> MCPServerDescriptor {
        MCPServerDescriptor(
            name: name,
            // Force-unwrap-free: a literal that cannot fail still goes through the
            // failable initializer, so `.invalid` keeps the suite off the network.
            endpoint: .streamableHTTP(
                url: URL(string: "https://example.invalid/mcp") ?? URL(fileURLWithPath: "/"),
                headerKeys: ["Authorization"]
            )
        )
    }
}
