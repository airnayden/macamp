// FolderSort — the persisted ordering vocabulary and the ONE comparator the
// sidebar folder tree and the folder browser both order by.
//
// Two contracts are pinned here because other layers are written against them:
//
// 1. The raw-value tokens (`"name.ascending"`, `"manual"`) are what settings
//    persist, so they are a frozen wire format — and a corrupt token must decode
//    to `nil` so the caller falls back to its own default rather than silently
//    accepting a shape it did not write.
// 2. The nil policy: a folder with no dated track sorts LAST in BOTH directions.
//    The SQL keyset variants of `tracksDirectlyIn` order by the same rule, so a
//    change here without the matching SQL change produces pages that disagree.
import Foundation
import Models
import Testing
@testable import ViewModels

@Suite("FolderSortTests")
struct FolderSortTests {
    private let directions: [FolderSortDirection] = [.ascending, .descending]

    private var everySort: [FolderSort] {
        FolderSortKey.allCases.flatMap { key in
            directions.map { FolderSort(key: key, direction: $0) }
        }
    }

    // MARK: - Fixtures

    /// Sorts `values` (name, newestDateAdded) by `sort` and reports the names.
    private func ordered(_ values: [(String, Double?)], by sort: FolderSort) -> [String] {
        values
            .map { (name: $0.0, newestDateAdded: $0.1) }
            .sorted { FolderSort.compare($0, $1, by: sort) }
            .map(\.name)
    }

    /// Sorts undated folders — the name key ignores `newestDateAdded` entirely.
    private func ordered(names: [String], by sort: FolderSort) -> [String] {
        ordered(names.map { ($0, nil) }, by: sort)
    }

    // MARK: - Raw-value round trips

    @Test("every FolderSort round-trips through its persisted token")
    func folderSortRoundTripsThroughItsToken() {
        for sort in everySort {
            #expect(FolderSort(rawValue: sort.rawValue) == sort)
        }
    }

    @Test("the FolderSort token spells key then direction")
    func folderSortTokenSpellsKeyThenDirection() {
        #expect(FolderSort(key: .name, direction: .ascending).rawValue == "name.ascending")
        #expect(FolderSort(key: .name, direction: .descending).rawValue == "name.descending")
        #expect(FolderSort(key: .dateAdded, direction: .ascending).rawValue == "dateAdded.ascending")
        #expect(FolderSort(key: .dateAdded, direction: .descending).rawValue == "dateAdded.descending")
        #expect(FolderSort.default == FolderSort(key: .name, direction: .ascending))
    }

    @Test("a corrupt FolderSort token decodes to nil — never to the default")
    func corruptFolderSortTokenDecodesToNil() {
        let corrupt = ["bogus", "", "name", "name.", ".ascending", "name.ascending.extra", "Name.Ascending", "manual"]
        for token in corrupt {
            #expect(FolderSort(rawValue: token) == nil, "\(token) should not decode")
        }
    }

    @Test("every FolderFilesSort round-trips through its persisted token")
    func folderFilesSortRoundTripsThroughItsToken() {
        for value in [FolderFilesSort.manual] + everySort.map(FolderFilesSort.sorted) {
            #expect(FolderFilesSort(rawValue: value.rawValue) == value)
        }
        #expect(FolderFilesSort.manual.rawValue == "manual")
        #expect(FolderFilesSort.sorted(FolderSort(key: .name, direction: .descending)).rawValue == "name.descending")
        #expect(FolderFilesSort.default == .manual)
    }

    @Test("a corrupt FolderFilesSort token decodes to nil — never to manual")
    func corruptFolderFilesSortTokenDecodesToNil() {
        for token in ["", "bogus", "Manual", "name.sideways", "dateAdded"] {
            #expect(FolderFilesSort(rawValue: token) == nil, "\(token) should not decode")
        }
    }

    @Test("FolderFilesSort survives a Codable round trip")
    func folderFilesSortSurvivesACodableRoundTrip() throws {
        let values = [FolderFilesSort.manual] + everySort.map(FolderFilesSort.sorted)
        let data = try JSONEncoder().encode(values)
        let decoded = try JSONDecoder().decode([FolderFilesSort].self, from: data)
        #expect(decoded == values)
    }

    // MARK: - Comparator: name

    @Test("the name key orders case-insensitively in both directions")
    func nameKeyOrdersCaseInsensitively() {
        let folders = ["banana", "Apple", "cherry", "DATE"]
        #expect(ordered(names: folders, by: FolderSort(key: .name, direction: .ascending))
            == ["Apple", "banana", "cherry", "DATE"])
        #expect(ordered(names: folders, by: FolderSort(key: .name, direction: .descending))
            == ["DATE", "cherry", "banana", "Apple"])
    }

    @Test("the name key folds diacritics onto their base letter")
    func nameKeyFoldsDiacritics() {
        let folders = ["Zebra", "Éclair", "Apple"]
        #expect(ordered(names: folders, by: FolderSort(key: .name, direction: .ascending))
            == ["Apple", "Éclair", "Zebra"])
        #expect(ordered(names: folders, by: FolderSort(key: .name, direction: .descending))
            == ["Zebra", "Éclair", "Apple"])
    }

    @Test("the name key ignores dateAdded entirely")
    func nameKeyIgnoresDateAdded() {
        let folders: [(String, Double?)] = [("b", 900), ("a", nil), ("c", 100)]
        #expect(ordered(folders, by: FolderSort(key: .name, direction: .ascending)) == ["a", "b", "c"])
    }

    // MARK: - Comparator: dateAdded

    @Test("the dateAdded key orders by date, newest last ascending")
    func dateAddedKeyOrdersByDate() {
        let folders: [(String, Double?)] = [("old", 100), ("new", 300), ("mid", 200)]
        #expect(ordered(folders, by: FolderSort(key: .dateAdded, direction: .ascending)) == ["old", "mid", "new"])
        #expect(ordered(folders, by: FolderSort(key: .dateAdded, direction: .descending)) == ["new", "mid", "old"])
    }

    @Test("an undated folder sorts LAST in BOTH directions — the epic's single nil policy")
    func undatedSortsLastInBothDirections() {
        let dated = (name: "dated", newestDateAdded: Double?.some(100))
        let undated = (name: "undated", newestDateAdded: Double?.none)
        for direction in directions {
            let sort = FolderSort(key: .dateAdded, direction: direction)
            #expect(FolderSort.compare(dated, undated, by: sort), "\(direction) put the undated folder first")
            #expect(!FolderSort.compare(undated, dated, by: sort), "\(direction) put the undated folder first")
        }
    }

    @Test("undated folders land at the tail of a mixed listing in both directions")
    func undatedFoldersLandAtTheTail() {
        let folders: [(String, Double?)] = [("beta", nil), ("old", 100), ("alpha", nil), ("new", 300)]
        #expect(ordered(folders, by: FolderSort(key: .dateAdded, direction: .ascending))
            == ["old", "new", "alpha", "beta"])
        #expect(ordered(folders, by: FolderSort(key: .dateAdded, direction: .descending))
            == ["new", "old", "alpha", "beta"])
    }

    @Test("a dateAdded tie breaks by name ASCENDING — direction flips only the primary key")
    func dateAddedTieBreaksByNameAscending() {
        let folders: [(String, Double?)] = [("beta", 100), ("Alpha", 100), ("gamma", 100)]
        for direction in directions {
            #expect(
                ordered(folders, by: FolderSort(key: .dateAdded, direction: direction))
                    == ["Alpha", "beta", "gamma"],
                "\(direction) flipped the tiebreak"
            )
        }
    }

    @Test("two undated folders also tie-break by name ascending")
    func undatedFoldersTieBreakByNameAscending() {
        let folders: [(String, Double?)] = [("beta", nil), ("Alpha", nil)]
        for direction in directions {
            #expect(ordered(folders, by: FolderSort(key: .dateAdded, direction: direction)) == ["Alpha", "beta"])
        }
    }

    @Test("no sort reports a row as ordered before itself")
    func comparatorIsIrreflexive() {
        let rows = [(name: "same", newestDateAdded: Double?.some(100)), (name: "same", newestDateAdded: nil)]
        for sort in everySort {
            for row in rows {
                #expect(!FolderSort.compare(row, row, by: sort), "\(sort.rawValue) ordered a row before itself")
            }
        }
    }
}
