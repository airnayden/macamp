// CacheDirectoryOverlapPolicy — pure rules for whether the karaoke instrumental
// cache directory may sit at a given location relative to the library's roots.
//
// The instrumental cache is a GLOBAL directory (one per install) while library
// roots are PER-PROFILE. Two things must never happen:
//   * the cache landing inside (or equal to) a music-library root — the scan would
//     re-import the app's own rendered `.m4a` instrumentals as tracks; or
//   * the cache CONTAINING a music-library root — moving/pruning the cache tree
//     could then touch the user's music.
// So the shell rejects a chosen cache directory that overlaps ANY profile's roots
// (not just the active profile's — an inactive profile's root would otherwise be
// covered after a profile switch), and rejects a chosen library root that overlaps
// the current cache directory.
//
// These are pure, Foundation-only functions so both the shell rejection paths and
// the `LibraryScanner` exclusion share ONE definition of "overlap", using the exact
// standardized-path prefix semantics `LibraryScanner.isExcluded` uses. Lives in
// `Models` — the lowest shared layer — and MUST NOT import AppKit/UIKit (PlayerCore
// portability invariant).
import Foundation

/// How a candidate cache directory overlaps one of the library's roots.
public enum CacheDirectoryOverlap: Sendable, Equatable {
    /// The cache directory is equal to, or nested inside, `root`.
    case insideRoot(URL)
    /// The cache directory is an ancestor of (contains) `root`.
    case containsRoot(URL)
}

/// Pure overlap + system-location rules for the global instrumental cache directory.
public enum CacheDirectoryOverlapPolicy {
    /// Whether `cacheDirectory` overlaps any of `roots`, and how.
    ///
    /// Returns the FIRST overlapping root found (order follows `roots`), or `nil`
    /// when the cache directory is disjoint from every root. Comparison standardizes
    /// both paths and matches on directory-prefix boundaries (`==` or a `"/"`-anchored
    /// prefix) — the SAME semantics `LibraryScanner` uses to decide exclusion, so the
    /// scanner and this guard can never disagree.
    ///
    /// `roots` is taken as a flat list precisely so a caller can pass EVERY profile's
    /// roots at once: the cache directory is global, so an inactive profile's root
    /// still counts.
    public static func overlap(cacheDirectory: URL, roots: [URL]) -> CacheDirectoryOverlap? {
        let cachePath = cacheDirectory.standardizedFileURL.path
        for root in roots {
            let rootPath = root.standardizedFileURL.path
            if cachePath == rootPath || cachePath.hasPrefix(rootPath + "/") {
                return .insideRoot(root)
            }
            if rootPath.hasPrefix(cachePath + "/") {
                return .containsRoot(root)
            }
        }
        return nil
    }

    /// Whether `url` is equal to, or nested inside, the app's own Application Support
    /// or Caches containers — the two locations a library root must never be, because
    /// they house the app's generated files (the default instrumental cache and the
    /// GRDB store). Standardized-path prefix semantics, matching ``overlap(cacheDirectory:roots:)``.
    public static func isSystemInternalLocation(_ url: URL, fileManager: FileManager = .default) -> Bool {
        let path = url.standardizedFileURL.path
        let containers: [FileManager.SearchPathDirectory] = [.applicationSupportDirectory, .cachesDirectory]
        let containerPaths = containers.flatMap { directory in
            fileManager.urls(for: directory, in: .userDomainMask).map(\.standardizedFileURL.path)
        }
        return containerPaths.contains { path == $0 || path.hasPrefix($0 + "/") }
    }
}
