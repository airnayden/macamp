// ChatDownloadImportGate — whether a finished chat-initiated download may be scanned.
//
// A download the assistant started is meant to end up in a playlist, which means it
// has to be a library row first. But the destination folder is deliberately NOT a
// library root (nothing watches it, no `libraryRoot` row names it), so "did this file
// become visible?" has exactly two honest answers:
//
//   1. auto-import is on — `DownloadLibraryImporter` scans every finished download, so
//      this one is already on its way in, and
//   2. auto-import is off, but the listener pointed a library root at the folder the
//      file landed in — so the folder IS watched and the file belongs in the library
//      by the listener's own earlier decision.
//
// Anything else is a refusal. A scan outside those two cases would be MacAMP importing
// a file into a library the listener never asked to grow, which is the silent-import
// failure the downloads surface was built to avoid.
//
// ── WHY THIS IS A SEPARATE TYPE ──────────────────────────────────────────────
//
// The decision is spelled out here, away from the `AppEnvironment` closure that will
// consume it, for the reason `DownloadLibraryImporter` gives in its own header: the
// wiring lives in the macOS shell, which `swift test` cannot reach. A `guard` inside
// that closure would be a policy no package test could drive. As a pure function over
// three plain values it is exhaustively table-testable, and the path arithmetic that
// makes it subtle — sibling-name prefixes, trailing slashes, `/var` vs `/private/var`
// — is asserted rather than assumed.
//
// ── THE DELIBERATE ASYMMETRY ─────────────────────────────────────────────────
//
// Standardization (`standardizedFileURL`, then `resolvingSymlinksInPath()`) happens
// ONLY inside this gate, on copies it makes itself. Callers pass their URLs verbatim
// and keep using their own verbatim values afterwards: the URL handed to
// `LibraryScanner.scan(.files([url]))` and the `filePath` later looked up must stay
// byte-identical to the path the download callback reported, because that string is
// the scanner's unique key. Resolving it on the way in would file the row under
// `/private/var/…` and then fail to find it under `/var/…`. Comparing needs canonical
// paths; storing needs the original. This function is the only place the first is
// true, and it never hands a standardized URL back to anyone.
import Foundation

/// Decides whether a finished download is eligible to be scanned into the library.
public enum ChatDownloadImportGate {
    /// `true` when this file may be imported: auto-import is on, or the file sits at
    /// or below one of `libraryRoots`.
    ///
    /// The containment test compares **path components**, never string prefixes, so
    /// `/Users/t/Music` does not contain `/Users/t/MusicLibrary/a.m4a` — a plain
    /// `String.hasPrefix` says it does, and the resulting import writes a row for a
    /// folder the listener never added. A file whose parent directory IS the root
    /// matches by the same rule (its components simply start with the root's), as does
    /// a URL naming the root directory itself.
    ///
    /// Both sides are standardized before comparison, which absorbs trailing slashes,
    /// `.`/`..` segments, and macOS's `/var` → `/private/var` symlink — a root recorded
    /// through a file picker and a path reported by the download engine are not
    /// required to spell the same directory the same way.
    ///
    /// A root of `/` is not special-cased: it genuinely contains every absolute path,
    /// so it matches everything. Adding `/` as a library root is a request for that.
    ///
    /// - Parameters:
    ///   - autoImportEnabled: the live read of the listener's auto-import switch.
    ///   - fileURL: the finished file, passed verbatim (see the asymmetry note above).
    ///   - libraryRoots: the active profile's roots, passed verbatim.
    public static func isEligible(autoImportEnabled: Bool, fileURL: URL, libraryRoots: [URL]) -> Bool {
        if autoImportEnabled { return true }
        let fileComponents = canonicalComponents(of: fileURL)
        return libraryRoots.contains { root in
            let rootComponents = canonicalComponents(of: root)
            guard rootComponents.count <= fileComponents.count else { return false }
            return Array(fileComponents.prefix(rootComponents.count)) == rootComponents
        }
    }

    /// The URL's path split into comparable components, with lexical noise and symlinks
    /// resolved away. This is the ONLY normalization in the file, and its result never
    /// escapes this type.
    private static func canonicalComponents(of url: URL) -> [String] {
        url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
    }
}
