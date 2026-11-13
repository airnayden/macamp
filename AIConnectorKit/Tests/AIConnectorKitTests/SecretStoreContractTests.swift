import AIConnectorKit
import Foundation
import Testing

/// The `SecretStore` contract, run against the in-memory witness.
///
/// This suite is the unconditional half of todo 3's coverage: it needs no
/// Keychain, no signed binary and no unlocked login session, so it runs
/// identically on a developer's Mac and on a headless CI runner. The real
/// Keychain gets the same contract in `SecretStoreKeychainTests`, gated on a
/// probe.
@Suite("SecretStoreContractTests")
struct SecretStoreContractTests {
    private static let service = ConnectorSecretService.name(forConnectorID: "contract-witness")

    @Test("The in-memory witness satisfies the full SecretStore contract")
    func inMemoryWitnessSatisfiesTheContract() async throws {
        try await SecretStoreContract.run(on: InMemorySecretStore(), service: Self.service)
    }

    @Test("A connector's service name is the reverse-DNS connector namespace")
    func serviceNameIsNamespaced() {
        #expect(ConnectorSecretService.name(forConnectorID: "ollama") == "com.macamp.aiconnectors.ollama")
        #expect(ConnectorSecretService.name(forConnectorID: "anthropic") == "com.macamp.aiconnectors.anthropic")
    }

    @Test("Reads, writes and deletes are counted so callers can assert when they happen")
    func callCountersTrackEachOperation() async throws {
        let store = InMemorySecretStore()
        try await store.set("sk-counted", service: Self.service, account: "apiKey")
        _ = try await store.get(service: Self.service, account: "apiKey")
        _ = try await store.get(service: Self.service, account: "apiKey")
        try await store.delete(service: Self.service, account: "apiKey")

        #expect(await store.writeCount == 1)
        #expect(await store.readCount == 2)
        #expect(await store.deleteCount == 1)
    }

    @Test("Resetting the counters keeps the stored secrets")
    func resetCountersLeavesStoredSecretsIntact() async throws {
        let store = InMemorySecretStore()
        try await store.set("sk-kept", service: Self.service, account: "apiKey")
        await store.resetCounters()

        #expect(await store.writeCount == 0)
        #expect(await store.storedSecretCount == 1)
        let stored = try await store.get(service: Self.service, account: "apiKey")
        #expect(stored == "sk-kept")
    }

    @Test("Deleting the last secret leaves the store empty")
    func deletingTheLastSecretEmptiesTheStore() async throws {
        let store = InMemorySecretStore()
        try await store.set("sk-only", service: Self.service, account: "apiKey")
        #expect(await store.storedSecretCount == 1)

        try await store.delete(service: Self.service, account: "apiKey")
        #expect(await store.storedSecretCount == 0)
    }

    /// Rule 4 of the plan's release gate: a secret must never reach a log, and
    /// an error description is a log by another name.
    @Test("A thrown SecretStoreError carries no secret material")
    func errorsNeverCarryTheSecret() async throws {
        let store = InMemorySecretStore()
        let secret = "sk-must-never-be-described"
        try await store.set(secret, service: Self.service, account: "apiKey")
        try await store.delete(service: Self.service, account: "apiKey")

        let error = await #expect(throws: SecretStoreError.self) {
            _ = try await store.require(service: Self.service, account: "apiKey")
        }
        let described = String(describing: error)
        #expect(!described.contains(secret))
        #expect(described.contains("notFound"))
    }
}
