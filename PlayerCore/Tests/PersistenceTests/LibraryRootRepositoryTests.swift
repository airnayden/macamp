import Foundation
import GRDB
import Persistence
import Testing

/// An in-memory ``LegacyRootsImportFlagStore`` for the one-shot import tests. A class
/// (reference type) so the flag persists across calls within a test, mirroring how a
/// real `UserDefaults`-backed store behaves across launches.
private final class InMemoryLegacyRootsFlag: LegacyRootsImportFlagStore, @unchecked Sendable {
    private let lock = NSLock()
    private var imported = false

    var legacyRootsImported: Bool {
        lock.lock()
        defer { lock.unlock() }
        return imported
    }

    func markLegacyRootsImported() {
        lock.lock()
        defer { lock.unlock() }
        imported = true
    }
}

@Suite("LibraryRootRepositoryTests")
struct LibraryRootRepositoryTests {
    @Test("addRoot then rootsForProfile round-trips, ordered by path")
    func addAndFetch() throws {
        let appDB = try AppDatabase.makeEmpty()
        let repo = LibraryRootRepository(appDB)
        try repo.addRoot(profileId: ProfileRecord.guestID, path: "/music/rock")
        try repo.addRoot(profileId: ProfileRecord.guestID, path: "/music/jazz")
        let roots = try repo.rootsForProfile(ProfileRecord.guestID, limit: LibraryRootRepository.fetchLimit)
        #expect(roots.map(\.path) == ["/music/jazz", "/music/rock"])
    }

    @Test("rootsForProfile isolates roots by profile")
    func rootsScopedByProfile() throws {
        let appDB = try AppDatabase.makeEmpty()
        let profileRepo = ProfileRepository(appDB)
        let repo = LibraryRootRepository(appDB)
        let other = try profileRepo.create(ProfileRecord(name: "Ada"))
        let otherID = try #require(other.id)
        try repo.addRoot(profileId: ProfileRecord.guestID, path: "/guest")
        try repo.addRoot(profileId: otherID, path: "/ada")
        #expect(try repo.rootsForProfile(ProfileRecord.guestID, limit: 10).map(\.path) == ["/guest"])
        #expect(try repo.rootsForProfile(otherID, limit: 10).map(\.path) == ["/ada"])
    }

    @Test("removeRoot deletes exactly one root")
    func removeRoot() throws {
        let appDB = try AppDatabase.makeEmpty()
        let repo = LibraryRootRepository(appDB)
        let root = try repo.addRoot(profileId: ProfileRecord.guestID, path: "/music")
        let rootID = try #require(root.id)
        let removed = try repo.removeRoot(id: rootID)
        #expect(removed)
        #expect(try repo.rootsForProfile(ProfileRecord.guestID, limit: 10).isEmpty)
    }

    @Test("importLegacyRootsIfNeeded is one-shot — running twice yields no duplicates")
    func importOnceNoDupes() throws {
        let appDB = try AppDatabase.makeEmpty()
        let repo = LibraryRootRepository(appDB)
        let flag = InMemoryLegacyRootsFlag()
        try repo.importLegacyRootsIfNeeded(from: ["/a", "/b"], flagStore: flag)
        try repo.importLegacyRootsIfNeeded(from: ["/a", "/b"], flagStore: flag)
        let roots = try repo.rootsForProfile(ProfileRecord.guestID, limit: 100)
        #expect(roots.map(\.path) == ["/a", "/b"])
        #expect(flag.legacyRootsImported)
    }

    @Test("deleting all Guest roots then re-running import does not resurrect them")
    func noResurrectionAfterDelete() throws {
        let appDB = try AppDatabase.makeEmpty()
        let repo = LibraryRootRepository(appDB)
        let flag = InMemoryLegacyRootsFlag()
        try repo.importLegacyRootsIfNeeded(from: ["/a", "/b"], flagStore: flag)
        for root in try repo.rootsForProfile(ProfileRecord.guestID, limit: 100) {
            let rootID = try #require(root.id)
            try repo.removeRoot(id: rootID)
        }
        // The flag is still set → the import must NOT run again (no "Guest is empty"
        // heuristic that would resurrect the deleted roots).
        try repo.importLegacyRootsIfNeeded(from: ["/a", "/b"], flagStore: flag)
        #expect(try repo.rootsForProfile(ProfileRecord.guestID, limit: 100).isEmpty)
    }

    @Test("importLegacyRootsIfNeeded skips entirely when the flag is already set")
    func skipsWhenFlagSet() throws {
        let appDB = try AppDatabase.makeEmpty()
        let repo = LibraryRootRepository(appDB)
        let flag = InMemoryLegacyRootsFlag()
        flag.markLegacyRootsImported() // pretend a previous launch already imported
        try repo.importLegacyRootsIfNeeded(from: ["/a"], flagStore: flag)
        #expect(try repo.rootsForProfile(ProfileRecord.guestID, limit: 10).isEmpty)
    }

    @Test("importLegacyRootsIfNeeded marks the flag even with zero paths")
    func marksFlagWithEmptyPaths() throws {
        let appDB = try AppDatabase.makeEmpty()
        let repo = LibraryRootRepository(appDB)
        let flag = InMemoryLegacyRootsFlag()
        try repo.importLegacyRootsIfNeeded(from: [], flagStore: flag)
        #expect(flag.legacyRootsImported)
        #expect(try repo.rootsForProfile(ProfileRecord.guestID, limit: 10).isEmpty)
    }
}
