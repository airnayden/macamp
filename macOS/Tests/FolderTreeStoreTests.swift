import Foundation
@testable import MacAMP
import Testing
import ViewModels

@MainActor
@Suite("Folder tree persistence", .serialized)
struct FolderTreeStoreTests {
    @Test("nothing persisted reads as an empty tree state")
    func absentStateIsEmpty() {
        let suiteName = Self.makeSuiteName()
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        #expect(Self.store(suiteName).load(profileId: 7) == .empty)
    }

    @Test("unreadable persisted state degrades to an empty tree state")
    func corruptStateIsEmpty() throws {
        let suiteName = Self.makeSuiteName()
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.set(Data("not json".utf8), forKey: "\(FolderTreeStore.defaultKey).profile.7")

        #expect(Self.store(suiteName).load(profileId: 7) == .empty)
    }

    @Test("expansion and selection round-trip through the persistence seam")
    func persistenceSeamRoundTrips() {
        let suiteName = Self.makeSuiteName()
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let seam = Self.store(suiteName).persistence
        let state = FolderTreeState(
            expandedPaths: ["/Music/Shared"],
            selection: FolderTreeSelection(rootId: 42, path: "/Music/Shared/Live Sets")
        )

        seam.save(7, state)

        #expect(seam.load(7) == state)
    }

    @Test("state is per profile, so a switch cannot read a sibling's tree")
    func stateIsProfileScoped() {
        let suiteName = Self.makeSuiteName()
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let store = Self.store(suiteName)
        store.save(profileId: 7, FolderTreeState(
            expandedPaths: ["/Music/Shared"],
            selection: FolderTreeSelection(rootId: 42, path: "/Music/Shared/Live Sets")
        ))

        #expect(store.load(profileId: 8) == .empty)
        #expect(store.load(profileId: 7).selection?.rootId == 42)
    }

    private static func store(_ suiteName: String) -> FolderTreeStore {
        FolderTreeStore(suiteName: suiteName)
    }

    private static func makeSuiteName() -> String {
        "com.example.macamp.tests.folderTree.\(UUID().uuidString)"
    }
}
