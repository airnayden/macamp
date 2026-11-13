import AIConnectorKit
import Foundation
import Testing

/// The `SecretStore` contract, run against the real login Keychain.
///
/// Gated on `KeychainTestSupport.isUsable` so an unsigned or headless run skips
/// instead of failing. The in-memory witness carries the same contract
/// unconditionally in `SecretStoreContractTests`, so skipping here never leaves
/// a behaviour unproven — only the `SecItem*` plumbing goes unexercised.
@Suite("SecretStoreKeychainTests")
struct SecretStoreKeychainTests {
    @Test("The login-Keychain probe records a verdict")
    func probeRecordsItsVerdict() {
        let verdict = KeychainTestSupport.verdict
        // The one deliberate `print` in this package. `swift test` streams it to
        // the run output, which is what the todo's evidence file captures — so a
        // skipped Keychain test always ships with a recorded reason rather than
        // a silent absence.
        print("[KeychainTestSupport] usable=\(verdict.isUsable) reason=\(verdict.reason)")
        #expect(!verdict.reason.isEmpty)
    }

    @Test(
        "The real Keychain satisfies the same SecretStore contract",
        .enabled(if: KeychainTestSupport.isUsable, "login Keychain unusable — see the probe verdict")
    )
    func keychainStoreSatisfiesTheContract() async throws {
        // A per-run service namespace: a repeat run, or a run alongside a real
        // MacAMP install, can never touch the other's items.
        let service = ConnectorSecretService.name(forConnectorID: "keychain-contract-\(UUID().uuidString)")
        let store = KeychainSecretStore()

        try await SecretStoreContract.run(on: store, service: service)

        // The contract deletes everything it writes, so nothing may remain. A
        // leftover here means a cleanup step regressed and the next run would
        // start dirty.
        let leftover = try await store.get(service: service, account: "apiKey")
        #expect(leftover == nil)
    }
}
