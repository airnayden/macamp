import Foundation
@testable import MacAMP
import Services
import Testing
import ViewModels

/// File scope, not suite statics: a static on a `@MainActor` type is MainActor
/// isolated and cannot be read from a nonisolated context.
private enum ImportFixture {
    static let path = "/Music/Shared/Live Sets"
    static let summary = ScanSummary(added: 4, updated: 0, skipped: 0, failed: 0)

    static func chunk(processed: Int, total: Int, currentPath: String? = path) -> ScanEvent {
        .progress(ScanProgress(processed: processed, total: total, currentPath: currentPath))
    }
}

@MainActor
@Suite("Sidebar import progress")
struct SidebarImportProgressTests {
    @Test("an idle model renders no strip")
    func idleModelIsHidden() {
        let state = SidebarImportProgressState(model: ImportProgressModel())

        #expect(state.isVisible == false)
        #expect(state.processed == 0)
        #expect(state.total == 0)
        #expect(state.fraction == 0)
        #expect(state.folderName == nil)
    }

    @Test("a chunk with real work flips the strip visible and carries the tally")
    func importingModelIsVisible() async {
        let model = ImportProgressModel()

        await model.apply(ImportFixture.chunk(processed: 3, total: 10))

        let state = SidebarImportProgressState(model: model)
        #expect(state.isVisible)
        #expect(state.processed == 3)
        #expect(state.total == 10)
        #expect(state.fraction == 0.3)
        #expect(state.folderName == "Live Sets")
    }

    @Test("a zero-work watcher rescan never shows the strip")
    func zeroWorkRescanStaysHidden() async {
        let model = ImportProgressModel()

        await model.apply(ImportFixture.chunk(processed: 0, total: 0, currentPath: nil))

        #expect(SidebarImportProgressState(model: model).isVisible == false)
    }

    @Test("a chunk without a current path still renders, with no folder name")
    func nilCurrentPathIsTolerated() async {
        let model = ImportProgressModel()

        await model.apply(ImportFixture.chunk(processed: 1, total: 4, currentPath: nil))

        let state = SidebarImportProgressState(model: model)
        #expect(state.isVisible)
        #expect(state.folderName == nil)
        #expect(state.processed == 1)
        #expect(state.total == 4)
    }

    @Test("the strip's fraction tracks the model's own")
    func fractionMatchesTheModel() async {
        let model = ImportProgressModel()

        await model.apply(ImportFixture.chunk(processed: 7, total: 9))

        #expect(SidebarImportProgressState(model: model).fraction == model.fraction)
    }

    @Test("finishing the import hides the strip again")
    func finishedImportHidesTheStrip() async {
        let model = ImportProgressModel()
        await model.apply(ImportFixture.chunk(processed: 4, total: 4))
        #expect(SidebarImportProgressState(model: model).isVisible)

        await model.apply(.finished(ImportFixture.summary))

        let state = SidebarImportProgressState(model: model)
        #expect(state.isVisible == false)
        #expect(state.folderName == nil)
    }

    @Test("an empty current path yields no folder name")
    func emptyCurrentPathYieldsNoFolderName() {
        let state = SidebarImportProgressState(isImporting: true, processed: 1, total: 2, currentPath: "")

        #expect(state.isVisible)
        #expect(state.folderName == nil)
    }

    @Test("the caption resolves the localized tally")
    func captionResolvesTheTally() {
        let caption = String(localized: SidebarImportProgressStrings.caption(processed: 3, total: 10))

        #expect(caption == "Importing 3 of 10")
    }
}
