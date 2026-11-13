// The library browser's in-view search field, which now queries FTS5 instead of
// filtering the loaded window.
//
// The browser has no unit-test target, so everything the field decides —
// which repository overload runs for which corpus, how keystrokes coalesce, how
// the ranked window grows, and what clearing restores — lives in
// ``LibraryLocalSearchModel`` and is asserted here against a recording fake. The
// fake records the overload actually called, which is the only way to prove the
// folder scope reaches `searchTracks(profileId:rootPath:query:limit:)` rather
// than the library-wide one.
import Foundation
import Persistence
import Testing
@testable import ViewModels

@MainActor
@Suite("LibraryLocalSearchTests")
struct LibraryLocalSearchTests {
    private let fastDebounce = Duration.milliseconds(20)

    // MARK: - Routing

    @Test("All Tracks searches the whole visible library")
    func allTracksScopeUsesLibraryWideSearch() async {
        let reader = RecordingSearchReader(rows: Self.rows(12))
        let model = LibraryLocalSearchModel(
            reader: reader,
            scope: .allTracks,
            debounce: fastDebounce,
            pageSize: 50
        )

        model.search("boh")
        await pollUntil { !model.results.isEmpty }

        let calls = reader.calls
        try? #require(calls.count == 1)
        #expect(calls.first?.rootPath == nil)
        #expect(calls.first?.query == "boh")
        #expect(calls.first?.limit == 50)
        #expect(model.results.count == 12)
    }

    @Test("A folder view searches only that root's subtree")
    func folderScopeUsesRootScopedSearch() async {
        let reader = RecordingSearchReader(rows: Self.rows(3))
        let model = LibraryLocalSearchModel(
            reader: reader,
            scope: .folder(rootPath: "/Music/A"),
            debounce: fastDebounce
        )

        model.search("boh")
        await pollUntil { !model.results.isEmpty }

        #expect(reader.calls.first?.rootPath == "/Music/A")
    }

    @Test("Re-scoping to a folder re-runs a live query against the new corpus")
    func configureRerunsLiveQueryOnScopeChange() async {
        let reader = RecordingSearchReader(rows: Self.rows(3))
        let model = LibraryLocalSearchModel(reader: reader, debounce: fastDebounce)

        model.search("boh")
        await pollUntil { !model.results.isEmpty }
        model.configure(reader: reader, scope: .folder(rootPath: "/Music/A"), activeProfileId: 1)
        await pollUntil { reader.calls.count == 2 }

        #expect(reader.calls.map(\.rootPath) == [nil, "/Music/A"])
    }

    @Test("Re-configuring with an unchanged corpus does not re-query")
    func configureWithSameCorpusIsInert() async {
        let reader = RecordingSearchReader(rows: Self.rows(3))
        let model = LibraryLocalSearchModel(reader: reader, debounce: fastDebounce)

        model.search("boh")
        await pollUntil { !model.results.isEmpty }
        model.configure(reader: reader, scope: .allTracks, activeProfileId: ProfileRecord.guestID)
        try? await Task.sleep(for: .milliseconds(60))

        #expect(reader.calls.count == 1)
    }

    // MARK: - Debounce

    @Test("Rapid keystrokes coalesce into one query for the final text")
    func keystrokesCoalesce() async {
        let reader = RecordingSearchReader(rows: Self.rows(2))
        let model = LibraryLocalSearchModel(reader: reader, debounce: fastDebounce)

        model.search("b")
        model.search("bo")
        model.search("boh")
        await pollUntil { !model.results.isEmpty }
        try? await Task.sleep(for: .milliseconds(60))

        #expect(reader.calls.count == 1)
        #expect(reader.calls.first?.query == "boh")
    }

    @Test("A blank query never reaches the database")
    func blankQueryIsInert() async {
        let reader = RecordingSearchReader(rows: Self.rows(5))
        let model = LibraryLocalSearchModel(reader: reader, debounce: fastDebounce)

        model.search("   ")
        try? await Task.sleep(for: .milliseconds(60))

        #expect(reader.calls.isEmpty)
        #expect(model.isActive == false)
        #expect(model.results.isEmpty)
    }

    // MARK: - Growing window

    @Test("loadMore widens the ranked window by one page")
    func loadMoreGrowsTheWindow() async {
        let reader = RecordingSearchReader(rows: Self.rows(140))
        let model = LibraryLocalSearchModel(reader: reader, debounce: fastDebounce, pageSize: 50)

        model.search("boh")
        await pollUntil { !model.results.isEmpty }
        #expect(model.results.count == 50)
        #expect(model.hasMore)

        await model.loadMore()

        #expect(reader.calls.map(\.limit) == [50, 100])
        #expect(model.results.count == 100)
        #expect(model.hasMore)
    }

    @Test("A window that comes back short ends pagination")
    func shortWindowStopsPagination() async {
        let reader = RecordingSearchReader(rows: Self.rows(7))
        let model = LibraryLocalSearchModel(reader: reader, debounce: fastDebounce, pageSize: 50)

        model.search("boh")
        await pollUntil { !model.results.isEmpty }
        #expect(model.hasMore == false)

        await model.loadMore()

        #expect(reader.calls.count == 1)
    }

    @Test("A new query resets the window to the first page")
    func newQueryResetsTheWindow() async {
        let reader = RecordingSearchReader(rows: Self.rows(140))
        let model = LibraryLocalSearchModel(reader: reader, debounce: fastDebounce, pageSize: 50)

        model.search("boh")
        await pollUntil { !model.results.isEmpty }
        await model.loadMore()
        model.search("rha")
        await pollUntil { reader.calls.count == 3 }

        #expect(reader.calls.map(\.limit) == [50, 100, 50])
    }

    // MARK: - Clearing

    @Test("Clearing the query drops the search corpus so browse rows return")
    func clearingDropsResults() async {
        let reader = RecordingSearchReader(rows: Self.rows(9))
        let model = LibraryLocalSearchModel(reader: reader, debounce: fastDebounce)

        model.search("boh")
        await pollUntil { !model.results.isEmpty }
        #expect(model.isActive)

        model.clear()

        #expect(model.isActive == false)
        #expect(model.results.isEmpty)
        #expect(model.hasMore == false)
        #expect(model.query.isEmpty)
    }

    @Test("Emptying the field clears results without another query")
    func emptyingTheFieldClearsResults() async {
        let reader = RecordingSearchReader(rows: Self.rows(9))
        let model = LibraryLocalSearchModel(reader: reader, debounce: fastDebounce)

        model.search("boh")
        await pollUntil { !model.results.isEmpty }
        model.search("")
        try? await Task.sleep(for: .milliseconds(60))

        #expect(model.isActive == false)
        #expect(model.results.isEmpty)
        #expect(reader.calls.count == 1)
    }

    // MARK: - Fixtures

    private static func rows(_ count: Int) -> [TrackRecord] {
        (0 ..< count).map { index in
            makeTrackRecord(filePath: "/Music/A/\(index).flac", title: "T\(index)")
        }
    }
}

/// A ``LibraryLocalSearchReading`` fake that records which overload ran.
///
/// `rootPath` is `nil` for the library-wide call and set for the folder-scoped
/// one, so a single recorded call proves the routing the browser depends on.
private final class RecordingSearchReader: LibraryLocalSearchReading, @unchecked Sendable {
    struct Call: Equatable {
        let rootPath: String?
        let query: String
        let limit: Int
        let profileId: Int64
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    private let rows: [TrackRecord]

    init(rows: [TrackRecord]) {
        self.rows = rows
    }

    var calls: [Call] {
        lock.withLock { recorded }
    }

    func searchTracks(profileId: Int64, query: String, limit: Int) throws -> [TrackRecord] {
        record(Call(rootPath: nil, query: query, limit: limit, profileId: profileId))
        return Array(rows.prefix(limit))
    }

    func searchTracks(profileId: Int64, rootPath: String, query: String, limit: Int) throws -> [TrackRecord] {
        record(Call(rootPath: rootPath, query: query, limit: limit, profileId: profileId))
        return Array(rows.prefix(limit))
    }

    private func record(_ call: Call) {
        lock.withLock { recorded.append(call) }
    }
}
