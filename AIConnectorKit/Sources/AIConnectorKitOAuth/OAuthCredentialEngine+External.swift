// OAuthCredentialEngine+External — reading and rotating a credential that belongs
// to another application.
//
// Split out of `OAuthCredentialEngine.swift` for one mechanical reason:
// `.swiftlint.yml` caps `type_body_length` at 250 and CI runs `--strict`, so the
// engine's main declaration cannot grow. An extension's members do not count
// toward that ceiling. The boundary is a real one either way — everything here is
// about the SECOND source, while the sibling file is about storing and rotating
// whatever source won.
//
// ── PRECEDENCE, AND WHY IT IS NOT A SETTING ───────────────────────────────────
//
// MacAMP's own blob ALWAYS wins. The external source is consulted only when this
// app holds nothing. Inverting that — or making it configurable — would let a
// stale borrowed session shadow a login the listener just performed here, and the
// symptom (a sign-in that appears to do nothing) is indistinguishable from a bug.
//
// ── A FAILED WRITE-BACK ADOPTS RATHER THAN LOSES ──────────────────────────────
//
// The refresh token is SINGLE-USE. Once a rotation succeeds, the token we
// presented is dead everywhere — including in the other application's copy. So a
// write-back that FAILS cannot simply be shrugged off: the rotated replacement
// would exist only in memory, and the next launch would read the other app's now-
// dead token and be permanently logged out. When the external write is refused,
// the rotated credential is therefore persisted into MacAMP's OWN store instead.
// From then on precedence makes this app the owner, which is the correct outcome:
// we hold the only live token.
//
// A SUCCESSFUL write-back deliberately does NOT also copy into our store. Doing so
// would flip precedence and make us stop noticing the other application's own
// rotations, turning a shared session into two diverging ones.
import AIConnectorKit
import Foundation

/// Which store a credential in hand came out of.
public enum CredentialOrigin: Sendable, Equatable {
    /// MacAMP's own ``SecretStore`` blob — written by an in-app sign-in.
    case app

    /// Another application's login, at the recorded address.
    case external(ExternalCredentialOrigin)

    /// Whether this credential is borrowed rather than owned.
    ///
    /// The shell renders a borrowed session differently and must not offer a
    /// sign-out that reads as "delete", so this is public API rather than an
    /// implementation detail.
    public var isExternal: Bool {
        if case .external = self { return true }
        return false
    }
}

/// A credential plus where it came from.
public struct StoredCredentialReading: Sendable, Equatable {
    public var credentials: OAuthCredentials
    public var origin: CredentialOrigin

    public init(credentials: OAuthCredentials, origin: CredentialOrigin) {
        self.credentials = credentials
        self.origin = origin
    }
}

extension StoredCredentialReading: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// Redacted — ``OAuthCredentials`` redacts itself, and a synthesized
    /// description here would be one refactor away from printing a token.
    public var description: String {
        "StoredCredentialReading(credentials: \(credentials), external: \(origin.isExternal))"
    }

    public var debugDescription: String {
        description
    }

    public var customMirror: Mirror {
        Mirror(self, children: ["description": description], displayStyle: .struct)
    }
}

public extension OAuthCredentialEngine {
    /// The credential in force, and which store it came from.
    ///
    /// - Throws: ``ConnectorFailure/authExpired`` when MacAMP's OWN blob exists but
    ///   cannot be decoded. An external source that cannot be read is `nil`
    ///   instead: the other application not being signed in is a normal state, not
    ///   a corruption this app can ask anyone to repair.
    func storedCredentialReading() async throws -> StoredCredentialReading? {
        if let blob = try await store.get(service: service, account: account) {
            guard let decoded = try? Self.decoder().decode(OAuthCredentials.self, from: Data(blob.utf8)) else {
                throw ConnectorFailure.authExpired
            }
            return StoredCredentialReading(credentials: decoded, origin: .app)
        }
        guard let reading = await externalReading() else { return nil }
        return StoredCredentialReading(credentials: reading.credentials, origin: .external(reading.origin))
    }
}

extension OAuthCredentialEngine {
    /// What the external source currently holds, or `nil` when there is no source,
    /// it was suppressed by ``signOut()``, or the other application is signed out.
    func externalReading() async -> ExternalCredentialReading? {
        guard isExternalSuppressed == false, let externalSource else { return nil }
        return await externalSource.load()
    }

    /// Routes a rotated credential to the store it came from — see this file's
    /// header for why a refused external write is adopted rather than dropped.
    func persist(_ credentials: OAuthCredentials, to origin: CredentialOrigin) async throws {
        switch origin {
        case .app:
            try await persistToOwnStore(credentials)
        case let .external(address):
            let written = await externalSource?.writeBack(credentials, to: address) ?? false
            guard written == false else { return }
            try await persistToOwnStore(credentials)
        }
    }
}
