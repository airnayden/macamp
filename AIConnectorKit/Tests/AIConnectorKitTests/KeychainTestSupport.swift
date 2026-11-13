import Foundation
import Security

/// Runtime gate for the one test that touches the real login Keychain.
///
/// A `swift test` binary is not a signed, entitled app: depending on the machine
/// it may have no keychain access at all (headless CI, locked screen, sandboxed
/// runner). Rather than let that turn into a red build on someone else's Mac,
/// the gate performs a REAL add → read → delete round-trip once per process and
/// reports a verdict. `SecretStoreKeychainTests` enables its round-trip only
/// when the probe succeeded, and always records the reason when it did not.
///
/// The probe writes a generic password under a dedicated probe service with a
/// per-process random account, and deletes it again on every exit path — it can
/// never collide with, or leave behind, a real connector secret.
enum KeychainTestSupport {
    /// `errSecMissingEntitlement`. Spelled numerically because the plan names
    /// the number, and because this is the exact status an unentitled process
    /// gets when it asks for a keychain it may not use.
    static let missingEntitlement: OSStatus = -34018

    /// `errSecInteractionNotAllowed` — a locked keychain that cannot prompt.
    static let interactionNotAllowed: OSStatus = -25308

    struct Verdict {
        let isUsable: Bool
        let reason: String
    }

    /// Evaluated once, on first use, and reused for the rest of the run.
    static let verdict: Verdict = probeLoginKeychain()

    /// Whether the real-Keychain test may run.
    static var isUsable: Bool {
        verdict.isUsable
    }

    /// Why it may not — recorded in the evidence file when the test is skipped.
    static var skipReason: String {
        verdict.reason
    }

    private static func probeLoginKeychain() -> Verdict {
        let address: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.macamp.aiconnectors.keychain-probe",
            kSecAttrAccount as String: "probe-\(UUID().uuidString)",
        ]
        let expected = Data("probe".utf8)

        var addQuery = address
        addQuery[kSecValueData as String] = expected
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            return unusable(stage: "SecItemAdd", status: addStatus)
        }

        var readQuery = address
        readQuery[kSecReturnData as String] = true
        readQuery[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let readStatus = SecItemCopyMatching(readQuery as CFDictionary, &item)
        guard readStatus == errSecSuccess, item as? Data == expected else {
            _ = SecItemDelete(address as CFDictionary)
            return unusable(stage: "SecItemCopyMatching", status: readStatus)
        }

        let deleteStatus = SecItemDelete(address as CFDictionary)
        guard deleteStatus == errSecSuccess else {
            return unusable(stage: "SecItemDelete", status: deleteStatus)
        }
        return Verdict(isUsable: true, reason: "login Keychain add/read/delete probe succeeded")
    }

    private static func unusable(stage: String, status: OSStatus) -> Verdict {
        Verdict(
            isUsable: false,
            reason: "\(stage) returned OSStatus \(status)\(explanation(for: status)) — real-Keychain round-trip skipped"
        )
    }

    private static func explanation(for status: OSStatus) -> String {
        switch status {
        case missingEntitlement:
            " (errSecMissingEntitlement: unsigned or unentitled test binary)"
        case interactionNotAllowed:
            " (errSecInteractionNotAllowed: keychain locked, or no interactive login session)"
        default:
            ""
        }
    }
}
