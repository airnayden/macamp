import Foundation

/// A ``SecretStore`` that keeps everything in memory for the duration of the
/// process.
///
/// This is the witness the whole `SecretStore` contract suite runs against, and
/// the store every other test injects: it needs no Keychain, no signed binary
/// and no unlocked login session, so it behaves identically on a developer's
/// Mac and on a headless CI runner.
///
/// It ships in `Sources` rather than a test target because three separate test
/// targets (`AIConnectorKitTests`, `AIConnectorBridgeTests`,
/// `AIConnectorKitOAuthTests`) plus SwiftUI previews all need it, and a
/// `.testTarget` cannot export code to its siblings.
///
/// An `actor` rather than a locked class: the store is written from config
/// sheets on the main actor and read from connector tasks off it, and actor
/// isolation gives that for free without a lock the callers could forget.
///
/// The three counters exist for tests that assert *when* writes happen — for
/// example proving a commit-on-submit config sheet performs zero writes while
/// the user is still typing.
public actor InMemorySecretStore: SecretStore {
    private struct Address: Hashable {
        let service: String
        let account: String
    }

    private var secrets: [Address: String] = [:]

    /// Number of ``get(service:account:)`` calls since the last ``resetCounters()``.
    public private(set) var readCount = 0

    /// Number of ``set(_:service:account:)`` calls since the last ``resetCounters()``.
    public private(set) var writeCount = 0

    /// Number of ``delete(service:account:)`` calls since the last ``resetCounters()``.
    public private(set) var deleteCount = 0

    public init() {}

    public func get(service: String, account: String) async throws -> String? {
        readCount += 1
        return secrets[Address(service: service, account: account)]
    }

    public func set(_ value: String, service: String, account: String) async throws {
        writeCount += 1
        secrets[Address(service: service, account: account)] = value
    }

    public func delete(service: String, account: String) async throws {
        deleteCount += 1
        secrets[Address(service: service, account: account)] = nil
    }

    /// How many secrets are currently held, across every service.
    ///
    /// Lets a test prove a "Remove" action left nothing behind without knowing
    /// which addresses were used.
    public var storedSecretCount: Int {
        secrets.count
    }

    /// Zeroes the three call counters, leaving stored secrets untouched.
    ///
    /// Seed a fixture with ``set(_:service:account:)``, reset, then assert on
    /// the writes the code under test performs.
    public func resetCounters() {
        readCount = 0
        writeCount = 0
        deleteCount = 0
    }
}
