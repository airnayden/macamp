// WritableSource — iOS sandbox gating for tag writes.
//
// iOS is sandboxed: a file is only writable while the app holds security-scoped
// access to a folder the user explicitly granted through the import picker. Those
// grants are persisted as security-scoped bookmarks (see
// `SecurityScopedBookmarks.swift`) and re-resolved to live root URLs on launch.
//
// A track is therefore writable IFF its file lives under one of those resolved
// roots. This type answers exactly that question — the gate the tag editor checks
// before enabling its Save button — and returns the covering ``rootURL`` the
// caller must `startAccessingSecurityScopedResource()` on while it reads and
// writes the file (the balanced helpers live in `BookmarkLifecycle.swift`).
//
// Pure path arithmetic over the resolved roots; the only I/O is the one-shot
// ``resolveRoots(database:)`` (a DB read + bookmark resolution) which callers run
// off the main actor. AppKit/UIKit-free.
import Foundation
import Persistence

/// A track file paired with the security-scoped root that grants write access.
struct WritableSource: Equatable {
    /// The file to read/write.
    var trackURL: URL
    /// The granted root to hold scoped access on while reading/writing the file.
    var rootURL: URL
}

/// Resolves whether a track file is writable on iOS and, if so, under which root.
enum WritableSourceResolver {
    /// Resolves every persisted import root to a live URL (off-main I/O: a GRDB
    /// read plus bookmark resolution, re-minting stale bookmarks transparently).
    static func resolveRoots(database: AppDatabase) -> [URL] {
        let manager = SecurityScopedBookmarkManager(store: GRDBBookmarkStore(database: database))
        return manager.resolveRoots().map(\.url)
    }

    /// Returns the ``WritableSource`` for `path` when it lives under one of
    /// `roots`, else `nil` (a read-only source). Paths are normalised (symlinks
    /// resolved, `.`/`..` collapsed) so `/private`-prefixed roots match.
    static func writableSource(forFilePath path: String, roots: [URL]) -> WritableSource? {
        let fileURL = URL(fileURLWithPath: path)
        let normalizedFile = normalize(fileURL)
        for root in roots where contains(root: normalize(root), file: normalizedFile) {
            return WritableSource(trackURL: fileURL, rootURL: root)
        }
        return nil
    }

    /// Convenience predicate: does `path` have an active writable bookmark?
    static func hasActiveBookmark(forFilePath path: String, roots: [URL]) -> Bool {
        writableSource(forFilePath: path, roots: roots) != nil
    }

    private static func normalize(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// `true` when `file` equals `root` (a file bookmark) or sits beneath it (a
    /// folder bookmark). Compared on a trailing-slash boundary so `/Music` never
    /// matches `/MusicArchive`.
    private static func contains(root: String, file: String) -> Bool {
        if file == root { return true }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return file.hasPrefix(prefix)
    }
}
