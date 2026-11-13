import AIConnectorKit
import Foundation
import Testing

/// The behaviours EVERY `SecretStore` implementation must exhibit.
///
/// Written once and run twice: unconditionally against `InMemorySecretStore`
/// (`SecretStoreContractTests`) and — when the login Keychain is reachable —
/// against the real `KeychainSecretStore` (`SecretStoreKeychainTests`). A future
/// backend proves itself by passing this same function, so the fake can never
/// quietly diverge from the store that actually holds users' API keys.
///
/// Two rules keep the shared run safe against the real Keychain:
///
/// 1. Every step deletes what it created, so a run leaves the keychain as it
///    found it.
/// 2. Every assertion is `#expect`, never `#require` — a failed expectation
///    records and continues, so the cleanup below it still executes.
enum SecretStoreContract {
    /// Runs every contract step against `store`, addressing secrets under
    /// `service` (and a sibling namespace derived from it).
    static func run(on store: some SecretStore, service: String) async throws {
        try await missingSecretReadsNil(store, service: service)
        try await setThenGetRoundTrips(store, service: service)
        try await overwriteReplacesTheStoredValue(store, service: service)
        try await deleteRemovesTheSecret(store, service: service)
        try await requireThrowsNotFoundOnceDeleted(store, service: service)
        try await deletingAnAbsentSecretSucceeds(store, service: service)
        try await accountsAreIsolated(store, service: service)
        try await servicesAreIsolated(store, service: service)
        try await nonASCIIAndLongValuesSurvive(store, service: service)
    }

    /// An unconfigured connector reads as `nil`, not as an error.
    private static func missingSecretReadsNil(_ store: some SecretStore, service: String) async throws {
        let stored = try await store.get(service: service, account: "never-written")
        #expect(stored == nil)
    }

    private static func setThenGetRoundTrips(_ store: some SecretStore, service: String) async throws {
        let account = "round-trip"
        try await store.set("sk-contract-round-trip", service: service, account: account)
        let stored = try await store.get(service: service, account: account)
        #expect(stored == "sk-contract-round-trip")
        try await store.delete(service: service, account: account)
    }

    /// Re-entering a key replaces the old one. A store that only ever *added*
    /// would keep authenticating with the key the user just replaced.
    private static func overwriteReplacesTheStoredValue(_ store: some SecretStore, service: String) async throws {
        let account = "overwrite"
        try await store.set("first-key", service: service, account: account)
        try await store.set("second-key", service: service, account: account)
        let stored = try await store.get(service: service, account: account)
        #expect(stored == "second-key")
        try await store.delete(service: service, account: account)
    }

    /// The failure mode this whole contract exists to rule out: a deleted
    /// secret must never be served again.
    private static func deleteRemovesTheSecret(_ store: some SecretStore, service: String) async throws {
        let account = "removed"
        try await store.set("sk-to-be-removed", service: service, account: account)
        try await store.delete(service: service, account: account)
        let stored = try await store.get(service: service, account: account)
        #expect(stored == nil, "delete-then-get must never serve a stale secret")
    }

    private static func requireThrowsNotFoundOnceDeleted(_ store: some SecretStore, service: String) async throws {
        let account = "required"
        try await store.set("sk-required", service: service, account: account)
        try await store.delete(service: service, account: account)
        let error = await #expect(throws: SecretStoreError.self) {
            _ = try await store.require(service: service, account: account)
        }
        #expect(error == .notFound(service: service, account: account))
    }

    /// "Remove" on a connector that was never configured is not an error — the
    /// requested end state (no secret) already holds.
    private static func deletingAnAbsentSecretSucceeds(_ store: some SecretStore, service: String) async throws {
        try await store.delete(service: service, account: "absent")
    }

    private static func accountsAreIsolated(_ store: some SecretStore, service: String) async throws {
        try await store.set("api-key-value", service: service, account: "apiKey")
        try await store.set("oauth-blob-value", service: service, account: "oauthBlob")

        let apiKey = try await store.get(service: service, account: "apiKey")
        let blob = try await store.get(service: service, account: "oauthBlob")
        #expect(apiKey == "api-key-value")
        #expect(blob == "oauth-blob-value")

        try await store.delete(service: service, account: "apiKey")
        let survivor = try await store.get(service: service, account: "oauthBlob")
        #expect(survivor == "oauth-blob-value", "deleting one account must not disturb its sibling")

        try await store.delete(service: service, account: "oauthBlob")
    }

    /// Two connectors share an account name (`apiKey`) and must not share a
    /// secret — the per-connector service namespace is what keeps them apart.
    private static func servicesAreIsolated(_ store: some SecretStore, service: String) async throws {
        let sibling = "\(service).sibling"
        try await store.set("primary-key", service: service, account: "apiKey")
        try await store.set("sibling-key", service: sibling, account: "apiKey")

        let primary = try await store.get(service: service, account: "apiKey")
        let siblingValue = try await store.get(service: sibling, account: "apiKey")
        #expect(primary == "primary-key")
        #expect(siblingValue == "sibling-key")

        try await store.delete(service: service, account: "apiKey")
        let survivor = try await store.get(service: sibling, account: "apiKey")
        #expect(survivor == "sibling-key", "deleting one service must not disturb another")

        try await store.delete(service: sibling, account: "apiKey")
    }

    /// Secrets cross a UTF-8 boundary in the Keychain backend, and an OAuth blob
    /// is JSON that can run to kilobytes. Both must survive byte-exact.
    private static func nonASCIIAndLongValuesSurvive(_ store: some SecretStore, service: String) async throws {
        let account = "blob"
        let value = #"{"accessToken":"\#(String(repeating: "abc123", count: 700))","note":"ключ • clé • 鍵"}"#
        try await store.set(value, service: service, account: account)
        let stored = try await store.get(service: service, account: account)
        #expect(stored == value)
        try await store.delete(service: service, account: account)
    }
}
