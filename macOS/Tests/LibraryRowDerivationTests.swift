import Foundation
@testable import MacAMP
import Persistence
import Testing
import ViewModels

/// Fixture builders and the legacy chain, kept at file scope so both suites share
/// them without a `type_body_length` breach.
private enum Fixture {
    static var sortOrder: [KeyPathComparator<LibraryTrackRow>] {
        [KeyPathComparator(\LibraryTrackRow.titleText)]
    }

    static func track(_ id: Int64, _ title: String?, genre: String? = nil, path: String? = nil) -> TrackRecord {
        TrackRecord(
            id: id,
            filePath: path ?? "/Music/\(id).flac",
            title: title,
            genre: genre
        )
    }

    /// The chain this todo replaced, composed by hand: `displayedTracks` → the genre
    /// chip on search results → `map(LibraryTrackRow.init)` → the gated
    /// `sorted(using:)`. Any drift between this and ``LibraryBrowserRows/deriveRows``
    /// is the regression the order-identity tests exist to catch.
    static func legacyRows(
        source: [TrackRecord],
        searchActive: Bool,
        searchResults: [TrackRecord],
        genre: GenreFilter,
        filterRootPath: String?
    ) -> [LibraryTrackRow] {
        let displayed: [TrackRecord] = if searchActive {
            searchResults.filter { track in
                switch genre {
                case .all: true
                case .untagged: track.genre == nil || (track.genre ?? "").isEmpty
                case let .genre(name): track.genre == name
                }
            }
        } else {
            source
        }
        let rows = displayed.map { LibraryTrackRow(track: $0) }
        guard FolderReorderPolicy.appliesTableSort(filterRootPath: filterRootPath) else { return rows }
        return rows.sorted(using: sortOrder)
    }

    static func browse(_ source: [TrackRecord], filterRootPath: String? = nil) -> [LibraryTrackRow] {
        LibraryBrowserRows.deriveRows(
            source: source,
            searchActive: false,
            searchResults: [],
            genre: .all,
            filterRootPath: filterRootPath,
            sortOrder: sortOrder
        ).rows
    }

    /// `LibraryBrowserView.seedTrack(for:)`'s rule: the first row of the rendered
    /// order whose id is selected.
    static func seed(_ rows: [LibraryTrackRow], _ ids: Set<Int64>) -> TrackRecord? {
        rows.first { ids.contains($0.id) }?.track
    }

    /// `refs(for:)` / `records(for:)`'s rule: the selected rows, in rendered order.
    static func selected(_ rows: [LibraryTrackRow], _ ids: Set<Int64>) -> [Int64] {
        rows.filter { ids.contains($0.id) }.map(\.id)
    }
}

/// Reads a shipped source file so a converted call site cannot silently revert to
/// the stale computed chain while the behavioural fixtures still pass.
private enum Source {
    static func text(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}

@Suite("Library row derivation")
struct LibraryRowDerivationTests {
    @Test("All Tracks derives byte-identically to the chain it replaced")
    func allTracksMatchesLegacyChain() {
        let source = [
            Fixture.track(1, "Zephyr"),
            Fixture.track(2, "Anvil"),
            Fixture.track(3, "Marrow"),
            Fixture.track(4, "anvil chorus"),
        ]

        let derived = Fixture.browse(source)
        let legacy = Fixture.legacyRows(
            source: source,
            searchActive: false,
            searchResults: [],
            genre: .all,
            filterRootPath: nil
        )

        #expect(derived.map(\.id) == legacy.map(\.id))
        #expect(derived.map(\.titleText) == legacy.map(\.titleText))
    }

    @Test("a genre window arrives id-ordered and is re-sorted, not passed through")
    func genreWindowIsResorted() {
        // `tracksByGenre` pages by `track.id`, so the window reaches the browser in
        // id order. This is the fence for "the sort is redundant" — it is not.
        let window = [
            Fixture.track(1, "Willow", genre: "Jazz"),
            Fixture.track(2, "Basalt", genre: "Jazz"),
            Fixture.track(3, "Quarry", genre: "Jazz"),
        ]

        let derived = Fixture.browse(window)

        #expect(derived.map(\.id) == [2, 3, 1])
        #expect(derived.map(\.id) != window.map { $0.id ?? 0 })
    }

    @Test("search results are re-sorted alphabetically, discarding BM25 rank")
    func searchResultsAreAlphabetical() {
        let ranked = [
            Fixture.track(7, "Tidewater"),
            Fixture.track(8, "Cinder"),
            Fixture.track(9, "Harrow"),
        ]

        let derived = LibraryBrowserRows.deriveRows(
            source: [Fixture.track(1, "Anvil")],
            searchActive: true,
            searchResults: ranked,
            genre: .all,
            sortOrder: Fixture.sortOrder
        )

        #expect(derived.rows.map(\.id) == [8, 9, 7])
        let legacy = Fixture.legacyRows(
            source: [Fixture.track(1, "Anvil")],
            searchActive: true,
            searchResults: ranked,
            genre: .all,
            filterRootPath: nil
        )
        #expect(derived.rows.map(\.id) == legacy.map(\.id))
    }

    @Test("the genre chip narrows search results; a browse window is narrowed upstream")
    func genreChipNarrowsEachMode() {
        let mixed = [
            Fixture.track(1, "Anvil", genre: "Jazz"),
            Fixture.track(2, "Basalt", genre: "Rock"),
            Fixture.track(3, "Cinder", genre: ""),
            Fixture.track(4, "Delta"),
        ]

        let searched = LibraryBrowserRows.deriveRows(
            source: mixed,
            searchActive: true,
            searchResults: mixed,
            genre: .genre("Jazz"),
            sortOrder: Fixture.sortOrder
        )
        #expect(searched.rows.map(\.id) == [1])

        let untagged = LibraryBrowserRows.deriveRows(
            source: mixed,
            searchActive: true,
            searchResults: mixed,
            genre: .untagged,
            sortOrder: Fixture.sortOrder
        )
        #expect(untagged.rows.map(\.id) == [3, 4])

        // Browse mode: `syncSourceTracks()` already narrowed the window, so the
        // deriver passes it through untouched rather than re-filtering a window
        // that may still be the previous chip's.
        let preNarrowed = mixed.filter { $0.genre == "Rock" }
        let browsed = LibraryBrowserRows.deriveRows(
            source: preNarrowed,
            searchActive: false,
            searchResults: mixed,
            genre: .genre("Jazz"),
            sortOrder: Fixture.sortOrder
        )
        #expect(browsed.rows.map(\.id) == [2])
    }

    @Test("indexById maps every row id to its rendered position")
    func indexByIdMatchesRenderedPositions() {
        let source = [
            Fixture.track(11, "Zephyr"),
            Fixture.track(12, "Anvil"),
            Fixture.track(13, "Marrow"),
        ]

        let derived = LibraryBrowserRows.deriveRows(
            source: source,
            searchActive: false,
            searchResults: [],
            genre: .all,
            sortOrder: Fixture.sortOrder
        )

        #expect(derived.indexById.count == derived.rows.count)
        for (index, row) in derived.rows.enumerated() {
            #expect(derived.indexById[row.id] == index)
        }
        #expect(derived.indexById[12] == 0)
        #expect(derived.indexById[99] == nil)
    }

    @Test("untagged rows sort by the filename stem, not the full path")
    func untaggedRowsSortByFilenameStem() {
        // Todo 9's `TrackRecord.displayTitle`: a trimmed non-empty tag wins verbatim,
        // otherwise the stem — `lastPathComponent` minus ONE extension, with no
        // underscore replacement and no case folding. So the untagged row below keys
        // on "02 Dream Theater -This Dying Soul" (sorting under "0"), not on the
        // "/Volumes/…" path it keyed on before that change.
        let source = [
            Fixture.track(1, "Basalt"),
            Fixture.track(2, nil, path: "/Volumes/ANDROMEDA/music/02 Dream Theater -This Dying Soul.mp3"),
            Fixture.track(3, "  Anvil  "),
            Fixture.track(4, nil, path: "/Volumes/ANDROMEDA/music/01_THE_bends.flac"),
        ]

        let derived = Fixture.browse(source)

        #expect(derived.map(\.titleText) == [
            "01_THE_bends",
            "02 Dream Theater -This Dying Soul",
            "Anvil",
            "Basalt",
        ])
        #expect(derived.map(\.id) == [4, 2, 3, 1])
    }

    @Test("a folder window keeps its user-owned drag order, unsorted")
    func folderWindowIsNotResorted() {
        let dragged = [
            Fixture.track(1, "Zephyr"),
            Fixture.track(2, "Anvil"),
            Fixture.track(3, "Marrow"),
        ]

        let derived = Fixture.browse(dragged, filterRootPath: "/Music/Live Sets")

        #expect(derived.map(\.id) == [1, 2, 3])
        #expect(derived.map(\.id) == Fixture.legacyRows(
            source: dragged,
            searchActive: false,
            searchResults: [],
            genre: .all,
            filterRootPath: "/Music/Live Sets"
        ).map(\.id))
    }
}

@Suite("Library row derivation — converted call sites")
struct LibraryRowCallSiteTests {
    /// A page append that changes the derived order without changing the source
    /// order, so a site reading the wrong array picks a different row.
    private static let pageOne = [
        Fixture.track(1, "Marrow"),
        Fixture.track(2, "Zephyr"),
    ]
    private static let pageTwo = pageOne + [Fixture.track(3, "Anvil")]

    @Test("seedTrack picks from the rendered order, not the source order")
    func seedTrackFollowsRenderedOrder() throws {
        let before = Fixture.browse(Self.pageOne)
        let after = Fixture.browse(Self.pageTwo)
        let ids: Set<Int64> = [1, 2, 3]

        // The fixture is discriminating: the two orders disagree about which row
        // comes first, so reading a stale array is observable.
        #expect(Fixture.seed(before, ids)?.id == 1)
        #expect(Fixture.seed(after, ids)?.id == 3)
        #expect(after.map(\.id) != Self.pageTwo.map { $0.id ?? 0 })

        let source = try Source.text("macOS/Sources/LibraryBrowserActions.swift")
        #expect(source.contains("derivedRows.first {"))
    }

    @Test("refs and records return the rendered order")
    func refsAndRecordsFollowRenderedOrder() throws {
        let rendered = Fixture.browse(Self.pageTwo)
        let ids: Set<Int64> = [1, 3]

        #expect(Fixture.selected(rendered, ids) == [3, 1])
        #expect(Fixture.selected(rendered, ids) != Self.pageTwo.compactMap(\.id).filter { ids.contains($0) })

        // The only `sortedRows` left in the file is its own definition, which exists
        // solely to feed the unreachable `Table` branch; every reader is converted.
        let source = try Source.text("macOS/Sources/LibraryBrowserActions.swift")
        #expect(source.components(separatedBy: "sortedRows").count - 1 == 1)
        #expect(source.contains("var sortedRows"))
    }

    @Test("the empty state reads the cached rows, not the computed chain")
    func emptyStateReadsDerivedRows() throws {
        let source = try Source.text("macOS/Sources/LibraryBrowserView.swift")

        #expect(source.contains("if derivedRows.isEmpty {"))
        #expect(!source.contains("if rows.isEmpty {"))
    }

    @Test("the scroll prefetch looks a row up in O(1)")
    func prefetchUsesTheIndex() throws {
        let source = try Source.text("macOS/Sources/LibraryBrowserPagination.swift")

        #expect(source.contains("rowIndexById[row.id]"))
        #expect(!source.contains("firstIndex"))
    }
}
