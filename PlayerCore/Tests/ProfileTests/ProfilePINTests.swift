import Foundation
import Services
import Testing

@Suite("ProfileTests")
struct ProfilePINTests {
    // Fixed salts so hashing assertions are reproducible run to run.
    private let saltA = Data(repeating: 0xAB, count: 16)
    private let saltB = Data(repeating: 0xCD, count: 16)

    // MARK: - Salt

    @Test("makeSalt returns 16 cryptographically random bytes")
    func makeSaltLength() {
        #expect(ProfilePIN.makeSalt().count == 16)
        #expect(ProfilePIN.saltByteCount == 16)
    }

    @Test("makeSalt is (overwhelmingly) unique per call")
    func makeSaltUniqueness() {
        // 128-bit salts colliding across 100 draws is astronomically unlikely;
        // a failure here means the RNG is broken, not flaky.
        let salts = (0 ..< 100).map { _ in ProfilePIN.makeSalt() }
        #expect(Set(salts).count == salts.count)
    }

    // MARK: - Hash

    @Test("hash is deterministic for the same pin and salt")
    func hashDeterministic() {
        let first = ProfilePIN.hash(pin: "1234", salt: saltA)
        let second = ProfilePIN.hash(pin: "1234", salt: saltA)
        #expect(first == second)
    }

    @Test("hash differs across salts for the same pin")
    func hashDiffersAcrossSalts() {
        let underA = ProfilePIN.hash(pin: "1234", salt: saltA)
        let underB = ProfilePIN.hash(pin: "1234", salt: saltB)
        #expect(underA != underB)
    }

    @Test("hash differs across pins for the same salt")
    func hashDiffersAcrossPins() {
        #expect(ProfilePIN.hash(pin: "1234", salt: saltA) != ProfilePIN.hash(pin: "abc123", salt: saltA))
    }

    @Test("hash is 64 lowercase-hex characters (SHA-256)")
    func hashHexShape() {
        let hex = ProfilePIN.hash(pin: "abc123", salt: saltA)
        #expect(hex.count == 64)
        #expect(hex.allSatisfy { "0123456789abcdef".contains($0) })
    }

    // MARK: - Verify

    @Test("verify succeeds for the correct pin")
    func verifyCorrect() {
        let stored = ProfilePIN.hash(pin: "1234", salt: saltA)
        #expect(ProfilePIN.verify(pin: "1234", hash: stored, salt: saltA))
    }

    @Test("verify fails for a wrong pin")
    func verifyWrong() {
        let stored = ProfilePIN.hash(pin: "1234", salt: saltA)
        #expect(!ProfilePIN.verify(pin: "9999", hash: stored, salt: saltA))
    }

    @Test("verify fails when the salt does not match")
    func verifyWrongSalt() {
        let stored = ProfilePIN.hash(pin: "1234", salt: saltA)
        #expect(!ProfilePIN.verify(pin: "1234", hash: stored, salt: saltB))
    }

    // MARK: - Validation

    @Test("validate rejects a 3-character pin as too short")
    func rejectsTooShort() {
        #expect(failureError(ProfilePIN.validate("abc")) == .tooShort)
    }

    @Test("validate rejects the empty pin as too short")
    func rejectsEmpty() {
        #expect(failureError(ProfilePIN.validate("")) == .tooShort)
    }

    @Test("validate rejects a 7-character pin as too long")
    func rejectsTooLong() {
        #expect(failureError(ProfilePIN.validate("abcdefg")) == .tooLong)
    }

    @Test("validate rejects symbols and spaces as invalid characters")
    func rejectsInvalidCharacters() {
        #expect(failureError(ProfilePIN.validate("12 4")) == .invalidCharacters)
        #expect(failureError(ProfilePIN.validate("ab!2")) == .invalidCharacters)
        #expect(failureError(ProfilePIN.validate("pa$$w")) == .invalidCharacters)
    }

    @Test("invalid characters take priority over a bad length")
    func invalidCharactersBeatLength() {
        // 8 chars AND a symbol -> the character rule fires first.
        #expect(failureError(ProfilePIN.validate("abcdefg!")) == .invalidCharacters)
    }

    @Test("validate accepts all-digit and mixed alphanumeric pins")
    func acceptsValid() {
        #expect(isSuccess(ProfilePIN.validate("1234")))
        #expect(isSuccess(ProfilePIN.validate("abc123")))
    }

    @Test("validate accepts the 4 and 6 character length boundaries")
    func acceptsLengthBoundaries() {
        #expect(isSuccess(ProfilePIN.validate("ab12"))) // 4 = min
        #expect(isSuccess(ProfilePIN.validate("abc456"))) // 6 = max
    }

    // MARK: - Helpers

    private func failureError(_ result: Result<Void, ProfilePINError>) -> ProfilePINError? {
        switch result {
        case .success: nil
        case let .failure(error): error
        }
    }

    private func isSuccess(_ result: Result<Void, ProfilePINError>) -> Bool {
        if case .success = result { return true }
        return false
    }
}
