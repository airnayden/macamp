// Ordering the main window's folder outline: Manual, Name, or Date added.
//
// The fixture is built so no two orderings coincide by accident — `dateAdded` is
// deliberately NOT monotone in the file names, so a test that asserted "sorted by
// date" while the code actually sorted by name would fail. The subfolder fixture
// carries one entry with NO date, which is the epic's single nil policy (last in
// BOTH directions) at the only place the in-memory comparator decides it.
import Foundation
import Models
import Persistence
import Testing
import ViewModels

@MainActor
@Suite("Folder outline — Name and Date-added ordering")
struct FolderOutlineSortTests {
    @Test("Subfolders follow the chosen sort, with an undated folder last either way")
    func subfoldersFollowEverySort() async {
        let byName = ["Alpha", "Bravo", "Charlie", "Sub"]
        let expectations: [(FolderFilesSort, [String])] = [
            (.manual, byName),
            (.sorted(FolderSort(key: .name, direction: .ascending)), byName),
            (.sorted(FolderSort(key: .name, direction: .descending)), byName.reversed()),
            (.sorted(FolderSort(key: .dateAdded, direction: .ascending)), ["Alpha", "Sub", "Bravo", "Charlie"]),
            (.sorted(FolderSort(key: .dateAdded, direction: .descending)), ["Bravo", "Sub", "Alpha", "Charlie"]),
        ]
        for (sort, expected) in expectations {
            let model = Self.makeModel(sort: sort)
            await model.load()
            #expect(model.rows.compactMap(\.folder).map(\.name) == expected, "\(sort.rawValue) ordered wrongly")
        }
    }

    @Test("Name descending pages through three pages with no gaps and no duplicates")
    func nameDescendingPagesCleanly() async {
        let repository = Self.repository()
        let model = Self.makeModel(
            repository: repository,
            pageSize: 2,
            sort: .sorted(FolderSort(key: .name, direction: .descending))
        )
        await model.load()

        let loaded = model.rootFileRows.map(\.trackId)
        #expect(Self.rootPageCount(repository) == 3)
        #expect(loaded == [6, 5, 4, 3, 2, 1])
        #expect(Set(loaded).count == loaded.count)
    }

    @Test("Date added ascending pages through three pages with no gaps and no duplicates")
    func dateAscendingPagesCleanly() async {
        let repository = Self.repository()
        let model = Self.makeModel(
            repository: repository,
            pageSize: 2,
            sort: .sorted(FolderSort(key: .dateAdded, direction: .ascending))
        )
        await model.load()

        let loaded = model.rootFileRows.map(\.trackId)
        #expect(Self.rootPageCount(repository) == 3)
        #expect(loaded == [2, 4, 1, 6, 3, 5])
        #expect(Set(loaded).count == loaded.count)
    }

    /// A sort change re-pages the FILES (their order is the query's) and re-sorts the
    /// SUBFOLDERS in memory (every loaded row already carries its `newestDateAdded`),
    /// so the aggregate query that produced those rows must not run a second time.
    @Test("Switching the sort re-pages the files once and re-sorts subfolders without a query")
    func switchingSortRePagesOnceAndKeepsSubfolders() async {
        let repository = Self.repository()
        let model = Self.makeModel(repository: repository, pageSize: 10)
        await model.load()
        #expect(Self.rootPageCount(repository) == 1)
        let childCallsAfterLoad = repository.childFolderCalls.count

        model.filesSort = .sorted(FolderSort(key: .name, direction: .descending))
        await model.awaitPendingSortReload()

        #expect(Self.rootPageCount(repository) == 2)
        #expect(repository.childFolderCalls.count == childCallsAfterLoad)
        #expect(model.rows.compactMap(\.folder).map(\.name) == ["Sub", "Charlie", "Bravo", "Alpha"])
        #expect(model.rootFileRows.map(\.trackId) == [6, 5, 4, 3, 2, 1])
    }

    @Test("Re-applying the same sort changes nothing and issues no query")
    func anIdenticalSortIsANoOp() async {
        let repository = Self.repository()
        let model = Self.makeModel(repository: repository, pageSize: 10)
        await model.load()

        model.filesSort = .manual
        await model.awaitPendingSortReload()

        #expect(Self.rootPageCount(repository) == 1)
    }

    @Test("Every file page is fetched under the outline's active sort")
    func everyPageCarriesTheActiveSort() async {
        let repository = Self.repository()
        let sort = FolderFilesSort.sorted(FolderSort(key: .dateAdded, direction: .descending))
        let model = Self.makeModel(repository: repository, pageSize: 2, sort: sort)
        await model.load()

        #expect(!repository.trackPageSorts.isEmpty)
        #expect(repository.trackPageSorts.allSatisfy { $0 == sort })
    }

    /// The failure this gate exists for: a drag while the list is query-ordered would
    /// persist positions the next page load discards.
    @Test("A sorted outline refuses every drag and writes nothing")
    func aSortedOutlineRefusesEveryDrag() async {
        let repository = Self.repository()
        let model = Self.makeModel(
            repository: repository,
            pageSize: 10,
            sort: .sorted(FolderSort(key: .name, direction: .descending))
        )
        await model.load()

        #expect(!model.canReorder(at: FolderOutlineFixture.root))
        let moved = model.moveRootFiles(from: IndexSet(integer: 2), to: 0, isEnabled: true)
        await model.awaitPendingOrderWrite()

        #expect(moved == nil)
        #expect(repository.orderWrites.isEmpty)
        #expect(model.rootFileRows.map(\.trackId) == [6, 5, 4, 3, 2, 1])
    }

    @Test("Returning to manual order re-opens the drag gate")
    func manualOrderReopensTheGate() async {
        let repository = Self.repository()
        let model = Self.makeModel(
            repository: repository,
            pageSize: 10,
            sort: .sorted(FolderSort(key: .name, direction: .descending))
        )
        await model.load()

        model.filesSort = .manual
        await model.awaitPendingSortReload()

        #expect(model.canReorder(at: FolderOutlineFixture.root))
        let moved = model.moveRootFiles(from: IndexSet(integer: 2), to: 0, isEnabled: true)
        await model.awaitPendingOrderWrite()

        #expect(moved?.compactMap(\.id) == [3, 1, 2, 4, 5, 6])
        #expect(repository.orderWrites.count == 1)
    }

    @Test("A nested level is never reorderable, whatever the sort")
    func nestedLevelsStayUnreorderable() async {
        let model = Self.makeModel()
        await model.load()
        await model.expand(FolderOutlineFixture.sub)

        #expect(!model.canReorder(at: FolderOutlineFixture.sub))
    }
}

// MARK: - Fixtures

extension FolderOutlineSortTests {
    static func makeModel(
        repository: FakeFolderOutlineRepository = OutlineSortFixtures.repository(),
        pageSize: Int = 10,
        sort: FolderFilesSort = .manual
    ) -> FolderOutlineViewModel {
        FolderOutlineViewModel(
            repository: repository,
            rootPath: FolderOutlineFixture.root,
            pageSize: pageSize,
            filesSort: sort
        )
    }

    static func repository() -> FakeFolderOutlineRepository {
        OutlineSortFixtures.repository()
    }

    static func rootPageCount(_ repository: FakeFolderOutlineRepository) -> Int {
        repository.trackPageCalls.count(where: { $0 == FolderOutlineFixture.root })
    }
}

/// Outside the `@MainActor` suite so the seeded values stay nonisolated — a fixture
/// a default argument evaluates must not require the main actor.
private enum OutlineSortFixtures {
    /// Dates that do NOT follow the alphabet, so name order and date order differ.
    static let fileDates: [Double] = [30, 10, 50, 20, 60, 40]

    static func repository() -> FakeFolderOutlineRepository {
        FakeFolderOutlineRepository(
            children: [
                FolderOutlineFixture.root: [
                    FolderOutlineFixture.child(
                        "\(FolderOutlineFixture.root)/Alpha",
                        name: "Alpha",
                        newestDateAdded: 100
                    ),
                    FolderOutlineFixture.child(
                        "\(FolderOutlineFixture.root)/Bravo",
                        name: "Bravo",
                        newestDateAdded: 300
                    ),
                    FolderOutlineFixture.child("\(FolderOutlineFixture.root)/Charlie", name: "Charlie"),
                    FolderOutlineFixture.child(FolderOutlineFixture.sub, name: "Sub", newestDateAdded: 200),
                ],
            ],
            files: [
                FolderOutlineFixture.root: zip(1 ... 6, fileDates).map { index, date in
                    FolderOutlineFixture.track(
                        id: Int64(index),
                        dir: FolderOutlineFixture.root,
                        name: String(UnicodeScalar(UInt8(96 + index))),
                        dateAdded: date
                    )
                },
                FolderOutlineFixture.sub: [
                    FolderOutlineFixture.track(id: 7, dir: FolderOutlineFixture.sub, name: "s"),
                ],
            ]
        )
    }
}
