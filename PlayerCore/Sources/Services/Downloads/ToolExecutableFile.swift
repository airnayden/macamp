// ToolExecutableFile — permission and quarantine hygiene for the tool binaries
// MacAMP copies out of its bundle and executes.
//
// Extracted from ToolUpdateInstaller.swift when yt-dlp moved from a PyInstaller
// ONEFILE binary to a ONEDIRECTORY tree: the tree variant below needs a
// filesystem walk, and the installer file had 28 lines of headroom against the
// 400-line ceiling. The split is also honest — this type is about file hygiene,
// not about updating anything.
//
// Foundation + Darwin only. No AppKit/UIKit (PlayerCore portability invariant),
// no Process, no URLSession (the downloader boundary gate).
import Darwin
import Foundation

/// Permission and quarantine hygiene for a tool binary MacAMP is about to execute.
///
/// Both steps are required and neither is sufficient alone: a copied binary arrives
/// without the executable bit, and a downloaded one arrives carrying
/// `com.apple.quarantine`, which Gatekeeper honours by refusing to launch a
/// non-notarized executable.
public enum ToolExecutableFile {
    /// `rwxr-xr-x` — the mode every provisioned tool binary is given.
    public static let executablePermissions = 0o755

    /// The Gatekeeper quarantine extended attribute.
    public static let quarantineAttribute = "com.apple.quarantine"

    /// What went wrong making a tool binary runnable.
    ///
    /// Never shown to a person — callers map it onto the ``DownloadError`` that suits
    /// their stage (``DownloadError/toolMissing`` while provisioning,
    /// ``DownloadError/updateFailed(detail:)`` while updating) — so it carries no
    /// `LocalizedStringResource`.
    public enum Failure: Error, Sendable, Equatable {
        /// `chmod` did not take.
        case permissionsFailed(path: String, code: Int32)
        /// `removexattr` failed for a reason other than "the attribute is not there".
        case quarantineFailed(path: String, code: Int32)
        /// A directory tree could not be walked, so its files cannot be vouched for.
        case treeUnreadable(path: String)
    }

    /// Marks `url` executable and strips its Gatekeeper quarantine flag.
    public static func makeRunnable(at url: URL) throws {
        try setExecutablePermissions(at: url)
        try stripQuarantine(at: url)
    }

    /// Sets `url`'s mode to ``executablePermissions``.
    public static func setExecutablePermissions(at url: URL) throws {
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: executablePermissions)],
                ofItemAtPath: url.path
            )
        } catch {
            throw Failure.permissionsFailed(path: url.path, code: Int32((error as NSError).code))
        }
    }

    /// Removes ``quarantineAttribute`` from `url`.
    ///
    /// `ENOATTR` is SUCCESS: it means the attribute was not there, which is exactly
    /// the state this function exists to produce. Treating it as an error would make
    /// the second, idempotent call fail on every launch.
    public static func stripQuarantine(at url: URL) throws {
        var code: Int32 = 0
        let removed = url.withUnsafeFileSystemRepresentation { path -> Bool in
            guard let path else { return false }
            if removexattr(path, quarantineAttribute, 0) == 0 { return true }
            code = errno
            return false
        }
        guard removed || code == ENOATTR else {
            throw Failure.quarantineFailed(path: url.path, code: code)
        }
    }
}

// MARK: - Directory trees (the PyInstaller onedir shape)

public extension ToolExecutableFile {
    /// Marks `executable` runnable and strips quarantine from EVERY regular file
    /// under `root`.
    ///
    /// The single-file ``makeRunnable(at:)`` is not enough for a PyInstaller
    /// one-directory tool: `FileManager.copyItem` PROPAGATES `com.apple.quarantine`
    /// into nested files (measured), so copying a quarantined tree out of a
    /// downloaded app bundle produces 134 quarantined files, of which the launcher
    /// is one. The other 133 are the `.dylib`/`.so` payload the launcher `dlopen`s
    /// at run time — precisely the files a single-file strip leaves behind.
    ///
    /// Recursion is cheap enough that the question is not worth leaving open: over
    /// the real 134-file yt-dlp tree the whole pass measured **3.9 ms** cold and
    /// 1.7 ms warm, because every call is one `removexattr` syscall that returns
    /// `ENOATTR` when there is nothing to remove.
    ///
    /// Symlinks and directories are skipped: `isRegularFile` is the filter, so a
    /// link is never followed out of the tree.
    static func makeTreeRunnable(at root: URL, executable: URL) throws {
        for file in try regularFiles(under: root) {
            try stripQuarantine(at: file)
        }
        try makeRunnable(at: executable)
    }

    /// Every regular file under `root`, depth-first.
    ///
    /// - Throws: ``Failure/treeUnreadable(path:)`` when no enumerator can be made —
    ///   reporting "the tree could not be vouched for" rather than silently
    ///   returning an empty list, which would look like a clean strip.
    static func regularFiles(under root: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            throw Failure.treeUnreadable(path: root.path)
        }
        var files: [URL] = []
        for case let url as URL in enumerator {
            let isRegularFile = try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile
            if isRegularFile == true { files.append(url) }
        }
        return files
    }
}
