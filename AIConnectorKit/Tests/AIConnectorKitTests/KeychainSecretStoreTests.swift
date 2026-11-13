import AIConnectorKit
import Foundation
import Testing

/// The two OPTIONAL API keys the web-suggestions path may use — web search and
/// YouTube — addressed in the real login Keychain through the SHIPPED
/// ``KeychainSecretStore``.
///
/// There is no new store, no new namespace builder and no new file format here:
/// the whole point of the suite is that two more accounts need nothing but two
/// more `ConnectorSecretService` names. `SecretStoreKeychainTests` already runs
/// the full `SecretStore` contract against this backend; what is unproven until
/// here is that the specific service names those tools will ask for behave the
/// same way — including the case that matters most in practice, a listener who
/// never pastes a key at all.
///
/// Three rules keep a real-Keychain suite safe to run on a working machine:
///
/// 1. Gated on `KeychainTestSupport.isUsable`, like its sibling, so an unsigned
///    or headless run skips rather than fails.
/// 2. The round-trips address the REAL service names — a per-run namespace would
///    prove the plumbing but not the addresses — so each one first reads
///    whatever is there, and puts it back before returning. A listener with a
///    key configured keeps it.
/// 3. Every assertion is `#expect`, never `#require`, so a failed expectation
///    records and continues and the cleanup below it still runs.
///
/// The round-trips assert the VALUE that comes back, never merely that no error
/// was thrown: an entitlement-starved process that stores nothing and reads
/// nothing back would sail straight through a no-throw assertion.
@Suite("KeychainSecretStoreTests", .serialized)
struct KeychainSecretStoreTests {
    /// The slot inside each namespace — a plain key, so the connector-wide
    /// `"apiKey"` account rather than the OAuth blob slot.
    private static let account = "apiKey"

    private static let webSearchService = ConnectorSecretService.name(forConnectorID: "web_search")
    private static let youTubeService = ConnectorSecretService.name(forConnectorID: "youtube")

    private static let skipReason = "login Keychain unusable — see SecretStoreKeychainTests' probe verdict"

    // MARK: Addresses

    @Test("the optional web-suggestion keys live under the shipped connector namespaces")
    func theServiceNamesAreTheShippedOnes() {
        // Pinned by literal: these strings ARE where an already-stored key lives,
        // so a "tidier" connector id would orphan it rather than rename it.
        #expect(Self.webSearchService == "com.macamp.aiconnectors.web_search")
        #expect(Self.youTubeService == "com.macamp.aiconnectors.youtube")
    }

    // MARK: Never configured

    @Test(
        "an optional key that was never pasted reads nil instead of throwing",
        .enabled(if: KeychainTestSupport.isUsable, .init(rawValue: skipReason))
    )
    func aNeverWrittenKeyReadsNil() async throws {
        let store = KeychainSecretStore()

        // A per-run namespace under the same prefix: nothing has ever written
        // here, and a read leaves nothing behind either. This is the ordinary
        // state of both tools — keyless is the supported configuration, so
        // "absent" has to be a value, not an error path.
        for connectorID in ["web_search", "youtube"] {
            let service = ConnectorSecretService.name(forConnectorID: "\(connectorID)-unset-\(UUID().uuidString)")
            let stored = try await store.get(service: service, account: Self.account)
            #expect(stored == nil)
        }
    }

    // MARK: Round-trips

    @Test(
        "the web-search key round-trips and deletes under its real service name",
        .enabled(if: KeychainTestSupport.isUsable, .init(rawValue: skipReason))
    )
    func theWebSearchKeyRoundTrips() async throws {
        try await Self.roundTripAndDelete(service: Self.webSearchService)
    }

    @Test(
        "the YouTube key round-trips and deletes under its real service name",
        .enabled(if: KeychainTestSupport.isUsable, .init(rawValue: skipReason))
    )
    func theYouTubeKeyRoundTrips() async throws {
        try await Self.roundTripAndDelete(service: Self.youTubeService)
    }

    /// Write → read back the same value → delete → read `nil` → delete again,
    /// restoring any pre-existing key on the way out.
    private static func roundTripAndDelete(service: String) async throws {
        let store = KeychainSecretStore()

        // Whatever a real install has configured at this address is put back
        // below. Reading it first is also the only way this suite can be run
        // twice on a machine that uses MacAMP for real.
        let preexisting = try await store.get(service: service, account: account)

        let written = "sk-web-suggestions-\(UUID().uuidString)"
        try await store.set(written, service: service, account: account)

        let readBack = try await store.get(service: service, account: account)
        // The VALUE, not the absence of a throw — see the suite note.
        #expect(readBack == written)

        try await store.delete(service: service, account: account)
        let afterDelete = try await store.get(service: service, account: account)
        #expect(afterDelete == nil)

        // Idempotent: removing a key the listener never configured — or already
        // removed — is the requested end state either way, not a failure.
        try await store.delete(service: service, account: account)
        let afterSecondDelete = try await store.get(service: service, account: account)
        #expect(afterSecondDelete == nil)

        if let preexisting {
            try await store.set(preexisting, service: service, account: account)
        }
    }
}
