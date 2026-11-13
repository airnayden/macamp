// DownloadToolManager — the macOS shell's ``DownloadToolProviding``: it provisions the
// download tools out of the signed app bundle and self-updates yt-dlp beside them.
//
// ── THE BUNDLE IS READ-ONLY, ALWAYS ──────────────────────────────────────────
//
// The seed binaries ship inside `MacAMP.app` and are covered by its code signature.
// Writing to them would break that signature; EXECUTING them from there would mean the
// app runs a file it may later want to replace. So the bundle is only ever a SOURCE:
// every tool is copied out to `~/Library/Application Support/MacAMP/Tools/` and run
// from there, and the self-update rewrites only that copy.
//
// ── TWO BUNDLE LOCATIONS, TWO FOUNDATION LOOKUPS ─────────────────────────────
//
// ffmpeg and ffprobe are single Mach-O files staged by a Tuist
// `copyFiles(.executables)` phase, which resolves to `Contents/MacOS/` — so they are
// found with `Bundle.url(forAuxiliaryExecutable:)`, Foundation's exact API for that
// folder.
//
// yt-dlp is a PyInstaller ONE-DIRECTORY tree (a `yt-dlp_macos` launcher plus a
// sibling `_internal/` of 133 files) staged by a Tuist `.folderReference`, which
// lands in `Contents/Resources/` — so it is found with
// `Bundle.url(forResource:withExtension:)`, Foundation's exact API for THAT folder.
// The tree ships whole because the launcher resolves its Python shared library out
// of `_internal/` at run time; a flattened copy dies with
// `Failed to load Python shared library '…/_internal/Python'`.
//
// Neither literal path string appears in this file. Both are one expression each
// (``seedTreeURL`` and the `url(forAuxiliaryExecutable:)` call in ``provision(_:)``),
// so the bundle layout is stated once per location and nowhere else.
//
// ── WHY BOTH THE EXEC BIT AND THE QUARANTINE FLAG ────────────────────────────
//
// A copied file arrives without the executable bit, and a downloaded one arrives
// carrying `com.apple.quarantine`, which Gatekeeper honours by refusing to launch a
// non-notarized executable. Neither step is sufficient alone, so both run on every
// provisioned binary through ``ToolExecutableFile`` — including binaries that were
// already there, because a copy made by an older build may still be quarantined.
//
// For the tree that means EVERY file, not just the launcher:
// `FileManager.copyItem` propagates `com.apple.quarantine` into nested files
// (measured), so a copy made from a quarantined app bundle arrives with all 134
// files flagged, 102 of them the `.dylib`/`.so` payload the launcher `dlopen`s.
// ``ToolExecutableFile/makeTreeRunnable(at:executable:)`` covers the whole tree for
// 3.9 ms.
//
// ── PROCESS DISCIPLINE ───────────────────────────────────────────────────────
//
// This file NEVER constructs a `Process`. `--version`, `codesign -dv` and the ad-hoc
// re-sign all go through the injected ``ToolProcessRunning`` seam, whose only
// production conformer is `YtDlpProcessRunner` — the one file the downloader boundary
// guard exempts. Networking likewise goes through ``ToolReleaseFetching``.
import Foundation
import Services

/// The canonical on-disk location of the copied-out download tools.
///
/// Mirrors `DownloadStagingLocation` in `Services`, which owns the same problem for
/// the staging directory: resolve through this type rather than re-deriving
/// `Application Support/MacAMP/Tools/` at each call site.
enum DownloadToolsLocation {
    /// The tools directory's path relative to the Application Support container.
    static let applicationSupportSubpath = "MacAMP/Tools"

    /// The tools directory inside a given Application Support directory.
    static func directory(inApplicationSupport applicationSupport: URL) -> URL {
        applicationSupport
            .appendingPathComponent("MacAMP", isDirectory: true)
            .appendingPathComponent("Tools", isDirectory: true)
    }

    /// The default tools directory, or `nil` when Application Support cannot be located.
    ///
    /// Resolution only (`create: false`) — ``DownloadToolManager/prepare()`` creates it.
    static func defaultDirectory(fileManager: FileManager = .default) -> URL? {
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

/// Copy in, run from, and update the download tools in Application Support.
///
/// An `actor` rather than a lock-guarded class: `prepare()` and `applyUpdate()` both
/// mutate one directory, and the update in particular interleaves `await`s with file
/// moves, which is precisely the shape a lock cannot guard.
actor DownloadToolManager: DownloadToolProviding {
    /// The yt-dlp launcher's name — the same string inside the bundled tree, inside
    /// the installed tree, and in the release's `SHA2-256SUMS`.
    static let ytDlpExecutableName = "yt-dlp_macos"
    /// The directory that holds the launcher and its `_internal/` payload, both in
    /// the bundle's resources and in the tools directory.
    static let ytDlpTreeName = "yt-dlp"
    /// The release asset a self-update downloads: the ARCHIVE of the whole tree.
    ///
    /// The bare `yt-dlp_macos` onefile asset is published in the same release under a
    /// name that differs only by this suffix, and installing it succeeds — it just
    /// silently costs ~12 s on every engine spawn, for ever. Never spell this without
    /// the `.zip`.
    static let ytDlpArchiveName = "yt-dlp_macos.zip"
    /// The transcoder yt-dlp is pointed at with `--ffmpeg-location`.
    static let ffmpegExecutableName = "ffmpeg"
    /// ffmpeg's probe companion, which yt-dlp expects in the same directory.
    static let ffprobeExecutableName = "ffprobe"

    /// The single-file binaries provisioned out of the bundle, in copy order.
    ///
    /// yt-dlp is absent because it is a directory tree with its own provisioning path
    /// (``provisionYtDlpTree()``), not because it is not provisioned.
    ///
    /// Only yt-dlp is ever self-updated: ffmpeg rides app releases because it does not
    /// suffer YouTube's breakage cadence.
    static let seededBinaryNames = [
        ffmpegExecutableName,
        ffprobeExecutableName,
    ]

    /// Diagnostic recorded when an update is refused because a download is in flight.
    ///
    /// A DIAGNOSTIC, not user copy — the person-facing sentence is
    /// ``DownloadToolStrings/updateDeferredWhileDownloading``.
    static let deferredDetail = "a download is in flight; the engine is updated after downloads finish"
    /// Diagnostic recorded when a second update is requested while one is running.
    static let concurrentUpdateDetail = "an engine update is already running"

    /// Where the running copies live. Injectable so a test can point at a scratch tree.
    let toolsDirectory: URL

    /// `bundle` and `didPrepare` are internal, not private, because Swift scopes
    /// `private` to one file and the provisioning extension lives beside this one.
    /// Everything the provisioning path does not touch stays private.
    let bundle: Bundle
    var didPrepare = false

    private let releaseFetcher: any ToolReleaseFetching
    private let processRunner: any ToolProcessRunning
    private let queueSnapshot: @Sendable () async -> DownloadQueueSnapshot
    private var isApplyingUpdate = false

    /// - Parameters:
    ///   - releaseFetcher: The release feed and byte source for the self-update.
    ///   - processRunner: Runs `--version` and `codesign`. This type never spawns directly.
    ///   - bundle: Where the seed binaries are read from. `Bundle.main` in production.
    ///   - toolsDirectory: Where the running copies live. Defaults to
    ///     `~/Library/Application Support/MacAMP/Tools/`, falling back to a temporary
    ///     directory only when Application Support cannot be resolved at all — a state
    ///     in which `prepare()` is expected to fail loudly rather than silently do nothing.
    ///   - queueSnapshot: Reads the download queue. An update is refused while it
    ///     reports ANY active item; the default reports an empty queue.
    init(
        releaseFetcher: any ToolReleaseFetching,
        processRunner: any ToolProcessRunning,
        bundle: Bundle = .main,
        toolsDirectory: URL? = nil,
        queueSnapshot: @escaping @Sendable () async -> DownloadQueueSnapshot = { .empty }
    ) {
        self.releaseFetcher = releaseFetcher
        self.processRunner = processRunner
        self.bundle = bundle
        self.toolsDirectory = toolsDirectory
            ?? DownloadToolsLocation.defaultDirectory()
            ?? FileManager.default.temporaryDirectory
            .appendingPathComponent(DownloadToolsLocation.applicationSupportSubpath, isDirectory: true)
        self.queueSnapshot = queueSnapshot
    }
}

// MARK: - DownloadToolProviding

extension DownloadToolManager {
    /// The installed yt-dlp tree's root inside ``toolsDirectory``.
    var ytDlpTreeURL: URL {
        toolsDirectory.appendingPathComponent(Self.ytDlpTreeName, isDirectory: true)
    }

    var ytDlpURL: URL {
        get async throws {
            if !didPrepare { try await prepare() }
            return ytDlpTreeURL.appendingPathComponent(Self.ytDlpExecutableName)
        }
    }

    var ffmpegDirectoryURL: URL {
        get async throws {
            _ = try await preparedURL(of: Self.ffmpegExecutableName)
            return toolsDirectory
        }
    }

    /// Copies any absent-or-older seed out of the bundle, then asserts every tool is
    /// executable and un-quarantined.
    ///
    /// Idempotent: a steady-state launch copies nothing and only re-asserts permissions,
    /// which is cheap and covers a copy an older build left quarantined.
    func prepare() async throws {
        do {
            try FileManager.default.createDirectory(at: toolsDirectory, withIntermediateDirectories: true)
        } catch {
            throw DownloadError.toolMissing
        }
        try provisionYtDlpTree()
        for name in Self.seededBinaryNames {
            try provision(name)
        }
        didPrepare = true
    }

    /// What the installed engine calls itself.
    func version() async throws -> String {
        let tool = try await ytDlpURL
        let result = try await ToolRunResult.collecting(tool, arguments: ["--version"], through: processRunner)
        guard result.termination.isSuccess, let reported = result.firstOutputLine else {
            throw DownloadError.toolMissing
        }
        return reported
    }

    /// Compares the installed engine against the published release tag.
    func checkForUpdate() async throws -> ToolUpdateAvailability {
        let installed = try await version()
        let release = try await releaseFetcher.fetchLatestRelease()
        return ToolUpdatePlanner.availability(installed: installed, latest: release.tag)
    }

    /// Installs the latest published engine tree, verified and with rollback.
    ///
    /// Refused while ANY download is in flight: replacing the engine underneath a
    /// running child is how a download that was going to succeed turns into a corrupt
    /// file. The caller surfaces ``DownloadToolStrings/updateDeferredWhileDownloading``
    /// and tries again later — nothing is queued or retried automatically.
    ///
    /// The whole TREE is replaced, from ``ytDlpArchiveName``. Resolving ``ytDlpURL``
    /// first is deliberate: it provisions the tree out of the bundle when it is absent,
    /// so an update always has a predecessor to roll back to.
    func applyUpdate() async throws -> String {
        guard !isApplyingUpdate else {
            throw DownloadError.updateFailed(detail: Self.concurrentUpdateDetail)
        }
        // SEMANTIC WIDENING, not a rename. The queue runs several transfers at once, so
        // the refusal now covers ANY active row rather than one in-flight row: an
        // engine swapped underneath even one running child corrupts that download, and
        // the rollback copy it would race is shared by all of them.
        guard await queueSnapshot().activeItems.isEmpty else {
            throw DownloadError.updateFailed(detail: Self.deferredDetail)
        }
        isApplyingUpdate = true
        defer { isApplyingUpdate = false }
        _ = try await ytDlpURL
        let release = try await releaseFetcher.fetchLatestRelease()
        let installer = ToolUpdateInstaller(releaseFetcher: releaseFetcher, processRunner: processRunner)
        return try await installer.installTree(
            release,
            archiveName: Self.ytDlpArchiveName,
            executableName: Self.ytDlpExecutableName,
            at: ytDlpTreeURL
        )
    }
}

// MARK: - Deferral, surfaced without throwing

extension DownloadToolManager {
    /// Whether ``applyUpdate()`` would refuse right now.
    ///
    /// Lets a settings pane disable its update button instead of offering an action
    /// that is guaranteed to fail.
    func isUpdateDeferred() async -> Bool {
        let snapshot = await queueSnapshot()
        return !snapshot.activeItems.isEmpty
    }
}

/// Copy owned by the tool manager.
///
/// One constant today, so it lives beside the code that needs it rather than in a file
/// of its own; the update UI (which owns the rest of this surface's copy) may relocate
/// it when it adds siblings.
enum DownloadToolStrings {
    static let updateDeferredWhileDownloading = LocalizedStringResource(
        "downloads.update.deferredWhileDownloading",
        defaultValue: "The download engine will be updated after your downloads finish.",
        comment: "Shown when an engine update is requested while a download is still running"
    )
}
