import Foundation
import Security

/// The production ``SecretStore``: generic-password items in the user's login
/// Keychain, reached through `SecItemAdd` / `SecItemCopyMatching` /
/// `SecItemUpdate` / `SecItemDelete`.
///
/// **The queries below deliberately carry no data-protection-keychain flag.**
/// `macampMac` ships unsandboxed today, and asking for the iOS-style
/// data-protection keychain from an unentitled process fails the whole call with
/// `errSecMissingEntitlement (-34018)` — every read returns nothing and every
/// write is rejected, which reads exactly like "the user never configured a
/// key". The file-based login keychain is the correct store for this app, and
/// staying on it is a hard requirement, not a default. For the same reason the
/// queries set no accessibility attribute: that attribute only means something
/// to the store this type is avoiding.
///
/// The type is a stateless `struct` — the Keychain itself is the state — so it
/// is trivially `Sendable` and can be shared across connectors.
///
/// `SecItem*` calls are synchronous; the `async` here comes from the protocol,
/// which exists so an actor can also witness it. Calls normally complete in well
/// under a millisecond, but the Keychain *can* block (a locked keychain prompts
/// the user), which is one reason connector call sites wrap their entire body —
/// secret read included — in a deadline.
public struct KeychainSecretStore: SecretStore {
    public init() {}

    public func get(service: String, account: String) async throws -> String? {
        var query = Self.address(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let secret = String(data: data, encoding: .utf8) else {
                throw SecretStoreError.malformedStoredValue(service: service, account: account)
            }
            return secret
        case errSecItemNotFound:
            return nil
        default:
            throw SecretStoreError.keychainFailure(operation: .read, status: status)
        }
    }

    public func set(_ value: String, service: String, account: String) async throws {
        let data = Data(value.utf8)
        let address = Self.address(service: service, account: account)

        // Update first, add second. The reverse order would have to treat
        // `errSecDuplicateItem` as the common case, and an add-only store would
        // silently keep serving the OLD key after the user pastes a new one.
        let updateStatus = SecItemUpdate(address as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw SecretStoreError.keychainFailure(operation: .write, status: updateStatus)
        }

        var addQuery = address
        addQuery[kSecValueData as String] = data
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw SecretStoreError.keychainFailure(operation: .write, status: addStatus)
        }
    }

    public func delete(service: String, account: String) async throws {
        let status = SecItemDelete(Self.address(service: service, account: account) as CFDictionary)
        // `errSecItemNotFound` is success: the caller asked for the secret to be
        // gone, and it is. Removing a connector that was never configured must
        // not surface an error.
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecretStoreError.keychainFailure(operation: .delete, status: status)
        }
    }

    /// The attributes that identify one secret — and nothing else.
    ///
    /// Every call builds its query from this base and adds only what that
    /// specific call needs (`kSecReturnData` for a read, `kSecValueData` for an
    /// add). Sharing one dictionary across calls is a known Keychain trap:
    /// `SecItemDelete` rejects a query that still carries return attributes.
    private static func address(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
