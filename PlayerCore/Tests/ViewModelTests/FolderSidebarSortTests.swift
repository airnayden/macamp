// FolderSidebarSortTests — ordering the sidebar folder tree by name or date added.
//
// Four claims that would each look plausible while being wrong:
//
//   1. Only the roots sort. Every level has to obey the same order, so a loaded
//      child level is asserted under all four sorts alongside the roots.
//   2. A folder with no dated track sorts FIRST (or as epoch) under one direction.
//      The epic's single nil policy is LAST in BOTH directions, so both are asserted.
//   3. Changing the sort re-queries. `childrenCache` already holds every loaded
//      level, so a sort change must be pure in-memory work — locked by a call count
//      taken before and after.
//   4. The sort leaks into the filter. The breadth-first match walk collects into a
//      `Set`, so the MATCH SET must be identical under every sort even though the
//      rows are then laid out in sort order.
import Foundation
import Models
import Persistence
import Testing
import ViewModels

@MainActor
struct FolderSidebarSortTests {
    @Test("the roots order by each of the four sorts")
    func rootsFollowTheActiveSort() async {
        for (sort, expected) in SortFixture.rootExpectations {
            let model = SortFixture.makeModel()
            model.sort = sort
            await model.refresh(roots: SortFixture.rootURLs)

            #expect(model.nodes.map(\.name) == expected, "roots under \(sort.rawValue)")
            #expect(model.visibleNodes.map(\.name) == expected)
        }
    }

    @Test("a loaded child level orders by each of the four sorts")
    func childLevelFollowsTheActiveSort() async {
        for (sort, expected) in SortFixture.childExpectations {
            let model = SortFixture.makeModel()
            model.sort = sort
            await model.refresh(roots: SortFixture.rootURLs)
            await model.expand(SortFixture.alpha)

            #expect(model.children(of: SortFixture.alpha)?.map(\.name) == expected, "level under \(sort.rawValue)")
        }
    }

    /// A folder whose tracks carry no `dateAdded` is undatable, not oldest and not
    /// newest — reversing the direction must not move it off the tail.
    @Test("an undated folder sorts last ascending AND descending")
    func undatedFoldersSortLastInBothDirections() async {
        for direction in [FolderSortDirection.ascending, .descending] {
            let model = SortFixture.makeModel()
            model.sort = FolderSort(key: .dateAdded, direction: direction)
            await model.refresh(roots: SortFixture.rootURLs)
            await model.expand(SortFixture.alpha)

            #expect(model.nodes.last?.name == "Charlie", "undated root, \(direction.rawValue)")
            #expect(model.nodes.last?.newestDateAdded == nil)
            #expect(model.children(of: SortFixture.alpha)?.last?.name == "Zulu")
        }
    }

    @Test("changing the sort re-orders every loaded level without a second query")
    func resortingIssuesNoQuery() async {
        let repository = SortFixture.makeRepository()
        let model = SortFixture.makeModel(repository)
        await model.refresh(roots: SortFixture.rootURLs)
        await model.expand(SortFixture.alpha)
        let callsAfterLoad = repository.childFolderCalls.count
        #expect(repository.callCount(for: SortFixture.alpha) == 1)

        model.sort = FolderSort(key: .dateAdded, direction: .descending)

        #expect(repository.childFolderCalls.count == callsAfterLoad)
        #expect(repository.callCount(for: SortFixture.alpha) == 1)
        #expect(model.nodes.map(\.name) == ["Alpha", "Bravo", "Charlie"])
        #expect(model.children(of: SortFixture.alpha)?.map(\.name) == ["Yankee", "Xray", "Zulu"])
        #expect(model.visibleNodes.map(\.name) == ["Alpha", "Yankee", "Xray", "Zulu", "Bravo", "Charlie"])
    }

    @Test("re-assigning the same sort is a no-op")
    func anIdenticalSortChangesNothing() async {
        let repository = SortFixture.makeRepository()
        let model = SortFixture.makeModel(repository)
        await model.refresh(roots: SortFixture.rootURLs)
        await model.expand(SortFixture.alpha)
        let before = model.visibleNodes

        model.sort = .default

        #expect(model.visibleNodes == before)
        #expect(repository.callCount(for: SortFixture.alpha) == 1)
    }

    @Test("the filter matches the same folders under every sort")
    func filterResultsAreOrderAgnostic() async {
        var matchedSets: [Set<String>] = []
        for sort in SortFixture.everySort {
            let model = SortFixture.makeModel()
            model.sort = sort
            await model.refresh(roots: SortFixture.rootURLs)
            await model.setFilter("a")

            matchedSets.append(Set(model.visibleNodes.map(\.path)))
        }

        #expect(matchedSets.allSatisfy { $0 == matchedSets[0] })
        #expect(matchedSets[0].isEmpty == false)
    }

    /// The rows are a flattened tree, so the descending layout is NOT the ascending
    /// one reversed — each level is reversed within its own parent.
    @Test("a filtered tree still lays its rows out in sort order")
    func filteredRowsFollowTheActiveSort() async {
        let ascending = SortFixture.makeModel()
        ascending.sort = FolderSort(key: .name, direction: .ascending)
        await ascending.refresh(roots: SortFixture.rootURLs)
        await ascending.setFilter("a")

        let descending = SortFixture.makeModel()
        descending.sort = FolderSort(key: .name, direction: .descending)
        await descending.refresh(roots: SortFixture.rootURLs)
        await descending.setFilter("a")

        #expect(ascending.visibleNodes.map(\.name) == ["Alpha", "Xray", "Yankee", "Bravo", "Charlie"])
        #expect(descending.visibleNodes.map(\.name) == ["Charlie", "Bravo", "Alpha", "Yankee", "Xray"])
    }

    @Test("nodes carry the newest date their summary reported")
    func nodesCarryTheirNewestDate() async {
        let model = SortFixture.makeModel()
        await model.refresh(roots: SortFixture.rootURLs)
        await model.expand(SortFixture.alpha)

        #expect(model.nodes.first { $0.name == "Alpha" }?.newestDateAdded == 300)
        #expect(model.nodes.first { $0.name == "Charlie" }?.newestDateAdded == nil)
        #expect(model.children(of: SortFixture.alpha)?.first { $0.name == "Yankee" }?.newestDateAdded == 400)
    }
}

/// Three roots and one nested level, each with a distinct name AND a distinct date,
/// so all four orderings differ from one another — an ordering that happened to
/// agree with insertion order would otherwise pass without the sort running.
private enum SortFixture {
    static let alpha = "/Music/Alpha"
    static let bravo = "/Music/Bravo"
    static let charlie = "/Music/Charlie"
    static let xray = "/Music/Alpha/Xray"
    static let yankee = "/Music/Alpha/Yankee"
    static let zulu = "/Music/Alpha/Zulu"

    /// Deliberately NOT alphabetical and not date-ordered, so neither sort can be
    /// satisfied by leaving the incoming order alone.
    static var rootURLs: [URL] {
        [charlie, alpha, bravo].map { URL(fileURLWithPath: $0) }
    }

    static var everySort: [FolderSort] {
        [
            FolderSort(key: .name, direction: .ascending),
            FolderSort(key: .name, direction: .descending),
            FolderSort(key: .dateAdded, direction: .ascending),
            FolderSort(key: .dateAdded, direction: .descending),
        ]
    }

    static var rootExpectations: [(FolderSort, [String])] {
        [
            (everySort[0], ["Alpha", "Bravo", "Charlie"]),
            (everySort[1], ["Charlie", "Bravo", "Alpha"]),
            (everySort[2], ["Bravo", "Alpha", "Charlie"]),
            (everySort[3], ["Alpha", "Bravo", "Charlie"]),
        ]
    }

    static var childExpectations: [(FolderSort, [String])] {
        [
            (everySort[0], ["Xray", "Yankee", "Zulu"]),
            (everySort[1], ["Zulu", "Yankee", "Xray"]),
            (everySort[2], ["Xray", "Yankee", "Zulu"]),
            (everySort[3], ["Yankee", "Xray", "Zulu"]),
        ]
    }

    static func makeRepository() -> FakeFolderTreeRepository {
        FakeFolderTreeRepository(
            folders: [xray, yankee, zulu],
            rootTotals: [alpha: 3, bravo: 1, charlie: 1],
            newestDates: [alpha: 300, bravo: 100, xray: 200, yankee: 400]
        )
    }

    @MainActor
    static func makeModel(_ repository: FakeFolderTreeRepository? = nil) -> FolderSidebarViewModel {
        FolderSidebarViewModel(repository: repository ?? makeRepository())
    }
}
