// ExternalCredentialSource — a credential that belongs to ANOTHER application,
// which this app may reuse without owning.
//
// ── WHY THIS IS A SEPARATE CONCEPT FROM `SecretStore` ─────────────────────────
//
// ``SecretStore`` addresses secrets MacAMP wrote and may freely overwrite or
// delete. An external credential is the opposite on every axis:
//
//   * WE DID NOT CREATE IT, so we must never delete it. Signing out of a reused
//     session stops us from consulting it; it does not destroy the other app's
//     login. (``OAuthCredentialEngine/signOut()`` enforces that.)
//   * ITS SHAPE IS THE OTHER APP'S CONTRACT, not ours. A rotated token must be
//     written back into the ORIGINAL envelope, patching only the fields that
//     rotated, so the owning application keeps working afterwards.
//   * IT LIVES SOMEWHERE WE ONLY PARTLY CONTROL — a Keychain item under a
//     foreign service name, or a file in another tool's dot-directory. Which of
//     those it was is what ``ExternalCredentialOrigin`` records, so the write-back
//     lands where the read came from.
//
// ── THE ORIGIN CARRIES NO SECRET ──────────────────────────────────────────────
//
// It is an ADDRESS, never a payload: a service name, an account name, a path, and
// the envelope shape. A write-back re-reads the original blob from that address
// rather than carrying it around, so no value type in this file can leak a token
// through `description`, `dump`, or a synthesized `Equatable` in a failing test.
import Foundation

/// Where a reused credential came from, precisely enough to write it back.
public struct ExternalCredentialOrigin: Sendable, Equatable, Hashable {
    /// Which kind of store the credential was read out of.
    public enum Kind: String, Sendable, Equatable, Hashable, CaseIterable {
        /// A macOS generic-password Keychain item owned by another application.
        case keychain
        /// A plain file in another application's configuration directory.
        case file
    }

    public var kind: Kind

    /// The Keychain SERVICE name, or the absolute FILE path. Never a secret.
    public var locator: String

    /// The Keychain ACCOUNT name. `nil` for a file origin, and `nil` for a
    /// Keychain item whose account could not be discovered — in which case a
    /// write-back is refused rather than guessed, because `add-generic-password`
    /// with the wrong account creates a SECOND item instead of updating the one
    /// the owning application reads.
    public var account: String?

    /// Whether the on-disk envelope nests the credential under a wrapper key.
    ///
    /// Recorded so the patched blob keeps the shape the owning application
    /// expects — see ``ClaudeCLICredentialBlob``.
    public var isWrapped: Bool

    public init(kind: Kind, locator: String, account: String? = nil, isWrapped: Bool) {
        self.kind = kind
        self.locator = locator
        self.account = account
        self.isWrapped = isWrapped
    }
}

/// One credential read out of an external source, with the address it came from.
///
/// Redacts on description for the same reason ``OAuthCredentials`` does: the
/// synthesized behaviour would print the tokens this value exists to carry.
public struct ExternalCredentialReading: Sendable, Equatable {
    public var credentials: OAuthCredentials
    public var origin: ExternalCredentialOrigin

    public init(credentials: OAuthCredentials, origin: ExternalCredentialOrigin) {
        self.credentials = credentials
        self.origin = origin
    }
}

extension ExternalCredentialReading: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "ExternalCredentialReading(credentials: \(credentials), origin: \(origin.kind.rawValue))"
    }

    public var debugDescription: String {
        description
    }

    public var customMirror: Mirror {
        Mirror(self, children: ["description": description], displayStyle: .struct)
    }
}

/// A credential another application owns and this one may reuse.
///
/// Both methods are deliberately NON-throwing. Discovery failures are normal —
/// the other tool may simply not be installed or signed in — and a write-back
/// failure must never break a refresh that already succeeded. Neither is
/// something the caller can act on differently, and this kit ships no logging, so
/// a thrown error would only be swallowed at the call site anyway.
public protocol ExternalCredentialSource: Sendable {
    /// The credential the other application currently holds, or `nil`.
    func load() async -> ExternalCredentialReading?

    /// Best-effort write-back of a ROTATED credential into `origin`, preserving
    /// the original envelope and patching only the fields that changed.
    ///
    /// - Returns: `true` when the owning application's copy was updated. `false`
    ///   is not an error — see ``OAuthCredentialEngine`` for what it does with a
    ///   refused write-back (it adopts the credential rather than losing it).
    @discardableResult
    func writeBack(_ credentials: OAuthCredentials, to origin: ExternalCredentialOrigin) async -> Bool
}
