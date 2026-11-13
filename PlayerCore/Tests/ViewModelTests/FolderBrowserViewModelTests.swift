import Foundation
import GRDB
import Persistence
import Testing
@testable import ViewModels

@MainActor
struct FolderBrowserViewModelTests {
    private func seed(_ database: AppDatabase, root: String, count: Int) throws {
        let repo = TrackRepository(database)
        for index in 0 ..< count {
            _ = try repo.insert(TrackRecord(
                filePath: "\(root)/\(index).flac",
                title: "T\(index)",
                sortTitle: "T\(index)"
            ))
        }
    }

    @Test func selectingFolderAShowsTwoRows() async throws {
        let database = try AppDatabase.makeEmpty()
        try seed(database, root: "/Music/A", count: 2)
        try seed(database, root: "/Music/B", count: 3)
        let model = FolderBrowserViewModel(repository: TrackRepository(database), rootPath: "/Music/A")

        try await model.loadInitial()

        #expect(model.tracks.count == 2)
        #expect(model.tracks.allSatisfy { $0.filePath.hasPrefix("/Music/A/") })
        #expect(!model.hasMore)
    }

    @Test func selectingFolderBShowsThreeRows() async throws {
        let database = try AppDatabase.makeEmpty()
        try seed(database, root: "/Music/A", count: 2)
        try seed(database, root: "/Music/B", count: 3)
        let model = FolderBrowserViewModel(repository: TrackRepository(database), rootPath: "/Music/B")

        try await model.loadInitial()

        #expect(model.tracks.count == 3)
        #expect(model.tracks.allSatisfy { $0.filePath.hasPrefix("/Music/B/") })
    }

    @Test func paginatesByKeyset() async throws {
        let database = try AppDatabase.makeEmpty()
        try seed(database, root: "/Music/B", count: 3)
        let model = FolderBrowserViewModel(
            repository: TrackRepository(database),
            rootPath: "/Music/B",
            pageSize: 2
        )

        try await model.loadInitial()
        #expect(model.tracks.count == 2)
        #expect(model.hasMore)

        try await model.loadMore()
        #expect(model.tracks.count == 3)
        #expect(!model.hasMore)

        let ids = model.tracks.compactMap(\.id)
        #expect(ids == ids.sorted())
    }

    @Test func reentrantLoadInitialDuringLoadMoreNeverEmptiesFolderWindow() async throws {
        let database = try AppDatabase.makeEmpty()
        try seed(database, root: "/Music/B", count: 5)
        let model = FolderBrowserViewModel(
            repository: TrackRepository(database),
            rootPath: "/Music/B",
            pageSize: 2
        )

        try await model.loadInitial()
        #expect(model.tracks.count == 2)

        async let paging: Void = model.loadMore()
        async let reload: Void = model.loadInitial()
        _ = try await (paging, reload)

        #expect(!model.tracks.isEmpty)
        #expect(model.tracks.count >= 2)
        #expect(model.tracks.allSatisfy { $0.filePath.hasPrefix("/Music/B/") })
    }
}
