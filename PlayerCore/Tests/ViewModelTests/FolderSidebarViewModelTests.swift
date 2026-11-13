import Foundation
import GRDB
import Persistence
import Testing
@testable import ViewModels

@MainActor
struct FolderSidebarViewModelTests {
    private func seed(
        _ database: AppDatabase,
        root: String,
        count: Int,
        availability: Availability = .present
    ) throws {
        let repo = TrackRepository(database)
        for index in 0 ..< count {
            _ = try repo.insert(TrackRecord(
                filePath: "\(root)/\(index).flac",
                title: "T\(index)",
                sortTitle: "T\(index)",
                availability: availability
            ))
        }
    }

    @Test func buildsOneNodePerPopulatedRoot() async throws {
        let database = try AppDatabase.makeEmpty()
        try seed(database, root: "/Music/A", count: 2)
        try seed(database, root: "/Music/B", count: 3)
        let model = FolderSidebarViewModel(repository: TrackRepository(database))

        await model.refresh(roots: [
            URL(fileURLWithPath: "/Music/A"),
            URL(fileURLWithPath: "/Music/B"),
        ])

        #expect(model.nodes.count == 2)
        #expect(model.nodes.map(\.name) == ["A", "B"])
        #expect(model.nodes.allSatisfy { !$0.isMissing })
    }

    @Test func dropsRootsWithNoTracks() async throws {
        let database = try AppDatabase.makeEmpty()
        try seed(database, root: "/Music/A", count: 2)
        let model = FolderSidebarViewModel(repository: TrackRepository(database))

        await model.refresh(roots: [
            URL(fileURLWithPath: "/Music/A"),
            URL(fileURLWithPath: "/Music/Empty"),
        ])

        #expect(model.nodes.map(\.path) == ["/Music/A"])
    }

    @Test func rootPathResolvesSelectedId() async throws {
        let database = try AppDatabase.makeEmpty()
        try seed(database, root: "/Music/A", count: 1)
        let model = FolderSidebarViewModel(repository: TrackRepository(database))
        await model.refresh(roots: [URL(fileURLWithPath: "/Music/A")])

        let node = try #require(model.nodes.first)
        #expect(model.rootPath(forId: node.rootId) == "/Music/A")
        #expect(node.destination == .folder(rootId: node.rootId))
        #expect(model.rootPath(forId: node.rootId &+ 1) == nil)
    }

    @Test func removedRootDisappearsEvenWhenMissingTracksRemain() async throws {
        let database = try AppDatabase.makeEmpty()
        try seed(database, root: "/Music/A", count: 2)
        try seed(database, root: "/Music/B", count: 3)
        let model = FolderSidebarViewModel(repository: TrackRepository(database))
        await model.refresh(roots: [
            URL(fileURLWithPath: "/Music/A"),
            URL(fileURLWithPath: "/Music/B"),
        ])
        #expect(model.nodes.count == 2)

        try await database.writer.write { db in
            try db.execute(
                sql: "UPDATE track SET availability = ? WHERE filePath LIKE '/Music/B/%'",
                arguments: [Availability.missing.rawValue]
            )
        }
        await model.refresh(roots: [URL(fileURLWithPath: "/Music/A")])

        #expect(model.nodes.map(\.path) == ["/Music/A"])
        #expect(model.visibleNodes.map(\.path) == ["/Music/A"])
        #expect(model.path(forId: FolderSidebarViewModel.stableRootId(forPath: "/Music/B")) == nil)

        await model.refresh(roots: [URL(fileURLWithPath: "/Music/A"), URL(fileURLWithPath: "/Music/B")])
        #expect(model.nodes.first { $0.path == "/Music/B" }?.isMissing == true)
    }

    @Test func refreshWithProfileRootsShowsOnlyThatProfilesNodes() async throws {
        let database = try AppDatabase.makeEmpty()
        try seed(database, root: "/Music/P1", count: 2)
        try seed(database, root: "/Music/P2", count: 3)
        let profiles = ProfileRepository(database)
        let profile2 = try profiles.create(ProfileRecord(name: "P2"))
        let profile2Id = try #require(profile2.id)
        let roots = LibraryRootRepository(database)
        try roots.addRoot(profileId: ProfileRecord.guestID, path: "/Music/P1")
        try roots.addRoot(profileId: profile2Id, path: "/Music/P2")

        // GRDBLibraryRootsStore lives in the macOS shell (unimportable here), so
        // this mirrors its load() — rootsForProfile(active) → URLs — to prove the
        // sidebar sees only the active profile's roots.
        let profile2Roots = try roots
            .rootsForProfile(profile2Id, limit: LibraryRootRepository.fetchLimit)
            .map { URL(fileURLWithPath: $0.path) }
        let model = FolderSidebarViewModel(repository: TrackRepository(database))
        await model.refresh(roots: profile2Roots)

        #expect(model.nodes.map(\.path) == ["/Music/P2"])
    }

    @Test func stableRootIdIsDeterministicNonNegativeAndDistinct() {
        let first = FolderSidebarViewModel.stableRootId(forPath: "/Music/A")
        let repeated = FolderSidebarViewModel.stableRootId(forPath: "/Music/A")
        let other = FolderSidebarViewModel.stableRootId(forPath: "/Music/B")
        #expect(first == repeated)
        #expect(first != other)
        #expect(first >= 0)
        #expect(other >= 0)
    }
}
