import Foundation
import Persistence
import Testing
@testable import ViewModels

/// Row composition, the per-level genre chip, and the root-only reorder gate.
///
/// A separate suite from `FolderOutlineViewModelTests` to stay inside SwiftLint's
/// `type_body_length`; both are matched by `swift test --filter FolderOutline`.
@MainActor
@Suite("Folder outline — rows, genre chip and reorder gate")
struct FolderOutlineRowsTests {
    /// Every level renders its subfolders first, then its own direct files — and the
    /// browsed root's files are the contiguous trailing block the shell reorders.
    @Test("Subfolders render before files at every level")
    func subfoldersPrecedeFiles() async {
        let model = FolderOutlineViewModel(repository: Self.repository(), rootPath: Self.root)
        await model.load()
        await model.expand(Self.sub)

        #expect(model.subtreeRows.first?.folder?.path == Self.sub)
        let subtreeFiles = model.subtreeRows.compactMap(\.file)
        #expect(subtreeFiles.allSatisfy { $0.levelPath == Self.sub })
        #expect(model.rootFileRows.allSatisfy { $0.levelPath == Self.root })
        #expect(model.rows.count == model.subtreeRows.count + model.rootFileRows.count)
    }

    /// The genre chip narrows the FILES of every rendered level, and leaves the
    /// subfolder rows alone (their counts are recursive aggregates).
    @Test("The genre chip narrows files at every rendered level")
    func genreChipNarrowsEveryLevel() async {
        let model = FolderOutlineViewModel(repository: Self.repository(), rootPath: Self.root)
        await model.load()
        await model.expand(Self.sub)

        model.genreFilter = .genre("Jazz")

        #expect(model.rootFileRows.compactMap(\.track.id) == [1])
        let subFiles = model.subtreeRows.compactMap(\.file)
        #expect(subFiles.compactMap(\.track.id) == [3])
        #expect(model.subtreeRows.compactMap(\.folder).map(\.path) == [Self.sub])
    }

    /// A genre with no loaded match at a level empties that level's files without
    /// disturbing the tree.
    @Test("A genre with no match empties a level's files")
    func genreWithNoMatchEmptiesLevel() async {
        let model = FolderOutlineViewModel(repository: Self.repository(), rootPath: Self.root)
        await model.load()

        model.genreFilter = .genre("Polka")

        #expect(model.rootFileRows.isEmpty)
        #expect(model.subtreeRows.compactMap(\.folder).map(\.path) == [Self.sub])
    }

    /// Reorder is a browsed-root affordance only, and only with the chip cleared.
    @Test("Reorder is allowed only at the browsed root")
    func reorderIsRootLevelOnly() async {
        let model = FolderOutlineViewModel(repository: Self.repository(), rootPath: Self.root)
        await model.load()

        #expect(model.canReorder(at: Self.root))
        #expect(!model.canReorder(at: Self.sub))

        model.genreFilter = .genre("Jazz")
        #expect(!model.canReorder(at: Self.root))
    }

    /// A disabled drag writes nothing; an enabled one permutes the window and
    /// persists the new order through `folderTrackOrder`.
    @Test("Only an enabled root drag writes a folder order")
    func rootDragPersistsOrder() async {
        let repo = Self.repository()
        let model = FolderOutlineViewModel(repository: repo, rootPath: Self.root)
        await model.load()

        #expect(model.moveRootFiles(from: IndexSet(integer: 1), to: 0, isEnabled: false) == nil)
        await model.awaitPendingOrderWrite()
        #expect(repo.orderWrites.isEmpty)

        let moved = model.moveRootFiles(from: IndexSet(integer: 1), to: 0, isEnabled: true) ?? []
        #expect(moved.compactMap(\.id) == [2, 1])
        await model.awaitPendingOrderWrite()
        #expect(repo.orderWrites == [
            FolderOrderWrite(profileId: 1, rootPath: Self.root, orderedTrackIds: [2, 1]),
        ])
        #expect(model.rootFileRows.compactMap(\.track.id) == [2, 1])
    }

    /// The reorder cursor is rebuilt from the SAME composed key the folder page
    /// query sorts on (`printf('%020d', position) || COALESCE(sortTitle, '')`), so
    /// the next page resumes where the permuted window ends.
    @Test("The post-reorder cursor matches the folder page's composed sort key")
    func orderKeyMatchesFolderPageKey() {
        #expect(FolderOutlineViewModel.orderKey(position: 7, sortTitle: "Alpha")
            == "00000000000000000007Alpha")
        #expect(FolderOutlineViewModel.orderKey(position: 0, sortTitle: nil)
            == "00000000000000000000")

        let files = [
            FolderOutlineFixture.track(id: 4, dir: Self.root, name: "A"),
            FolderOutlineFixture.track(id: 5, dir: Self.root, name: "B"),
        ]
        let cursor = FolderOutlineViewModel.orderCursor(forLoaded: files)
        #expect(cursor?.id == 5)
        #expect(cursor?.key == "00000000000000000001B")
        #expect(FolderOutlineViewModel.orderCursor(forLoaded: []) == nil)
    }
}

// MARK: - Fixtures

extension FolderOutlineRowsTests {
    static let root = FolderOutlineFixture.root
    static let sub = FolderOutlineFixture.sub

    static func repository() -> FakeFolderOutlineRepository {
        FakeFolderOutlineRepository(
            children: [root: [FolderOutlineFixture.child(sub, name: "Sub", trackCount: 2)]],
            files: [
                root: [
                    FolderOutlineFixture.track(id: 1, dir: root, name: "A", genre: "Jazz"),
                    FolderOutlineFixture.track(id: 2, dir: root, name: "B", genre: "Rock"),
                ],
                sub: [
                    FolderOutlineFixture.track(id: 3, dir: sub, name: "C", genre: "Jazz"),
                    FolderOutlineFixture.track(id: 4, dir: sub, name: "D", genre: "Rock"),
                ],
            ]
        )
    }
}
