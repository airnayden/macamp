// CanonicalSourcePath — the ONE realpath-based spelling normalizer shared by every
// consumer that has to match a path against a stored instrumental `sourcePath`.
//
// The problem it solves: a cache entry records the `sourcePath` the RENDER saw, while
// callers spell the same file however their own layer does — a GRDB `track.filePath`,
// a `URL` built from user input, a `/var/…` alias of a `/private/var/…` file. Comparing
// those spellings directly silently misses. Canonicalizing BOTH sides through this
// helper makes the comparison total.
//
// `KaraokeReadyStore` (module `ViewModels`) owned this logic first; it now lives here
// because `Separation` cannot import `ViewModels` (the dependency runs the other way)
// and `InstrumentalCache` needs the exact same normalization for
// ``InstrumentalCaching/remove(sourcePaths:)``. The store delegates here, so the two
// stay byte-identical by construction.
//
// Foundation + Darwin only — no AppKit/UIKit (PlayerCore portability invariant).
import Darwin
import Foundation

/// Canonicalizes file paths through the filesystem so different spellings of the same
/// file compare equal.
public enum CanonicalSourcePath {
    /// Canonicalizes a file URL through the filesystem so aliases such as `/var` and
    /// `/private/var` match repository paths. Missing suffixes retain that canonical base.
    ///
    /// A path that does not exist yet is still canonicalized as far as its deepest
    /// EXISTING ancestor, with the missing tail re-appended — so a not-yet-created file
    /// under `/var/folders/…` still normalizes onto `/private/var/folders/…`.
    public static func canonical(_ url: URL) -> String {
        var candidate = url.standardizedFileURL
        var missingComponents: [String] = []
        while true {
            if let resolvedPath = realPath(candidate.path) {
                let suffix = missingComponents.reversed().joined(separator: "/")
                return suffix.isEmpty
                    ? resolvedPath
                    : (resolvedPath as NSString).appendingPathComponent(suffix)
            }
            guard candidate.path != "/" else { return url.standardizedFileURL.path }
            missingComponents.append(candidate.lastPathComponent)
            candidate.deleteLastPathComponent()
        }
    }

    /// Canonicalizes a file-system path string the same way.
    public static func canonical(_ path: String) -> String {
        canonical(URL(fileURLWithPath: path))
    }

    private static func realPath(_ path: String) -> String? {
        path.withCString { pathPointer in
            guard let resolvedPointer = Darwin.realpath(pathPointer, nil) else { return nil }
            defer { free(resolvedPointer) }
            return String(cString: resolvedPointer)
        }
    }
}
