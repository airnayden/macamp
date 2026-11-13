// InstrumentalCacheLocation — the single source of truth for where rendered
// karaoke instrumentals are cached on disk.
//
// The karaoke feature pre-renders each track's instrumental stem and caches it as
// an `.m4a` under `Application Support/MacAMP/Instrumentals/`. Two subsystems must
// agree on that exact path and must NOT drift:
//
//   * `Separation.InstrumentalCache` (the actor that reads/writes the cache) uses
//     it as its default directory.
//   * `Services.LibraryScanner` is handed it as an excluded directory so the scan
//     never re-imports the app's own generated instrumental files, and
//     `LibraryAccessController` rejects it (and its parents) as a library root.
//
// It lives in `Models` — the lowest shared layer both `Services` and `Separation`
// depend on — so both reference ONE definition instead of recomputing the literal.
// Foundation only (no AppKit/UIKit — PlayerCore portability invariant).
import Foundation

/// The canonical on-disk location of the rendered-instrumental cache.
///
/// Resolve the directory through this type rather than re-deriving
/// `Application Support/MacAMP/Instrumentals/` at each call site, so the cache
/// writer, the scanner's exclusion, and the library-root guard can never disagree.
public enum InstrumentalCacheLocation {
    /// The cache directory's path relative to the Application Support container.
    public static let applicationSupportSubpath = "MacAMP/Instrumentals"

    /// The instrumental cache directory inside a given Application Support directory.
    ///
    /// Injectable form: pass a test-scoped Application Support URL to relocate the
    /// cache without touching the real container.
    public static func directory(inApplicationSupport applicationSupport: URL) -> URL {
        applicationSupport
            .appendingPathComponent("MacAMP", isDirectory: true)
            .appendingPathComponent("Instrumentals", isDirectory: true)
    }

    /// The default instrumental cache directory
    /// (`~/Library/Application Support/MacAMP/Instrumentals/`), or `nil` when the
    /// Application Support container cannot be located.
    ///
    /// Does not create the directory (`create: false`) — resolution only. Callers
    /// that need it to exist create it lazily on first write.
    public static func defaultDirectory(fileManager: FileManager = .default) -> URL? {
        guard let base = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else {
            return nil
        }
        return directory(inApplicationSupport: base)
    }
}
