import Foundation
import Persistence
import Testing
import ViewModels

@MainActor
struct FolderSidebarTreeTests {
    private func makeModel(
        _ repository: FakeFolderTreeRepository,
        store: InMemoryFolderTreeStore? = nil
    ) -> FolderSidebarViewModel {
        FolderSidebarViewModel(
            repository: repository,
            persistence: store?.persistence ?? .ephemeral
        )
    }

    @Test func expandLoadsChildrenExactlyOnce() async {
        let repository = FolderTreeFixture.makeRepository()
        let model = makeModel(repository)
        await model.refresh(roots: [FolderTreeFixture.url(FolderTreeFixture.library)])
        #expect(repository.callCount(for: FolderTreeFixture.library) == 0)

        await model.expand(FolderTreeFixture.library)
        await model.expand(FolderTreeFixture.library)
        model.collapse(FolderTreeFixture.library)
        await model.expand(FolderTreeFixture.library)

        #expect(repository.callCount(for: FolderTreeFixture.library) == 1)
        #expect(model.children(of: FolderTreeFixture.library)?.map(\.name) == ["Jazz", "Rock"])
    }

    @Test func expandingPublishesChildRowsAtTheRightDepth() async {
        let repository = FolderTreeFixture.makeRepository()
        let model = makeModel(repository)
        await model.refresh(roots: [FolderTreeFixture.url(FolderTreeFixture.library)])
        await model.expand(FolderTreeFixture.library)
        await model.expand(FolderTreeFixture.rock)

        #expect(model.visibleNodes.map(\.path) == [
            FolderTreeFixture.library,
            FolderTreeFixture.jazz,
            FolderTreeFixture.rock,
            FolderTreeFixture.sub,
        ])
        let subNode = model.visibleNodes.first { $0.path == FolderTreeFixture.sub }
        #expect(subNode?.depth == 2)
        #expect(subNode?.hasChildren == true)
        #expect(model.visibleNodes.first?.depth == 0)
    }

    @Test func pathResolvesNestedIds() async {
        let repository = FolderTreeFixture.makeRepository()
        let model = makeModel(repository)
        await model.refresh(roots: [FolderTreeFixture.url(FolderTreeFixture.library)])
        await model.expand(FolderTreeFixture.library)
        await model.expand(FolderTreeFixture.rock)

        let rockId = FolderTreeFixture.nodeID(FolderTreeFixture.rock)
        let subId = FolderTreeFixture.nodeID(FolderTreeFixture.sub)
        #expect(model.path(forId: rockId) == FolderTreeFixture.rock)
        #expect(model.rootPath(forId: subId) == FolderTreeFixture.sub)
        #expect(model.path(forId: FolderTreeFixture.nodeID(FolderTreeFixture.deep)) == nil)
    }

    @Test func filterSurfacesDeepNodeWithAncestorsExpanded() async {
        let repository = FolderTreeFixture.makeRepository()
        let model = makeModel(repository)
        await model.refresh(roots: [
            FolderTreeFixture.url(FolderTreeFixture.library),
            FolderTreeFixture.url(FolderTreeFixture.other),
        ])

        await model.setFilter("deep")

        #expect(model.visibleNodes.map(\.path) == [
            FolderTreeFixture.library,
            FolderTreeFixture.rock,
            FolderTreeFixture.sub,
            FolderTreeFixture.deep,
        ])
        #expect(model.isExpanded(FolderTreeFixture.library))
        #expect(model.isExpanded(FolderTreeFixture.rock))
        #expect(model.isExpanded(FolderTreeFixture.sub))
        #expect(model.expandedPaths.isEmpty)
    }

    @Test func filterIgnoresCaseAndDiacritics() async {
        let repository = FakeFolderTreeRepository(
            folders: ["/Music/Lib/Café", "/Music/Lib/Rock"],
            rootTotals: ["/Music/Lib": 3]
        )
        let model = makeModel(repository)
        await model.refresh(roots: [FolderTreeFixture.url(FolderTreeFixture.library)])

        await model.setFilter("  CAFE ")

        #expect(model.visibleNodes.map(\.path) == [FolderTreeFixture.library, "/Music/Lib/Café"])
    }

    @Test func filterWithZeroMatchesYieldsEmptyListAndLeavesStateIntact() async {
        let repository = FolderTreeFixture.makeRepository()
        let model = makeModel(repository)
        await model.refresh(roots: [FolderTreeFixture.url(FolderTreeFixture.library)])
        await model.expand(FolderTreeFixture.library)

        await model.setFilter("zzzz")

        #expect(model.visibleNodes.isEmpty)
        #expect(model.nodes.map(\.path) == [FolderTreeFixture.library])
        #expect(model.expandedPaths == [FolderTreeFixture.library])
        #expect(model.path(forId: FolderTreeFixture.nodeID(FolderTreeFixture.rock)) == FolderTreeFixture.rock)

        await model.setFilter("")

        #expect(model.visibleNodes.map(\.path) == [
            FolderTreeFixture.library,
            FolderTreeFixture.jazz,
            FolderTreeFixture.rock,
        ])
    }

    @Test func rootChevronsAreExactOnTheFirstRefreshWithoutExpanding() async {
        let repository = FolderTreeFixture.makeLeafAndNestedRepository()
        let model = makeModel(repository)

        await model.refresh(roots: [
            FolderTreeFixture.url(FolderTreeFixture.library),
            FolderTreeFixture.url(FolderTreeFixture.leaf),
        ])

        let nested = model.nodes.first { $0.path == FolderTreeFixture.library }
        let leaf = model.nodes.first { $0.path == FolderTreeFixture.leaf }
        #expect(nested?.hasChildren == true)
        #expect(leaf?.hasChildren == false)
        #expect(repository.childFolderCalls.isEmpty)
    }

    @Test func eachUnknownRootIsProbedOnceAndThenServedFromTheCache() async {
        let repository = FolderTreeFixture.makeLeafAndNestedRepository()
        let model = makeModel(repository)
        let roots = [
            FolderTreeFixture.url(FolderTreeFixture.library),
            FolderTreeFixture.url(FolderTreeFixture.leaf),
        ]

        await model.refresh(roots: roots)
        await model.refresh(roots: roots)

        #expect(repository.probeCount(for: FolderTreeFixture.library) == 1)
        #expect(repository.probeCount(for: FolderTreeFixture.leaf) == 1)
        #expect(model.nodes.first { $0.path == FolderTreeFixture.leaf }?.hasChildren == false)
    }

    @Test func aProfileSwitchReprobesEveryRoot() async {
        let repository = FolderTreeFixture.makeLeafAndNestedRepository()
        let model = makeModel(repository)
        let roots = [FolderTreeFixture.url(FolderTreeFixture.leaf)]

        await model.refresh(roots: roots, profileId: ProfileRecord.guestID)
        await model.refresh(roots: roots, profileId: 42)

        #expect(repository.probeCount(for: FolderTreeFixture.leaf) == 2)
        #expect(model.nodes.first?.hasChildren == false)
    }

    @Test func aFailedProbeLeavesTheChevronInPlace() async {
        let repository = FolderTreeFixture.makeLeafAndNestedRepository()
        repository.failSubfolderProbes()
        let model = makeModel(repository)

        await model.refresh(roots: [FolderTreeFixture.url(FolderTreeFixture.leaf)])

        #expect(model.nodes.first?.hasChildren == true)
    }

    @Test func loadChildrenOnVanishedPathReturnsEmpty() async {
        let repository = FolderTreeFixture.makeRepository()
        let model = makeModel(repository)
        await model.refresh(roots: [FolderTreeFixture.url(FolderTreeFixture.library)])

        let children = await model.loadChildren(of: "/Music/Lib/Gone")

        #expect(children.isEmpty)
        #expect(model.children(of: "/Music/Lib/Gone")?.isEmpty == true)
        #expect(model.nodes.map(\.path) == [FolderTreeFixture.library])
    }
}
