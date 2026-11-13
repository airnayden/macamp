// Query-level proof of `hasSubfolders` — the existence probe a library root's
// disclosure chevron is drawn from.
//
// It answers the same question `childFolders` does, so the two must never
// disagree; what it must NOT do is pay for the child level. These tests pin the
// three properties the derivation has to get right, exactly as
// `FolderTreeQueryTests` pins them for the level reads: the level split (a
// subfolder counts, a direct file does not), `LIKE` metacharacter escaping, and
// profile visibility. The sargability gate lives in `FolderTreeQueryPlanTests`.
import Foundation
import GRDB
import Persistence
import Testing

@Suite("FolderSubfolderProbeTests")
struct FolderSubfolderProbeTests {
    @Test("a root holding a subfolder reports true")
    func nestedRootHasSubfolders() throws {
        let harness = try FolderTreeHarness()
        try harness.seedTree()

        let root = try harness.tracks.hasSubfolders(rootPath: "/Music/Root")
        let sub = try harness.tracks.hasSubfolders(rootPath: "/Music/Root/Sub")

        #expect(root)
        #expect(sub)
    }

    @Test("a root holding only files reports false")
    func directFilesOnlyRootHasNoSubfolders() throws {
        let harness = try FolderTreeHarness()
        try harness.seed(path: "/Music/Leaf/one.mp3", title: "One")
        try harness.seed(path: "/Music/Leaf/two.mp3", title: "Two")

        let nested = try harness.tracks.hasSubfolders(rootPath: "/Music/Leaf")

        #expect(!nested)
    }

    @Test("the deepest folder and a path no track lives under both report false")
    func leafAndNonexistentPathsHaveNoSubfolders() throws {
        let harness = try FolderTreeHarness()
        try harness.seedTree()

        let deep = try harness.tracks.hasSubfolders(rootPath: "/Music/Root/Sub/Deep")
        let nowhere = try harness.tracks.hasSubfolders(rootPath: "/Nowhere/At/All")

        #expect(!deep)
        #expect(!nowhere)
    }

    @Test("a trailing slash addresses the same folder")
    func trailingSlashAddressesTheSameFolder() throws {
        let harness = try FolderTreeHarness()
        try harness.seedTree()

        let withSlash = try harness.tracks.hasSubfolders(rootPath: "/Music/Root/")
        let withoutSlash = try harness.tracks.hasSubfolders(rootPath: "/Music/Root")

        #expect(withSlash == withoutSlash)
        #expect(withSlash)
    }

    @Test("the probe agrees with childFolders on every level of the fixture tree")
    func probeAgreesWithTheChildLevel() throws {
        let harness = try FolderTreeHarness()
        try harness.seedTree()

        for path in ["/Music/Root", "/Music/Root/Sub", "/Music/Root/Sub/Deep", "/Music/Second"] {
            let probed = try harness.tracks.hasSubfolders(rootPath: path)
            let level = try harness.tracks.childFolders(parentPath: path)
            #expect(probed == !level.isEmpty, "disagreed at \(path)")
        }
    }

    @Test("a folder named 100%hits_x is probed literally, not as a wildcard")
    func likeMetacharactersInAFolderNameAreEscaped() throws {
        let harness = try FolderTreeHarness()
        try harness.seed(path: "/Music/100%hits_x/real.mp3", title: "Real")
        // Lookalikes an unescaped `%` / `_` pattern would swallow. Both nest, so an
        // unescaped probe reports the literal (flat) folder as nesting as well.
        try harness.seed(path: "/Music/100ZZZhitsQx/Nested/decoy.mp3", title: "Decoy")
        try harness.seed(path: "/Music/100hitsx/Nested/other.mp3", title: "Other")

        let literal = try harness.tracks.hasSubfolders(rootPath: "/Music/100%hits_x")
        let parent = try harness.tracks.hasSubfolders(rootPath: "/Music")

        #expect(!literal)
        #expect(parent)
    }

    @Test("a folder named 100%hits_x still reports its own subfolder")
    func escapedFolderStillSeesItsOwnSubfolder() throws {
        let harness = try FolderTreeHarness()
        try harness.seed(path: "/Music/100%hits_x/Nested/deep.mp3", title: "Deep")

        let nested = try harness.tracks.hasSubfolders(rootPath: "/Music/100%hits_x")

        #expect(nested)
    }

    @Test("a second profile sees no subfolders beneath another profile's root")
    func foreignRootIsInvisibleToASecondProfile() throws {
        let harness = try FolderTreeHarness()
        let alex = try harness.makeProfile(named: "Alex")
        try harness.roots.addRoot(profileId: ProfileRecord.guestID, path: "/Music/Root")
        try harness.roots.addRoot(profileId: alex, path: "/Music/Second")
        try harness.seedTree()

        let foreign = try harness.tracks.hasSubfolders(profileId: alex, rootPath: "/Music/Root")
        let owned = try harness.tracks.hasSubfolders(profileId: ProfileRecord.guestID, rootPath: "/Music/Root")

        #expect(!foreign)
        #expect(owned)
    }
}
