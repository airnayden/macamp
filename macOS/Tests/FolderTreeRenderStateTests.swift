import Foundation
@testable import MacAMP
import Persistence
import Testing
import ViewModels

/// File scope, not suite statics: a static on a `@MainActor` type is MainActor
/// isolated, and ``StubFolderTree`` reads these from a nonisolated context.
private enum TreePath {
    static let root = "/Music/Shared"
    static let child = "/Music/Shared/Live Sets"
    static let grandchild = "/Music/Shared/Live Sets/1998"
}

@MainActor
@Suite("Folder tree render state")
struct FolderTreeRenderStateTests {
    private static let root = TreePath.root
    private static let child = TreePath.child
    private static let grandchild = TreePath.grandchild

    @Test("a collapsed tree exposes roots only")
    func collapsedTreeHasNoChildren() async {
        let model = Self.model()
        await model.refresh(roots: [URL(fileURLWithPath: Self.root)])

        let state = FolderTreeRenderState(model: model)
        #expect(state.isFiltering == false)
        #expect(state.children(of: Self.root).isEmpty)
        #expect(state.isExpanded(Self.root) == false)
    }

    @Test("expanding a folder publishes its children and reports it expanded")
    func expansionPublishesChildren() async {
        let model = Self.model()
        await model.refresh(roots: [URL(fileURLWithPath: Self.root)])
        await model.expand(Self.root)

        let state = FolderTreeRenderState(model: model)
        #expect(state.children(of: Self.root).map(\.path) == [Self.child])
        #expect(state.isExpanded(Self.root))
        #expect(state.isExpanded(Self.child) == false)
    }

    /// The children cache is `@ObservationIgnored`, so the render state must be
    /// derivable from `visibleNodes` alone — a level that loaded has to appear here
    /// or the disclosure group renders an empty body forever.
    @Test("a nested level appears under its own parent, not the root")
    func nestedLevelIsKeyedByItsParent() async {
        let model = Self.model()
        await model.refresh(roots: [URL(fileURLWithPath: Self.root)])
        await model.expand(Self.root)
        await model.expand(Self.child)

        let state = FolderTreeRenderState(model: model)
        #expect(state.children(of: Self.root).map(\.path) == [Self.child])
        #expect(state.children(of: Self.child).map(\.path) == [Self.grandchild])
    }

    @Test("an active filter switches to the flattened match rows")
    func filterFlattensMatches() async {
        let model = Self.model()
        await model.refresh(roots: [URL(fileURLWithPath: Self.root)])
        await model.setFilter("1998")

        let state = FolderTreeRenderState(model: model)
        #expect(state.isFiltering)
        #expect(state.filteredRows.map(\.path) == [Self.root, Self.child, Self.grandchild])
        #expect(state.filteredRows.map(\.depth) == [0, 1, 2])
    }

    @Test("clearing the filter restores the unfiltered tree")
    func clearingFilterRestoresTree() async {
        let model = Self.model()
        await model.refresh(roots: [URL(fileURLWithPath: Self.root)])
        await model.setFilter("1998")
        await model.setFilter("")

        let state = FolderTreeRenderState(model: model)
        #expect(state.isFiltering == false)
        #expect(state.filteredRows.isEmpty)
    }

    private static func model() -> FolderSidebarViewModel {
        FolderSidebarViewModel(repository: StubFolderTree())
    }
}

/// A three-level chain: root → "Live Sets" → "1998".
private struct StubFolderTree: FolderTreeReading {
    func rootSummary(rootPath _: String) throws -> RootTrackSummary {
        RootTrackSummary(total: 3, present: 3, missing: 0, externalOffline: 0)
    }

    func childFolders(profileId _: Int64, parentPath: String) throws -> [FolderChildSummary] {
        switch parentPath {
        case TreePath.root:
            [FolderChildSummary(name: "Live Sets", path: TreePath.child, trackCount: 2, hasChildren: true)]
        case TreePath.child:
            [FolderChildSummary(name: "1998", path: TreePath.grandchild, trackCount: 1, hasChildren: false)]
        default:
            []
        }
    }

    func hasSubfolders(profileId: Int64, rootPath: String) throws -> Bool {
        try !childFolders(profileId: profileId, parentPath: rootPath).isEmpty
    }
}
