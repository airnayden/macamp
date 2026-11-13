// LibraryAccessSeams — the injectable side-effect boundaries the folder-access
// flow stands on, with both production (AppKit / FileManager) implementations and
// hermetic fakes.
//
// Splitting the open panel, readability probing, and the System-Settings launcher
// behind tiny protocols is what makes ``LibraryAccessController`` testable without
// a window server: a test injects fakes that return canned folders and statuses
// and record whether the recovery action fired.
import AppKit
import Foundation

// MARK: - FolderPicking

/// Presents a folder chooser and returns the selected folders (empty if
/// cancelled). `@MainActor` because the panel must run on the main thread.
public protocol FolderPicking: Sendable {
    @MainActor func pickFolders() async -> [URL]
}

/// Production ``FolderPicking`` over `NSOpenPanel` (directories, multi-select).
public struct NSOpenPanelFolderPicker: FolderPicking {
    public init() {}

    @MainActor
    public func pickFolders() async -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true
        guard panel.runModal() == .OK else { return [] }
        return panel.urls
    }
}

// MARK: - FileAccessProbing

/// Probes whether a folder is currently readable, without throwing or crashing.
public protocol FileAccessProbing: Sendable {
    func status(of url: URL) -> FolderAccessStatus
}

/// Production ``FileAccessProbing`` over `FileManager`. A missing path reads as
/// ``FolderAccessStatus/missing``; a present-but-unreadable path (TCC / perms)
/// reads as ``FolderAccessStatus/denied``; otherwise ``FolderAccessStatus/accessible``.
///
/// Stateless (no stored `FileManager`) so it stays `Sendable`.
public struct FileManagerAccessProbe: FileAccessProbing {
    public init() {}

    public func status(of url: URL) -> FolderAccessStatus {
        let path = url.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return .missing
        }
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: path)
            return .accessible
        } catch {
            return .denied
        }
    }
}

// MARK: - SystemSettingsOpening

/// Opens the System Settings pane where the user can grant folder access.
public protocol SystemSettingsOpening: Sendable {
    @MainActor func openFilesAndFoldersPrivacy()
}

/// Production ``SystemSettingsOpening`` that deep-links to Privacy ▸ Files and
/// Folders via the `x-apple.systempreferences:` URL scheme.
public struct SystemSettingsLauncher: SystemSettingsOpening {
    public init() {}

    @MainActor
    public func openFilesAndFoldersPrivacy() {
        let deepLink = "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders"
        guard let url = URL(string: deepLink) else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Fakes

/// A ``FolderPicking`` double returning a canned, settable folder list.
public final class FakeFolderPicker: FolderPicking, @unchecked Sendable {
    private let lock = NSLock()
    private var queued: [URL]

    public init(folders: [URL] = []) {
        queued = folders
    }

    public func setFolders(_ folders: [URL]) {
        lock.withLock { queued = folders }
    }

    @MainActor
    public func pickFolders() async -> [URL] {
        lock.withLock { queued }
    }
}

/// A ``FileAccessProbing`` double with a per-path status map and a fallback.
public final class FakeFileAccessProbe: FileAccessProbing, @unchecked Sendable {
    private let lock = NSLock()
    private var statuses: [String: FolderAccessStatus]
    private let fallback: FolderAccessStatus

    public init(default fallback: FolderAccessStatus = .accessible, statuses: [String: FolderAccessStatus] = [:]) {
        self.fallback = fallback
        self.statuses = statuses
    }

    public func setStatus(_ status: FolderAccessStatus, for url: URL) {
        lock.withLock { statuses[url.path] = status }
    }

    public func status(of url: URL) -> FolderAccessStatus {
        lock.withLock { statuses[url.path] ?? fallback }
    }
}

/// A ``SystemSettingsOpening`` double that records how often recovery fired.
public final class FakeSystemSettingsOpener: SystemSettingsOpening, @unchecked Sendable {
    private let lock = NSLock()
    private var opens = 0

    public init() {}

    @MainActor
    public func openFilesAndFoldersPrivacy() {
        lock.withLock { opens += 1 }
    }

    public var openCount: Int {
        lock.withLock { opens }
    }
}
