// Query-level proof of the folder-tree reads: `childFolders`, `tracksDirectlyIn`
// and the root-scoped `searchTracks`.
//
// Every folder in the tree is derived from `track.filePath` — there is no folder
// table and no migration behind any of this — so these tests pin the three
// properties that derivation has to get right: the level split (immediate
// children vs direct files vs deeper nesting), `LIKE` metacharacter escaping
// (a folder literally named `100%hits_x` must not act as a wildcard), and
// profile visibility (another profile's root resolves to nothing).
import Foundation
import GRDB
import Persistence
import Testing

@Suite("FolderTreeQueryTests")
struct FolderTreeQueryTests {
    // MARK: - Fixtures

    private func titles(_ page: Page<TrackRecord, String>) -> [String] {
        page.items.compactMap(\.title)
    }

    // MARK: - Child folders

    @Test("childFolders returns the immediate subfolder with its recursive count")
    func childFoldersOfRoot() throws {
        let harness = try FolderTreeHarness()
        try harness.seedTree()

        let children = try harness.tracks.childFolders(parentPath: "/Music/Root")

        #expect(children == [
            FolderChildSummary(name: "Sub", path: "/Music/Root/Sub", trackCount: 2, hasChildren: true),
        ])
    }

    @Test("childFolders resolves the deeper level and reports a leaf folder")
    func childFoldersOfDeeperLevel() throws {
        let harness = try FolderTreeHarness()
        try harness.seedTree()

        let sub = try harness.tracks.childFolders(parentPath: "/Music/Root/Sub")

        #expect(sub == [
            FolderChildSummary(name: "Deep", path: "/Music/Root/Sub/Deep", trackCount: 1, hasChildren: false),
        ])
    }

    @Test("a trailing slash addresses the same folder")
    func trailingSlashAddressesTheSameFolder() throws {
        let harness = try FolderTreeHarness()
        try harness.seedTree()

        let withSlash = try harness.tracks.childFolders(parentPath: "/Music/Root/")
        let withoutSlash = try harness.tracks.childFolders(parentPath: "/Music/Root")

        #expect(withSlash == withoutSlash)
    }

    @Test("childFolders on a folder holding only files returns []")
    func childFoldersOfLeafFolderIsEmpty() throws {
        let harness = try FolderTreeHarness()
        try harness.seedTree()

        let children = try harness.tracks.childFolders(parentPath: "/Music/Root/Sub/Deep")

        #expect(children.isEmpty)
    }

    @Test("childFolders on a path no track lives under returns [] without throwing")
    func childFoldersOfNonexistentPathIsEmpty() throws {
        let harness = try FolderTreeHarness()
        try harness.seedTree()

        let children = try harness.tracks.childFolders(parentPath: "/Nowhere/At/All")

        #expect(children.isEmpty)
    }

    @Test("childFolders lists every sibling folder, ordered case-insensitively by name")
    func childFoldersListsSiblingsInNameOrder() throws {
        let harness = try FolderTreeHarness()
        try harness.seed(path: "/Music/zeta/1.mp3", title: "One")
        try harness.seed(path: "/Music/Alpha/2.mp3", title: "Two")
        try harness.seed(path: "/Music/mid/3.mp3", title: "Three")

        let children = try harness.tracks.childFolders(parentPath: "/Music")

        #expect(children.map(\.name) == ["Alpha", "mid", "zeta"])
    }

    // MARK: - Folder date added

    @Test("childFolders reports each subfolder's newest dateAdded")
    func childFoldersReportNewestDateAdded() throws {
        let harness = try FolderTreeHarness()
        try harness.seed(path: "/Music/Root/Older/1.mp3", title: "One", dateAdded: 100)
        try harness.seed(path: "/Music/Root/Older/Nested/2.mp3", title: "Two", dateAdded: 200)
        try harness.seed(path: "/Music/Root/Newer/3.mp3", title: "Three", dateAdded: 300)

        let children = try harness.tracks.childFolders(parentPath: "/Music/Root")

        #expect(children.map(\.name) == ["Newer", "Older"])
        #expect(children.first { $0.name == "Older" }?.newestDateAdded == 200)
        #expect(children.first { $0.name == "Newer" }?.newestDateAdded == 300)
    }

    @Test("a subfolder whose tracks carry no dateAdded reports nil, not zero")
    func childFoldersWithoutDatesReportNil() throws {
        let harness = try FolderTreeHarness()
        try harness.seed(path: "/Music/Root/Undated/1.mp3", title: "One")
        try harness.seed(path: "/Music/Root/Undated/2.mp3", title: "Two")

        let children = try harness.tracks.childFolders(parentPath: "/Music/Root")

        #expect(children.map(\.name) == ["Undated"])
        #expect(children[0].newestDateAdded == nil)
    }

    @Test("a partially dated subfolder reports the newest date it does have")
    func childFoldersIgnoreUndatedSiblings() throws {
        let harness = try FolderTreeHarness()
        try harness.seed(path: "/Music/Root/Mixed/1.mp3", title: "One")
        try harness.seed(path: "/Music/Root/Mixed/2.mp3", title: "Two", dateAdded: 100)

        let children = try harness.tracks.childFolders(parentPath: "/Music/Root")

        #expect(children[0].newestDateAdded == 100)
    }

    @Test("rootSummary reports the newest dateAdded across the whole root")
    func rootSummaryReportsNewestDateAdded() throws {
        let harness = try FolderTreeHarness()
        try harness.seed(path: "/Music/Root/a.mp3", title: "Alpha", dateAdded: 100)
        try harness.seed(path: "/Music/Root/Sub/b.mp3", title: "Bravo", dateAdded: 300)
        try harness.seed(path: "/Music/Root/Sub/Deep/c.mp3", title: "Charlie", dateAdded: 200)
        try harness.seed(path: "/Music/Second/d.mp3", title: "Delta", dateAdded: 900)

        let root = try harness.tracks.rootSummary(rootPath: "/Music/Root")
        let undated = try harness.tracks.rootSummary(rootPath: "/Music/Second/Nowhere")

        #expect(root.total == 3)
        #expect(root.newestDateAdded == 300)
        #expect(undated.newestDateAdded == nil)
    }

    // MARK: - Direct tracks

    @Test("tracksDirectlyIn returns only the files sitting in the folder itself")
    func tracksDirectlyInSkipsNestedFiles() throws {
        let harness = try FolderTreeHarness()
        try harness.seedTree()

        let root = try harness.tracks.tracksDirectlyIn(dirPath: "/Music/Root")
        let sub = try harness.tracks.tracksDirectlyIn(dirPath: "/Music/Root/Sub")
        let deep = try harness.tracks.tracksDirectlyIn(dirPath: "/Music/Root/Sub/Deep")

        #expect(titles(root) == ["Alpha"])
        #expect(titles(sub) == ["Bravo"])
        #expect(titles(deep) == ["Charlie"])
    }

    @Test("tracksDirectlyIn on a nonexistent path returns an empty page with no cursor")
    func tracksDirectlyInNonexistentPathIsEmptyPage() throws {
        let harness = try FolderTreeHarness()
        try harness.seedTree()

        let page = try harness.tracks.tracksDirectlyIn(dirPath: "/Nowhere/At/All")

        #expect(page.items.isEmpty)
        #expect(page.nextCursor == nil)
        #expect(!page.hasMore)
    }

    @Test("tracksDirectlyIn keyset pages cover every direct file exactly once")
    func tracksDirectlyInKeysetPagingIsExact() throws {
        let harness = try FolderTreeHarness()
        for index in 0 ..< 6 {
            try harness.seed(path: "/Music/Root/\(index).mp3", title: String(format: "Track %02d", index))
        }
        try harness.seed(path: "/Music/Root/Sub/nested.mp3", title: "Nested")

        var collected: [String] = []
        var cursor: PageCursor<String>?
        var pages = 0
        repeat {
            let page = try harness.tracks.tracksDirectlyIn(dirPath: "/Music/Root", after: cursor, limit: 2)
            collected.append(contentsOf: titles(page))
            cursor = page.nextCursor
            pages += 1
        } while cursor != nil && pages < 10

        #expect(collected == (0 ..< 6).map { String(format: "Track %02d", $0) })
        #expect(Set(collected).count == 6)
    }

    @Test("a root's stored folder order drives tracksDirectlyIn, unpositioned files trailing")
    func tracksDirectlyInHonoursStoredFolderOrder() throws {
        let harness = try FolderTreeHarness()
        let alpha = try harness.seed(path: "/Music/Root/a.mp3", title: "Alpha")
        let bravo = try harness.seed(path: "/Music/Root/b.mp3", title: "Bravo")
        try harness.seed(path: "/Music/Root/c.mp3", title: "Charlie")
        try harness.storeOrder(rootPath: "/Music/Root", [bravo, alpha])

        let page = try harness.tracks.tracksDirectlyIn(dirPath: "/Music/Root", limit: 100)

        #expect(titles(page) == ["Bravo", "Alpha", "Charlie"])
    }

    @Test("a folder with no stored order falls back to (sortTitle, id)")
    func tracksDirectlyInFallsBackToSortTitle() throws {
        let harness = try FolderTreeHarness()
        try harness.seed(path: "/Music/Root/z.mp3", title: "Zulu")
        try harness.seed(path: "/Music/Root/a.mp3", title: "Alpha")

        let page = try harness.tracks.tracksDirectlyIn(dirPath: "/Music/Root")

        #expect(titles(page) == ["Alpha", "Zulu"])
    }

    // MARK: - LIKE escaping

    @Test("a folder named 100%hits_x round-trips without matching lookalikes")
    func likeMetacharactersInAFolderNameAreEscaped() throws {
        let harness = try FolderTreeHarness()
        try harness.seed(path: "/Music/100%hits_x/real.mp3", title: "Real")
        try harness.seed(path: "/Music/100%hits_x/Nested/deep.mp3", title: "Deep")
        // Lookalikes an unescaped `%` / `_` pattern would swallow.
        try harness.seed(path: "/Music/100ZZZhitsQx/decoy.mp3", title: "Decoy")
        try harness.seed(path: "/Music/100hitsx/other.mp3", title: "Other")

        let direct = try harness.tracks.tracksDirectlyIn(dirPath: "/Music/100%hits_x")
        let children = try harness.tracks.childFolders(parentPath: "/Music/100%hits_x")
        let parentLevel = try harness.tracks.childFolders(parentPath: "/Music")

        #expect(titles(direct) == ["Real"])
        #expect(children == [
            FolderChildSummary(
                name: "Nested",
                path: "/Music/100%hits_x/Nested",
                trackCount: 1,
                hasChildren: false
            ),
        ])
        #expect(parentLevel.first { $0.name == "100%hits_x" }?.trackCount == 2)
        #expect(parentLevel.map(\.name).sorted() == ["100%hits_x", "100ZZZhitsQx", "100hitsx"].sorted())
    }

    // MARK: - Profile visibility

    @Test("a second profile sees nothing beneath another profile's root")
    func foreignRootIsInvisibleToASecondProfile() throws {
        let harness = try FolderTreeHarness()
        let alex = try harness.makeProfile(named: "Alex")
        try harness.roots.addRoot(profileId: ProfileRecord.guestID, path: "/Music/Root")
        try harness.roots.addRoot(profileId: alex, path: "/Music/Second")
        try harness.seedTree()

        let foreignChildren = try harness.tracks.childFolders(profileId: alex, parentPath: "/Music/Root")
        let foreignDirect = try harness.tracks.tracksDirectlyIn(profileId: alex, dirPath: "/Music/Root")
        let foreignSearch = try harness.tracks.searchTracks(
            profileId: alex,
            rootPath: "/Music/Root",
            query: "alpha"
        )
        // Guest owns /Music/Root and still sees all of it.
        let guestChildren = try harness.tracks.childFolders(parentPath: "/Music/Root")
        let guestDirect = try harness.tracks.tracksDirectlyIn(dirPath: "/Music/Root")

        #expect(foreignChildren.isEmpty)
        #expect(foreignDirect.items.isEmpty)
        #expect(foreignSearch.isEmpty)
        #expect(guestChildren.count == 1)
        #expect(titles(guestDirect) == ["Alpha"])
    }

    // MARK: - Root-scoped search

    @Test("searchTracks(rootPath:) matches only tracks beneath that root")
    func rootScopedSearchIsConfinedToTheSubtree() throws {
        let harness = try FolderTreeHarness()
        try harness.seed(path: "/Music/Root/one.mp3", title: "Bohemian Rhapsody")
        try harness.seed(path: "/Music/Root/Sub/two.mp3", title: "Bohemian Like You")
        try harness.seed(path: "/Music/Second/three.mp3", title: "Bohemian Elsewhere")

        let scoped = try harness.tracks.searchTracks(rootPath: "/Music/Root", query: "bohemian")

        #expect(Set(scoped.compactMap(\.title)) == ["Bohemian Rhapsody", "Bohemian Like You"])
    }

    @Test("root-scoped search honours the limit and returns [] for an unusable query")
    func rootScopedSearchIsBounded() throws {
        let harness = try FolderTreeHarness()
        for index in 0 ..< 5 {
            try harness.seed(path: "/Music/Root/\(index).mp3", title: "Bohemian \(index)")
        }

        let capped = try harness.tracks.searchTracks(rootPath: "/Music/Root", query: "bohemian", limit: 2)
        let blank = try harness.tracks.searchTracks(rootPath: "/Music/Root", query: "   ")

        #expect(capped.count == 2)
        #expect(blank.isEmpty)
    }
}
