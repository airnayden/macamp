// ProfileArchivePanels — AppKit open/save panels for `.macampprofile` files.
//
// Mirrors `PlaylistFilePanels`: the macOS shell may import AppKit, PlayerCore may
// not, so the panels live here while the gathering, encoding and off-main IO stay in
// `ProfileArchiveExporter` / `ProfileArchiveImporter`.
import AppKit
import Persistence
import UniformTypeIdentifiers

enum ProfileArchivePanels {
    /// A dynamic UTI for the archive's extension. `.macampprofile` is not a
    /// registered system type, so the filter is derived from the extension rather
    /// than looked up; when the system cannot mint one the panel simply shows
    /// everything instead of showing nothing.
    private static let archiveContentType = UTType(
        filenameExtension: ProfileArchive.fileExtension,
        conformingTo: .json
    )

    @MainActor
    static func chooseImportFile() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let archiveContentType {
            panel.allowedContentTypes = [archiveContentType]
        }
        return panel.runModal() == .OK ? panel.url : nil
    }

    @MainActor
    static func chooseExportDestination(suggestedFileName: String) -> URL? {
        #if DEBUG
            if let scripted = uiTestExportDestination(suggestedFileName) { return scripted }
        #endif
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFileName
        if let archiveContentType {
            panel.allowedContentTypes = [archiveContentType]
        }
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    #if DEBUG
        /// XCUITest cannot drive a modal `NSSavePanel`, so a UI test names the
        /// destination directory instead. Mirrors the `UITEST_SEED_PATH` seam in
        /// `AppEnvironment+UITesting` and is compiled out of Release entirely.
        private static func uiTestExportDestination(_ fileName: String) -> URL? {
            guard let directory = ProcessInfo.processInfo.environment["UITEST_ARCHIVE_EXPORT_DIR"] else {
                return nil
            }
            try? FileManager.default.createDirectory(
                atPath: directory,
                withIntermediateDirectories: true
            )
            return URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(fileName)
        }
    #endif
}
