// Unit tests for the pure ``CacheDirectoryOverlapPolicy`` — the shared overlap rules
// that keep the global karaoke instrumental cache from colliding with any profile's
// library roots (Task 11 karaoke composition rewiring).
import Foundation
import Models
import Testing

struct CacheDirectoryOverlapPolicyTests {
    private func dir(_ path: String) -> URL {
        URL(fileURLWithPath: path, isDirectory: true)
    }

    // MARK: overlap

    @Test func cacheInsideRootIsInsideRoot() {
        let root = dir("/Users/me/Music")
        let cache = dir("/Users/me/Music/Karaoke")
        let overlap = CacheDirectoryOverlapPolicy.overlap(cacheDirectory: cache, roots: [root])
        #expect(overlap == .insideRoot(root))
    }

    @Test func cacheEqualToRootIsInsideRoot() {
        let root = dir("/Users/me/Music")
        let overlap = CacheDirectoryOverlapPolicy.overlap(cacheDirectory: root, roots: [root])
        #expect(overlap == .insideRoot(root))
    }

    @Test func cacheContainingRootIsContainsRoot() {
        let cache = dir("/Users/me/Media")
        let root = dir("/Users/me/Media/Music")
        let overlap = CacheDirectoryOverlapPolicy.overlap(cacheDirectory: cache, roots: [root])
        #expect(overlap == .containsRoot(root))
    }

    @Test func disjointDirectoriesDoNotOverlap() {
        let root = dir("/Users/me/Music")
        let cache = dir("/Users/me/Library/Karaoke")
        #expect(CacheDirectoryOverlapPolicy.overlap(cacheDirectory: cache, roots: [root]) == nil)
    }

    @Test func siblingPrefixIsNotAnOverlap() {
        // "/Users/me/Music2" must NOT count as inside "/Users/me/Music" — the check is
        // anchored on a path separator, not a raw string prefix.
        let root = dir("/Users/me/Music")
        let cache = dir("/Users/me/Music2/Karaoke")
        #expect(CacheDirectoryOverlapPolicy.overlap(cacheDirectory: cache, roots: [root]) == nil)
    }

    // MARK: all-profiles (the security-critical case)

    @Test func rootFromNonActiveProfileStillOverlaps() {
        // The policy is a pure function over a FLAT root list, so the caller feeds
        // every profile's roots at once. Here the active profile's root is disjoint,
        // but an INACTIVE profile's root covers the cache directory — it must still be
        // reported, so the cache dir can never be dropped under a rival profile's root.
        let activeProfileRoot = dir("/Users/me/Music")
        let inactiveProfileRoot = dir("/Volumes/Shared/FamilyMusic")
        let cache = dir("/Volumes/Shared/FamilyMusic/Instrumentals")
        let overlap = CacheDirectoryOverlapPolicy.overlap(
            cacheDirectory: cache,
            roots: [activeProfileRoot, inactiveProfileRoot]
        )
        #expect(overlap == .insideRoot(inactiveProfileRoot))
    }

    @Test func emptyRootsNeverOverlap() {
        #expect(CacheDirectoryOverlapPolicy.overlap(cacheDirectory: dir("/tmp/cache"), roots: []) == nil)
    }

    // MARK: isSystemInternalLocation

    @Test func applicationSupportSubdirectoryIsSystemInternal() throws {
        let appSupport = try #require(
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        )
        let nested = appSupport.appendingPathComponent("MacAMP/Instrumentals", isDirectory: true)
        #expect(CacheDirectoryOverlapPolicy.isSystemInternalLocation(nested))
        #expect(CacheDirectoryOverlapPolicy.isSystemInternalLocation(appSupport))
    }

    @Test func ordinaryFolderIsNotSystemInternal() {
        #expect(!CacheDirectoryOverlapPolicy.isSystemInternalLocation(dir("/Users/me/Music/Karaoke")))
    }
}
