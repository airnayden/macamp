// ProfilePIN — salted hashing and validation for the optional per-profile PIN.
//
// Profiles may carry an OPTIONAL 4–6 character PIN (letters + digits) that gates
// switching to, and editing, a profile. The PIN is stored ONLY as a salted
// SHA-256 hash (hex) plus its random salt on the profile row — the plaintext is
// never persisted, logged, or echoed anywhere.
//
// ## Threat model — soft child-proofing, NOT a security boundary
// This is deliberately light. The PIN keeps a sibling or child out of another
// household member's library; it is not encryption and protects nothing on disk.
// Consequently, by design and by scope decision:
//   * `verify(pin:hash:salt:)` uses a plain `==` comparison, NOT a constant-time
//     one. Timing side-channels are irrelevant to keeping a kid out of a music
//     app, and constant-time compare would add complexity for zero real benefit.
//   * There is NO lockout, retry cap, or backoff (that lives nowhere — it is out
//     of scope on purpose). Reviewers: do not "harden" this into a security
//     feature; that would contradict the product decision behind it.
//
// This file imports only Foundation + CryptoKit; it MUST NOT import AppKit or
// UIKit (PlayerCore portability invariant). CryptoKit is a portable system
// framework already used by the DesignSystem theming layer.
import CryptoKit
import Foundation

/// Salted PIN hashing/validation for profiles. A namespace of pure static
/// functions — there is no instance state and nothing to inject.
///
/// See the file header for the (intentionally soft) threat model: the digest is
/// salted SHA-256, comparison is NOT constant-time, and there is no lockout — all
/// deliberate for child-proofing rather than security.
public enum ProfilePIN {
    /// Length of a freshly generated salt, in bytes (128 bits).
    public static let saltByteCount = 16

    /// Inclusive minimum PIN length (interview-locked at 4).
    public static let minLength = 4
    /// Inclusive maximum PIN length (product spec: "up to 6 chars or numbers").
    public static let maxLength = 6

    // MARK: - Salt

    /// Returns ``saltByteCount`` cryptographically random bytes for a new PIN.
    ///
    /// `SystemRandomNumberGenerator` is documented as cryptographically secure on
    /// Apple platforms, so each byte is drawn from a CSPRNG.
    public static func makeSalt() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0 ..< saltByteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    // MARK: - Hash

    /// Hashes `pin` under `salt` as lowercase-hex SHA-256.
    ///
    /// The digest is computed over `salt` bytes FOLLOWED BY the UTF-8 bytes of
    /// `pin` (salt-prefixed), so the same PIN yields different hashes under
    /// different salts. The plaintext `pin` is never stored — only this hex string
    /// (alongside its salt) is persisted on the profile row.
    ///
    /// - Parameters:
    ///   - pin: The plaintext PIN. Callers should ``validate(_:)`` first; `hash`
    ///     itself is a pure function that hashes whatever it is given.
    ///   - salt: Random bytes from ``makeSalt()``.
    /// - Returns: A 64-character lowercase hex SHA-256 digest.
    public static func hash(pin: String, salt: Data) -> String {
        var input = salt
        input.append(Data(pin.utf8))
        return SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
    }

    /// Whether `pin` reproduces `hash` under `salt`.
    ///
    /// - Important: This is a plain equality comparison, NOT constant-time. That
    ///   is intentional — see the file header's threat model. Do not change it to
    ///   a constant-time compare; this is child-proofing, not a security boundary.
    public static func verify(pin: String, hash storedHash: String, salt: Data) -> Bool {
        hash(pin: pin, salt: salt) == storedHash
    }

    // MARK: - Validation

    /// Checks that `pin` is a well-formed PIN: 4–6 characters, every one a letter
    /// or digit (`CharacterSet.alphanumerics`). No symbols, spaces, or empties.
    ///
    /// Character validity is checked before length, so a PIN containing a symbol
    /// is always reported as ``ProfilePINError/invalidCharacters`` regardless of
    /// its length. Length is measured in grapheme clusters (`String.count`).
    ///
    /// - Returns: `.success` when valid, otherwise `.failure` with the specific
    ///   ``ProfilePINError`` the editor UI localizes per failure mode.
    public static func validate(_ pin: String) -> Result<Void, ProfilePINError> {
        let allowed = CharacterSet.alphanumerics
        guard pin.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return .failure(.invalidCharacters)
        }
        if pin.count < minLength {
            return .failure(.tooShort)
        }
        if pin.count > maxLength {
            return .failure(.tooLong)
        }
        return .success(())
    }
}

// MARK: - Error

/// A typed, `Sendable` reason a candidate PIN was rejected by
/// ``ProfilePIN/validate(_:)``.
///
/// The macOS profile editor (a later todo) maps each case to a localized inline
/// message, so the case set is a stable contract — mirror it when localizing.
public enum ProfilePINError: Error, Sendable, Equatable {
    /// Fewer than ``ProfilePIN/minLength`` characters (includes the empty string).
    case tooShort
    /// More than ``ProfilePIN/maxLength`` characters.
    case tooLong
    /// Contains a character that is neither a letter nor a digit.
    case invalidCharacters
}

// MARK: - Human-readable description

extension ProfilePINError: CustomStringConvertible {
    /// Developer-facing English text (for logs/tests). User-facing copy is
    /// localized in the shell keyed off the case — never taken from here.
    public var description: String {
        switch self {
        case .tooShort:
            "PIN is too short (must be \(ProfilePIN.minLength)–\(ProfilePIN.maxLength) characters)"
        case .tooLong:
            "PIN is too long (must be \(ProfilePIN.minLength)–\(ProfilePIN.maxLength) characters)"
        case .invalidCharacters:
            "PIN may contain only letters and digits"
        }
    }
}

extension ProfilePINError: LocalizedError {
    public var errorDescription: String? {
        description
    }
}
