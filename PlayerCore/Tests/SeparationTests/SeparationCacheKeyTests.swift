// Determinism contract for ``SeparationCacheKey`` — the key that decides whether a
// cached instrumental is reused. The invariant nine downstream todos rely on: the
// key is stable for identical inputs and changes when ANY component changes (path,
// size, mtime, or model SHA), so a stale instrumental is never served.
import Foundation
@testable import Separation
import Testing

@Suite("SeparationCacheKey")
struct SeparationCacheKeyTests {
    private static let path = "/music/song.flac"
    private static let size: Int64 = 1024
    private static let mtime: Double = 1_700_000_000
    private static let modelSHA = "abc123"

    private static func makeKey(
        path: String = SeparationCacheKeyTests.path,
        size: Int64 = SeparationCacheKeyTests.size,
        mtime: Double = SeparationCacheKeyTests.mtime,
        modelSHA: String = SeparationCacheKeyTests.modelSHA
    ) -> SeparationCacheKey {
        SeparationCacheKey(canonicalPath: path, fileSize: size, mtime: mtime, modelSHA: modelSHA)
    }

    @Test("same file identity + model SHA yields the same key")
    func deterministicForIdenticalInputs() {
        let first = Self.makeKey()
        let second = Self.makeKey()
        #expect(first == second)
        #expect(first.hexValue == second.hexValue)
    }

    @Test("a changed mtime yields a different key")
    func differsWhenMtimeChanges() {
        #expect(Self.makeKey() != Self.makeKey(mtime: Self.mtime + 1))
    }

    @Test("a changed model SHA yields a different key")
    func differsWhenModelSHAChanges() {
        #expect(Self.makeKey() != Self.makeKey(modelSHA: "def456"))
    }

    @Test("a changed file size yields a different key")
    func differsWhenFileSizeChanges() {
        #expect(Self.makeKey() != Self.makeKey(size: Self.size + 1))
    }

    @Test("a changed path yields a different key")
    func differsWhenPathChanges() {
        #expect(Self.makeKey() != Self.makeKey(path: "/music/other.flac"))
    }

    @Test("the key is a 64-character lowercase-hex SHA-256 digest")
    func hexIsSHA256Width() {
        let key = Self.makeKey()
        #expect(key.hexValue.count == 64)
        #expect(key.hexValue.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        #expect(key.description == key.hexValue)
    }

    @Test("the key is stable across independent constructions (hashable identity)")
    func hashableIdentityStable() {
        let keys: Set<SeparationCacheKey> = [Self.makeKey(), Self.makeKey()]
        #expect(keys.count == 1)
    }
}
