// TagWriteSupport — the macOS-specific seams the tag editor needs around the
// PlayerCore writer.
//
// macOS's MacAMP build is NOT sandboxed (see `LibraryRootsStore` / the project
// issues log: direct distribution, App Group only), so — unlike iOS — there is no
// security-scoped bookmark to resolve before a write. A file is writable iff the
// filesystem says so AND the format can carry tags. ``MacWritableProbe`` answers
// exactly that, mirroring ``SFBMetadataWriter``'s own preflight so the editor's
// Save button reflects what the writer would actually do.
//
// This file also supplies the small UI seams: the `.sheet(item:)` request
// wrapper, the pure rule that turns the pressed selection into the records to
// edit, an image-bytes MIME sniffer, and the AppKit open panel for "Replace…".
// AppKit lives in the app target (never PlayerCore).
import AppKit
import Foundation
import Metadata
import Persistence
import UniformTypeIdentifiers

// MARK: - Writability probe

/// Answers whether a track file can be tag-written on macOS — the editor's
/// read-only gate. Mirrors ``SFBMetadataWriter`` preflight order (exists →
/// writable format → writable file) so the UI never offers Save for a file the
/// writer would reject, and never blocks a file it would accept.
enum MacWritableProbe {
    /// `true` when the file exists, its extension is in the writer's allow-list,
    /// and the filesystem reports it writable. Pure filesystem I/O — callers run
    /// it off the main actor.
    static func isWritable(filePath: String) -> Bool {
        let url = URL(fileURLWithPath: filePath)
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return false
        }
        guard SFBMetadataWriter.writableExtensions.contains(url.pathExtension.lowercased()) else {
            return false
        }
        return manager.isWritableFile(atPath: url.path)
    }
}

// MARK: - Editor request

/// A request to open ``TagEditorSheet`` for a concrete set of records, shaped for
/// `.sheet(item:)` (`TrackRecord` is not itself `Identifiable`).
struct TagEditorRequest: Identifiable {
    let id = UUID()
    let records: [TrackRecord]
}

// MARK: - Artwork MIME sniffing

/// Detects an image MIME type from leading magic bytes (mirrors the reader's
/// sniffer) so dropped / picked bytes carry a correct type into the tag.
enum ArtworkMIME {
    static func sniff(_ data: Data) -> String? {
        let prefix = [UInt8](data.prefix(4))
        if prefix.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if prefix.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if prefix.starts(with: [0x47, 0x49, 0x46]) { return "image/gif" }
        return nil
    }

    static func isImage(_ data: Data) -> Bool {
        sniff(data) != nil
    }
}

// MARK: - Image picker (AppKit)

/// The AppKit open panel for the "Replace…" artwork flow. macOS has no
/// `PhotosPicker`; the shell may import AppKit while PlayerCore may not, so the
/// panel lives here in the app target.
enum TagArtworkPanel {
    /// Presents an image open panel and returns the picked file's bytes, or `nil`
    /// if cancelled or unreadable.
    @MainActor
    static func chooseImageData() -> Data? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return try? Data(contentsOf: url)
    }
}
