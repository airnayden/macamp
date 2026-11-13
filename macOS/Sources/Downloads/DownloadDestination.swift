// DownloadDestination — where finished downloads land, whether the app can write
// there, and which download directories a library scan must never walk.
//
// ── THE APP PROBES, NEVER THE CHILD ──────────────────────────────────────────
//
// macOS gates `~/Music`, `~/Downloads`, `~/Desktop`, `~/Documents` and every external
// volume behind TCC, and a TCC prompt is raised for the process that touches the path
// — attributed to its code signature. A yt-dlp child cannot raise one: it is not the
// app, it has no UI, and a denial reaches it as a bare `EPERM` in the middle of a
// transfer. So MacAMP writes and deletes its OWN probe file in the destination BEFORE
// any engine handoff. That is the write that prompts, the answer the listener gives is
// remembered against MacAMP's identity, and a refusal becomes
// ``DownloadError/destinationUnavailable`` before a byte is fetched.
//
// ── THE DESTINATION IS NOT A LIBRARY ROOT ────────────────────────────────────
//
// Nothing here registers a library root and no watcher is attached. A finished file is
// imported by ONE explicit `LibraryScanner.scan(.files([url]))` from the composition
// root's `onItemFinished` seam, and it stays visible to every profile because it sits
// under no profile's root at all (`LibraryVisibility`'s ownerless clause). Changing
// the destination therefore needs no bookkeeping: new items land in the new folder and
// the old folder is left exactly as it is.
//
// ── WHAT IS EXCLUDED, AND WHAT DELIBERATELY IS NOT ───────────────────────────
//
// ``DownloadScanExclusions`` names the two APP-PRIVATE download directories — the
// yt-dlp staging directory (`-P temp:`) and the copied-out tools directory — so no
// scan can ever import a half-written `.part`, a `*.temp.m4a`, or a vendored binary.
// The DESTINATION is not excluded: importing what lands there is the whole point.
//
// Pure `Foundation`: no `Process`, no `URLSession`, no AppKit — so every decision here
// is drivable from a test with a scratch directory.
import Foundation
import Services

/// The canonical on-disk location of the downloads destination folder.
///
/// Mirrors ``DownloadStagingLocation`` (`Services`) and `InstrumentalCacheLocation`
/// (`Models`), which own the same problem for the staging and karaoke-cache
/// directories: resolve the folder through this type rather than re-deriving
/// `~/Music/MacAMP Downloads` at each call site, so the yt-dlp `-o` argument, the
/// writability probe, and the preferences pane can never disagree.
enum DownloadDestinationLocation {
    /// The folder name created inside the user's Music directory.
    ///
    /// A DISPLAY-BEARING PATH COMPONENT, deliberately not localized: it is a directory
    /// on the listener's disk that a stored `destinationPath` may already point at, so
    /// translating it would strand every existing download behind a folder that no
    /// longer resolves. Same stance as the never-localized MacAMP brand.
    static let folderName = "MacAMP Downloads"

    /// The default destination (`~/Music/MacAMP Downloads`).
    ///
    /// Resolution only — the directory is created on first use by
    /// ``DownloadDestinationProbe/isWritable(_:fileManager:)``, so a launch that never
    /// downloads anything leaves no folder behind. Falls back to the home directory
    /// when `.musicDirectory` cannot be resolved, which keeps the return
    /// non-optional: a queue with no destination at all could not report
    /// ``DownloadError/destinationUnavailable`` for a folder, only crash.
    static func defaultDirectory(fileManager: FileManager = .default) -> URL {
        let music = (
            try? fileManager.url(for: .musicDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        ) ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Music", isDirectory: true)
        return music.appendingPathComponent(folderName, isDirectory: true)
    }

    /// The configured destination, or the default when nothing is configured.
    ///
    /// A plain filesystem path, never a security-scoped bookmark — the macOS shell is
    /// non-sandboxed, matching `AppSettings.karaokeCacheDirectoryPath`.
    static func resolve(configuredPath: String?, fileManager: FileManager = .default) -> URL {
        guard let configuredPath, !configuredPath.isEmpty else {
            return defaultDirectory(fileManager: fileManager)
        }
        return URL(fileURLWithPath: configuredPath, isDirectory: true)
    }
}

/// Proves — by writing — that MacAMP itself can create files in a directory.
enum DownloadDestinationProbe {
    /// The probe file's name prefix. A dotfile with no audio extension, so even a
    /// probe leaked by a failed delete is invisible to ``LibraryScanner``'s walk.
    static let fileNamePrefix = ".macamp-write-probe-"

    /// Creates `directory` if needed, then writes and deletes a probe file in it.
    ///
    /// This is the call that raises a TCC prompt (see the file header) and the reason
    /// the destination check cannot be delegated to the engine. It is also why the
    /// probe is a real write rather than `FileManager.isWritableFile(atPath:)`: that
    /// API answers from the POSIX mode bits alone and reports `true` for a TCC-denied
    /// folder the app cannot actually write to.
    ///
    /// - Returns: `true` when a file was created. A directory that cannot be created,
    ///   or a write that fails, answers `false`; a probe that was written but could
    ///   not be deleted still answers `true` — writability is proven either way, and
    ///   reporting the destination unusable over a stray dotfile would be the worse
    ///   mistake.
    static func isWritable(_ directory: URL, fileManager: FileManager = .default) -> Bool {
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return false
        }
        let probe = directory.appendingPathComponent(fileNamePrefix + UUID().uuidString)
        do {
            try Data().write(to: probe)
        } catch {
            return false
        }
        try? fileManager.removeItem(at: probe)
        return true
    }
}

/// The two app-private download directories: where intermediates are written, and
/// where the copied-out tools are run from.
///
/// Both are resolved HERE and handed to everything that needs them — the yt-dlp
/// `-P temp:` argument, ``DownloadToolManager``'s `toolsDirectory`, and
/// ``LibraryScanner``'s `excludedDirectories` provider. One resolution is what makes
/// ``excluded`` provably the same pair of paths the engine and the tool manager
/// actually use: a second derivation could drift, and a drifted exclusion means a
/// half-written `*.part` or a vendored binary silently entering the listener's library.
///
/// Neither path is user-relocatable, so they are a constant rather than a lock box the
/// way the (relocatable) karaoke cache directory is. If either ever becomes
/// configurable, this type is the seam that has to grow one.
///
/// A `nonisolated` top-level enum, so the `@Sendable` provider closure can read
/// ``excluded`` off the main actor during a scan.
enum DownloadPrivateDirectories {
    /// yt-dlp's `-P temp:` — partial files never touch the destination folder.
    static let staging: URL = resolve(
        DownloadStagingLocation.defaultDirectory(),
        fallbackSubpath: DownloadStagingLocation.applicationSupportSubpath
    )

    /// Where the seed binaries are copied out to and run from.
    ///
    /// Passed EXPLICITLY to ``DownloadToolManager`` rather than left to its own default,
    /// which applies the identical Application-Support-then-temporary fallback: sharing
    /// one value means the exclusion below cannot name a directory the manager is not
    /// using.
    static let tools: URL = resolve(
        DownloadToolsLocation.defaultDirectory(),
        fallbackSubpath: DownloadToolsLocation.applicationSupportSubpath
    )

    /// The directories a library scan must never descend into.
    ///
    /// The DESTINATION is deliberately absent — importing what lands there is the whole
    /// point of the feature (see the file header).
    static let excluded: [URL] = [staging, tools]

    /// `resolved`, or the same subpath under the temporary directory when Application
    /// Support cannot be located at all — mirroring ``DownloadToolManager``'s own
    /// fallback, so a machine in that state still downloads into a private directory
    /// rather than into the listener's music folder.
    private static func resolve(_ resolved: URL?, fallbackSubpath: String) -> URL {
        resolved ?? FileManager.default.temporaryDirectory
            .appendingPathComponent(fallbackSubpath, isDirectory: true)
    }
}
