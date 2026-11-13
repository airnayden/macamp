import Foundation
import Persistence
import Testing
import ViewModels

@MainActor
struct FolderSidebarRestoreTests {
    private let guestID = ProfileRecord.guestID

    private func makeModel(
        _ repository: FakeFolderTreeRepository,
        _ store: InMemoryFolderTreeStore
    ) -> FolderSidebarViewModel {
        FolderSidebarViewModel(repository: repository, persistence: store.persistence)
    }

    @Test func expansionRoundTripsThroughThePersistenceSeam() async {
        let repository = FolderTreeFixture.makeRepository()
        let store = InMemoryFolderTreeStore()
        let model = makeModel(repository, store)
        await model.refresh(roots: [FolderTreeFixture.url(FolderTreeFixture.library)])

        await model.expand(FolderTreeFixture.library)
        #expect(store.state(for: guestID).expandedPaths == [FolderTreeFixture.library])

        model.collapse(FolderTreeFixture.library)
        #expect(store.state(for: guestID).expandedPaths.isEmpty)

        await model.expand(FolderTreeFixture.library)
        let restored = makeModel(repository, store)
        await restored.refresh(roots: [FolderTreeFixture.url(FolderTreeFixture.library)])

        #expect(restored.expandedPaths == [FolderTreeFixture.library])
        #expect(restored.visibleNodes.map(\.path) == [
            FolderTreeFixture.library,
            FolderTreeFixture.jazz,
            FolderTreeFixture.rock,
        ])
    }

    @Test func noteSelectionPersistsTheIdPathPair() async {
        let repository = FolderTreeFixture.makeRepository()
        let store = InMemoryFolderTreeStore()
        let model = makeModel(repository, store)
        await model.refresh(roots: [FolderTreeFixture.url(FolderTreeFixture.library)])
        await model.expand(FolderTreeFixture.library)

        model.noteSelection(rootId: FolderTreeFixture.nodeID(FolderTreeFixture.rock))

        #expect(store.state(for: guestID).selection == FolderTreeSelection(
            rootId: FolderTreeFixture.nodeID(FolderTreeFixture.rock),
            path: FolderTreeFixture.rock
        ))

        model.clearSelection()
        #expect(store.state(for: guestID).selection == nil)
    }

    @Test func persistedSubfolderSelectionResolvesBeforeAnyLevelIsExpanded() async {
        let repository = FolderTreeFixture.makeRepository()
        let store = InMemoryFolderTreeStore()
        let subID = FolderTreeFixture.nodeID(FolderTreeFixture.sub)
        store.seed(
            FolderTreeState(selection: FolderTreeSelection(rootId: subID, path: FolderTreeFixture.sub)),
            for: guestID
        )
        let model = makeModel(repository, store)

        await model.refresh(roots: [FolderTreeFixture.url(FolderTreeFixture.library)])

        #expect(model.path(forId: subID) == FolderTreeFixture.sub)
        #expect(model.isExpanded(FolderTreeFixture.library))
        #expect(model.isExpanded(FolderTreeFixture.rock))
        #expect(model.visibleNodes.map(\.path).contains(FolderTreeFixture.sub))
    }

    @Test func profileSwitchRestoresThatProfilesOwnPair() async {
        let repository = FolderTreeFixture.makeRepository()
        let store = InMemoryFolderTreeStore()
        let rockID = FolderTreeFixture.nodeID(FolderTreeFixture.rock)
        let liveID = FolderTreeFixture.nodeID(FolderTreeFixture.live)
        store.seed(
            FolderTreeState(selection: FolderTreeSelection(rootId: rockID, path: FolderTreeFixture.rock)),
            for: guestID
        )
        store.seed(
            FolderTreeState(selection: FolderTreeSelection(rootId: liveID, path: FolderTreeFixture.live)),
            for: 2
        )
        let model = makeModel(repository, store)

        await model.refresh(roots: [FolderTreeFixture.url(FolderTreeFixture.library)], profileId: guestID)
        #expect(model.path(forId: rockID) == FolderTreeFixture.rock)
        #expect(model.path(forId: liveID) == nil)

        await model.refresh(roots: [FolderTreeFixture.url(FolderTreeFixture.other)], profileId: 2)
        #expect(model.path(forId: liveID) == FolderTreeFixture.live)
        #expect(model.path(forId: rockID) == nil)
        #expect(model.nodes.map(\.path) == [FolderTreeFixture.other])
    }

    @Test func refreshAfterRootRemovalDropsItsSubtreeFromTheRegistry() async {
        let repository = FolderTreeFixture.makeRepository()
        let store = InMemoryFolderTreeStore()
        let model = makeModel(repository, store)
        await model.refresh(roots: [
            FolderTreeFixture.url(FolderTreeFixture.library),
            FolderTreeFixture.url(FolderTreeFixture.other),
        ])
        await model.expand(FolderTreeFixture.other)
        let liveID = FolderTreeFixture.nodeID(FolderTreeFixture.live)
        #expect(model.path(forId: liveID) == FolderTreeFixture.live)

        repository.setRootTotal(0, for: FolderTreeFixture.other)
        await model.refresh(roots: [FolderTreeFixture.url(FolderTreeFixture.library)])

        #expect(model.nodes.map(\.path) == [FolderTreeFixture.library])
        #expect(model.path(forId: liveID) == nil)
        #expect(model.path(forId: FolderTreeFixture.nodeID(FolderTreeFixture.other)) == nil)
        #expect(model.children(of: FolderTreeFixture.other) == nil)
        #expect(!model.expandedPaths.contains(FolderTreeFixture.other))
    }

    @Test func refreshRereadsExpandedLevelsSoNewFoldersAppear() async {
        let repository = FolderTreeFixture.makeRepository()
        let store = InMemoryFolderTreeStore()
        let model = makeModel(repository, store)
        await model.refresh(roots: [FolderTreeFixture.url(FolderTreeFixture.library)])
        await model.expand(FolderTreeFixture.library)
        #expect(model.children(of: FolderTreeFixture.library)?.map(\.name) == ["Jazz", "Rock"])

        repository.setFolders(FolderTreeFixture.folders + ["/Music/Lib/Ambient"])
        await model.refresh(roots: [FolderTreeFixture.url(FolderTreeFixture.library)])

        #expect(model.children(of: FolderTreeFixture.library)?.map(\.name) == ["Ambient", "Jazz", "Rock"])
        #expect(repository.callCount(for: FolderTreeFixture.library) == 2)
    }
}
