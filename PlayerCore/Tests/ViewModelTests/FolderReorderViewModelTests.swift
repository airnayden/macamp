// The folder drag-reorder seam the macOS library browser drives.
//
// The browser itself has no unit-test target, so its two decisions live in
// ``FolderReorderPolicy`` and its state mutation lives in
// ``FolderBrowserViewModel`` — both covered here. `renderInput` below mirrors the
// browser's render chain (`syncSourceTracks` -> `rows` -> `sortedRows`) exactly, so
// "the move shows up on screen" is asserted at the render INPUT, not merely inside
// the view model's array.
import Foundation
import GRDB
import Models
import Persistence
import Testing
@testable import ViewModels

@MainActor
@Suite("FolderReorderViewModelTests")
struct FolderReorderViewModelTests {
    private let root = "/Music/A"

    // MARK: - Fixtures

    @discardableResult
    private func seed(_ database: AppDatabase, count: Int) throws -> [Int64] {
        let repo = TrackRepository(database)
        // Titles descend while ids ascend, so a title-sorted table and the folder's
        // stored order can never coincide by accident.
        return try (0 ..< count).map { index in
            let inserted = try repo.insert(TrackRecord(
                filePath: "\(root)/\(index).flac",
                title: "T\(count - index)",
                sortTitle: "t\(count - index)"
            ))
            return inserted.id ?? 0
        }
    }

    /// Mirrors `LibraryBrowserView`'s render chain: the `@State sourceTracks`
    /// snapshot, mapped to rows, then the table comparator applied only where
    /// ``FolderReorderPolicy/appliesTableSort(filterRootPath:)`` allows it.
    private func renderInput(_ model: FolderBrowserViewModel, filterRootPath: String?) -> [Int64] {
        let sourceTracks = model.tracks
        guard FolderReorderPolicy.appliesTableSort(filterRootPath: filterRootPath) else {
            return sourceTracks.compactMap(\.id)
        }
        return sourceTracks
            .sorted { ($0.title ?? "") < ($1.title ?? "") }
            .compactMap(\.id)
    }

    private func makeModel(
        _ repository: any TrackRepositoryProviding,
        pageSize: Int = 100
    ) -> FolderBrowserViewModel {
        FolderBrowserViewModel(repository: repository, rootPath: root, pageSize: pageSize)
    }

    // MARK: - Cause 1 + 2: the move reaches the render input

    @Test("applyLocalOrder permutes the loaded window")
    func applyLocalOrderPermutesTheLoadedWindow() async throws {
        let database = try AppDatabase.makeEmpty()
        let ids = try seed(database, count: 5)
        let model = makeModel(TrackRepository(database))
        try await model.loadInitial()

        model.applyLocalOrder(ids.reversed())

        #expect(model.tracks.compactMap(\.id) == Array(ids.reversed()))
    }

    @Test("a folder move lands on the render input immediately — the table sort cannot undo it")
    func moveReachesTheRenderInputImmediately() async throws {
        let database = try AppDatabase.makeEmpty()
        let ids = try seed(database, count: 5)
        let model = makeModel(TrackRepository(database))
        try await model.loadInitial()
        #expect(renderInput(model, filterRootPath: root) == ids)

        model.moveTracks(from: IndexSet(integer: 2), to: 0, isEnabled: true)

        let expected = [ids[2], ids[0], ids[1], ids[3], ids[4]]
        #expect(model.tracks.compactMap(\.id) == expected)
        #expect(renderInput(model, filterRootPath: root) == expected)
        await model.awaitPendingOrderWrite()
    }

    @Test("the table comparator still orders every non-folder browse mode")
    func tableSortStillAppliesOutsideFolderMode() async throws {
        let database = try AppDatabase.makeEmpty()
        let ids = try seed(database, count: 4)
        let model = makeModel(TrackRepository(database))
        try await model.loadInitial()

        #expect(FolderReorderPolicy.appliesTableSort(filterRootPath: nil))
        #expect(!FolderReorderPolicy.appliesTableSort(filterRootPath: root))
        // Titles descend as ids ascend, so the comparator reverses the folder order.
        #expect(renderInput(model, filterRootPath: nil) == Array(ids.reversed()))
    }

    // MARK: - Cause 3: the keyset cursor follows the new order

    @Test("loadMore after a reorder continues from the moved row's NEW key")
    func loadMoreAfterAReorderHasNoDuplicatesOrSkips() async throws {
        let database = try AppDatabase.makeEmpty()
        let ids = try seed(database, count: 6)
        let model = makeModel(TrackRepository(database), pageSize: 3)
        try await model.loadInitial()
        #expect(model.tracks.count == 3)

        model.moveTracks(from: IndexSet(integer: 2), to: 0, isEnabled: true)
        await model.awaitPendingOrderWrite()
        try await model.loadMore()

        let loaded = model.tracks.compactMap(\.id)
        #expect(loaded.count == 6)
        #expect(Set(loaded).count == 6)
        #expect(Array(loaded.prefix(3)) == [ids[2], ids[0], ids[1]])
        #expect(Array(loaded.dropFirst(3)) == Array(ids.dropFirst(3)))
    }

    // MARK: - Cause 4: gating

    @Test("only folder mode with no genre chip may reorder")
    func reorderGateRejectsEveryOtherBrowseMode() {
        #expect(FolderReorderPolicy.allowsReorder(filterRootPath: root, isGenreFilterAll: true))
        #expect(!FolderReorderPolicy.allowsReorder(filterRootPath: root, isGenreFilterAll: false))
        #expect(!FolderReorderPolicy.allowsReorder(filterRootPath: nil, isGenreFilterAll: true))
        #expect(!FolderReorderPolicy.allowsReorder(filterRootPath: nil, isGenreFilterAll: false))
    }

    @Test("a Name or Date-added sort closes the gate manual order leaves open")
    func reorderGateClosesUnderEverySortedOrder() {
        let sorted = FolderSortKey.allCases.flatMap { key in
            [FolderSortDirection.ascending, .descending].map {
                FolderFilesSort.sorted(FolderSort(key: key, direction: $0))
            }
        }
        for filesSort in sorted {
            #expect(
                !FolderReorderPolicy.allowsReorder(
                    filterRootPath: root,
                    isGenreFilterAll: true,
                    filesSort: filesSort
                ),
                "\(filesSort.rawValue) left the reorder gate open"
            )
        }
        // Manual order keeps the original rule — and the 2-arg overload still means manual.
        #expect(FolderReorderPolicy.allowsReorder(filterRootPath: root, isGenreFilterAll: true, filesSort: .manual))
        #expect(!FolderReorderPolicy.allowsReorder(filterRootPath: root, isGenreFilterAll: false, filesSort: .manual))
        #expect(!FolderReorderPolicy.allowsReorder(filterRootPath: nil, isGenreFilterAll: true, filesSort: .manual))
        #expect(FolderReorderPolicy.allowsReorder(filterRootPath: root, isGenreFilterAll: true))
    }

    @Test("a genre-filtered drag writes NOTHING and leaves the window untouched")
    func genreFilteredDragWritesNothing() async throws {
        let database = try AppDatabase.makeEmpty()
        let ids = try seed(database, count: 5)
        let spy = FolderOrderSpyRepository(TrackRepository(database))
        let model = makeModel(spy)
        try await model.loadInitial()

        let isEnabled = FolderReorderPolicy.allowsReorder(filterRootPath: root, isGenreFilterAll: false)
        let moved = model.moveTracks(from: IndexSet(integer: 2), to: 0, isEnabled: isEnabled)

        #expect(moved == nil)
        #expect(model.tracks.compactMap(\.id) == ids)
        #expect(spy.folderOrderWrites.isEmpty)
        #expect(spy.customPositionWriteCount == 0)
    }

    @Test("an All-Tracks drag writes NOTHING")
    func allTracksDragWritesNothing() async throws {
        let database = try AppDatabase.makeEmpty()
        let ids = try seed(database, count: 5)
        let spy = FolderOrderSpyRepository(TrackRepository(database))
        let model = makeModel(spy)
        try await model.loadInitial()

        let isEnabled = FolderReorderPolicy.allowsReorder(filterRootPath: nil, isGenreFilterAll: true)
        let moved = model.moveTracks(from: IndexSet(integer: 4), to: 0, isEnabled: isEnabled)

        #expect(moved == nil)
        #expect(model.tracks.compactMap(\.id) == ids)
        #expect(spy.folderOrderWrites.isEmpty)
    }

    @Test("an enabled folder drag persists exactly one root-scoped order write")
    func enabledDragPersistsTheNewOrder() async throws {
        let database = try AppDatabase.makeEmpty()
        let ids = try seed(database, count: 5)
        let spy = FolderOrderSpyRepository(TrackRepository(database))
        let model = makeModel(spy)
        try await model.loadInitial()

        let moved = model.moveTracks(from: IndexSet(integer: 2), to: 0, isEnabled: true)
        await model.awaitPendingOrderWrite()

        let expected = [ids[2], ids[0], ids[1], ids[3], ids[4]]
        #expect(moved?.compactMap(\.id) == expected)
        #expect(spy.folderOrderWrites == [FolderOrderWrite(
            profileId: ProfileRecord.guestID,
            rootPath: root,
            orderedTrackIds: expected
        )])
        #expect(spy.customPositionWriteCount == 0)
    }

    @Test("the persisted order survives a fresh view model over the same database")
    func reorderSurvivesAFreshViewModel() async throws {
        let database = try AppDatabase.makeEmpty()
        let ids = try seed(database, count: 5)
        let model = makeModel(TrackRepository(database))
        try await model.loadInitial()
        model.moveTracks(from: IndexSet(integer: 4), to: 0, isEnabled: true)
        await model.awaitPendingOrderWrite()

        let reopened = makeModel(TrackRepository(database))
        try await reopened.loadInitial()

        #expect(reopened.tracks.compactMap(\.id) == [ids[4]] + Array(ids.dropLast()))
        #expect(renderInput(reopened, filterRootPath: root) == [ids[4]] + Array(ids.dropLast()))
    }
}
