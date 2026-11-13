import Persistence
import Testing
import ViewModels

/// Lazy level loading, per-level keyset pagination and the bounded root viewport
/// fill behind the main window's hierarchical folder browser.
@MainActor
@Suite("Folder outline — lazy levels and per-level pagination")
struct FolderOutlineViewModelTests {
    /// Expanding a subfolder queries its level once; collapsing keeps the level
    /// cached, so re-expanding costs no further query.
    @Test("Expanding a subfolder loads its children exactly once")
    func expandLoadsChildLevelOnce() async {
        let repo = Self.twoLevelRepository()
        let model = FolderOutlineViewModel(repository: repo, rootPath: FolderOutlineFixture.root)
        await model.load()

        await model.expand(FolderOutlineFixture.sub)
        await model.expand(FolderOutlineFixture.sub)
        model.collapse(FolderOutlineFixture.sub)
        await model.expand(FolderOutlineFixture.sub)

        let subLoads = repo.childFolderCalls.filter { $0 == FolderOutlineFixture.sub }
        #expect(subLoads.count == 1)
    }

    /// A nested level pages on its own cursor, independently of the browsed root.
    @Test("A nested level advances its own keyset window")
    func nestedLevelPaginatesIndependently() async {
        let repo = Self.pagingRepository()
        let model = FolderOutlineViewModel(
            repository: repo,
            rootPath: FolderOutlineFixture.root,
            pageSize: 2
        )
        await model.load()
        await model.expand(FolderOutlineFixture.sub)

        #expect(model.loadedFileCount(in: FolderOutlineFixture.sub) == 2)
        #expect(model.hasMoreFiles(in: FolderOutlineFixture.sub))

        await model.loadMoreFiles(in: FolderOutlineFixture.sub)
        #expect(model.loadedFileCount(in: FolderOutlineFixture.sub) == 4)

        await model.loadMoreFiles(in: FolderOutlineFixture.sub)
        #expect(model.loadedFileCount(in: FolderOutlineFixture.sub) == 5)
        #expect(!model.hasMoreFiles(in: FolderOutlineFixture.sub))
    }

    /// The threshold prefetch fires on the row's OWN level, never on another.
    @Test("A near-end file row prefetches its own level")
    func prefetchAdvancesOwningLevel() async throws {
        let repo = Self.pagingRepository()
        let model = FolderOutlineViewModel(
            repository: repo,
            rootPath: FolderOutlineFixture.root,
            pageSize: 2
        )
        await model.load()
        await model.expand(FolderOutlineFixture.sub)
        let rootCountBefore = model.loadedFileCount(in: FolderOutlineFixture.root)

        let subFiles = model.rows.compactMap(\.file).filter { $0.levelPath == FolderOutlineFixture.sub }
        let row = try #require(subFiles.first)
        await model.prefetchFilesIfNeeded(row)

        #expect(model.loadedFileCount(in: FolderOutlineFixture.sub) == 4)
        #expect(model.loadedFileCount(in: FolderOutlineFixture.root) == rootCountBefore)
    }

    /// The initial load tops the BROWSED ROOT up past one page; a nested level is
    /// deliberately left at its first page.
    @Test("The initial load fills the browsed root's viewport only")
    func loadFillsRootViewport() async {
        let repo = Self.pagingRepository()
        let model = FolderOutlineViewModel(
            repository: repo,
            rootPath: FolderOutlineFixture.root,
            pageSize: 2
        )
        await model.load()
        #expect(model.loadedFileCount(in: FolderOutlineFixture.root) == 5)

        await model.expand(FolderOutlineFixture.sub)
        #expect(model.loadedFileCount(in: FolderOutlineFixture.sub) == 2)
    }

    /// Expansion nests without a depth limit: three levels open inline.
    @Test("Expansion nests inline to any depth")
    func expansionNestsToAnyDepth() async {
        let repo = Self.threeLevelRepository()
        let model = FolderOutlineViewModel(repository: repo, rootPath: FolderOutlineFixture.root)
        await model.load()
        await model.expand(FolderOutlineFixture.sub)
        await model.expand(FolderOutlineFixture.deep)

        let folders = model.rows.compactMap(\.folder)
        #expect(folders.map(\.path) == [FolderOutlineFixture.sub, FolderOutlineFixture.deep])
        #expect(folders.map(\.depth) == [0, 1])

        let deepFile = model.rows.compactMap(\.file).first { $0.levelPath == FolderOutlineFixture.deep }
        #expect(deepFile?.depth == 2)
    }
}

// MARK: - Fixtures

extension FolderOutlineViewModelTests {
    static func twoLevelRepository() -> FakeFolderOutlineRepository {
        FakeFolderOutlineRepository(
            children: [
                FolderOutlineFixture.root: [
                    FolderOutlineFixture.child(FolderOutlineFixture.sub, name: "Sub", trackCount: 2),
                ],
            ],
            files: [
                FolderOutlineFixture.root: [
                    FolderOutlineFixture.track(id: 1, dir: FolderOutlineFixture.root, name: "A"),
                ],
                FolderOutlineFixture.sub: [
                    FolderOutlineFixture.track(id: 2, dir: FolderOutlineFixture.sub, name: "C"),
                ],
            ]
        )
    }

    static func pagingRepository() -> FakeFolderOutlineRepository {
        FakeFolderOutlineRepository(
            children: [
                FolderOutlineFixture.root: [
                    FolderOutlineFixture.child(FolderOutlineFixture.sub, name: "Sub", trackCount: 5),
                ],
            ],
            files: [
                FolderOutlineFixture.root: (1 ... 5).map {
                    FolderOutlineFixture.track(id: Int64($0), dir: FolderOutlineFixture.root, name: "R\($0)")
                },
                FolderOutlineFixture.sub: (6 ... 10).map {
                    FolderOutlineFixture.track(id: Int64($0), dir: FolderOutlineFixture.sub, name: "S\($0)")
                },
            ]
        )
    }

    static func threeLevelRepository() -> FakeFolderOutlineRepository {
        FakeFolderOutlineRepository(
            children: [
                FolderOutlineFixture.root: [
                    FolderOutlineFixture.child(
                        FolderOutlineFixture.sub,
                        name: "Sub",
                        trackCount: 2,
                        hasChildren: true
                    ),
                ],
                FolderOutlineFixture.sub: [
                    FolderOutlineFixture.child(FolderOutlineFixture.deep, name: "Deep", trackCount: 1),
                ],
            ],
            files: [
                FolderOutlineFixture.root: [
                    FolderOutlineFixture.track(id: 1, dir: FolderOutlineFixture.root, name: "A"),
                ],
                FolderOutlineFixture.sub: [
                    FolderOutlineFixture.track(id: 2, dir: FolderOutlineFixture.sub, name: "C"),
                ],
                FolderOutlineFixture.deep: [
                    FolderOutlineFixture.track(id: 3, dir: FolderOutlineFixture.deep, name: "D"),
                ],
            ]
        )
    }
}
