// PlaylistFilePanels — AppKit open/save panels for playlist files.
//
// The macOS shell may import AppKit; PlayerCore may not, so the panels live in the
// app target while the format work + off-actor IO stay in
// `PlaylistImportExportViewModel`.
import AppKit
import Persistence
import UniformTypeIdentifiers
import ViewModels

enum PlaylistFilePanels {
    private static let importContentTypes: [UTType] = {
        let byExtension = ["m3u", "m3u8", "pls", "jspf"].compactMap { UTType(filenameExtension: $0) }
        return byExtension + [.json, .plainText]
    }()

    @MainActor
    static func chooseImportFile() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = importContentTypes
        return panel.runModal() == .OK ? panel.url : nil
    }

    @MainActor
    static func chooseExportDestination(suggestedName: String, format: PlaylistFormat) -> URL? {
        let panel = NSSavePanel()
        let ext = PlaylistImportExportViewModel.fileExtension(for: format)
        panel.nameFieldStringValue = "\(suggestedName).\(ext)"
        if let type = UTType(filenameExtension: ext) {
            panel.allowedContentTypes = [type]
        }
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}
