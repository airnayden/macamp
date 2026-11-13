// The engine self-update flow end to end, over a REAL temporary directory and the two
// scripted doubles: `FakeToolReleaseFetcher` for the bytes and `FakeToolProcessRunner`
// for `ditto`, `codesign` and `--version`.
//
// The unit of installation is a DIRECTORY. Every test here installs a tree — a
// launcher plus a non-empty `_internal/` payload — because that is what yt-dlp is, and
// because a single-file swap is precisely the regression this flow exists to prevent.
//
// The three load-bearing scenarios the plan names are the three tests in the first
// suite: a happy swap, a bad-hash refusal that must happen BEFORE anything is written
// (and, now, before anything is EXPANDED), and a post-swap `--version` failure that
// must restore the previous tree. Refusals, first-install behaviour and executable
// hygiene continue in `ToolUpdateInstallerRefusalTests.swift`; archive-integrity
// refusals in `ToolUpdateInstallerTreeTests.swift`. Both share the fixture below.
//
// The expected digests are hard-coded hex, produced independently by `shasum -a 256`
// on the exact fixture bytes — not recomputed here from the same `CryptoKit` call the
// production code makes, which would agree with any value it happened to produce.
import Foundation
import PlayerCoreTestSupport
import Services
import Testing

// MARK: - Shared fixture

/// `shasum -a 256` of `macamp-old-engine`.
let toolOldDigest = "3770d847f1e00b07eae57430194d240b7f07abfde267f443e42630bb1c063b01"
/// `shasum -a 256` of `macamp-new-engine`.
let toolNewDigest = "e3ff958839da6e51f07fdbe3082ded7abe4d15eb037300f308d6c43520e47ccb"

let toolOldBytes = Data("macamp-old-engine".utf8)
let toolNewBytes = Data("macamp-new-engine".utf8)

/// The ARCHIVE's name in `SHA2-256SUMS`. Never the bare launcher name published beside
/// it — installing that succeeds and permanently costs ~12 s per engine spawn.
let toolArchiveName = "yt-dlp_macos.zip"
/// The launcher, both inside the archive and inside the installed tree.
let toolAssetName = "yt-dlp_macos"
/// The installed tree's directory name.
let toolTreeName = "yt-dlp"

/// A scratch directory that stands in for `~/Library/Application Support/MacAMP/Tools`.
func makeToolsDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("macamp-tool-update-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

/// One `SHA2-256SUMS` record, in the manifest's real two-space shape.
func toolManifestText(digest: String, name: String = toolArchiveName) -> String {
    "\(digest)  \(name)\n"
}

func toolReleaseFetcher(manifest: String, asset: Data) -> FakeToolReleaseFetcher {
    let release = FakeToolReleaseFetcher.sampleRelease
    return FakeToolReleaseFetcher(payloads: [
        release.checksumURL: Data(manifest.utf8),
        release.assetURL: asset,
    ])
}

func toolPosixPermissions(of url: URL) throws -> Int? {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.posixPermissions] as? NSNumber)?.intValue
}

func toolModificationDate(of url: URL) throws -> Date? {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return attributes[.modificationDate] as? Date
}

func toolContents(of url: URL) throws -> Data {
    try Data(contentsOf: url)
}

/// The PyInstaller onedir shape in miniature: a launcher plus a non-empty `_internal/`.
func writeToolTree(at root: URL, launcher: Data) throws {
    let manager = FileManager.default
    let payload = root.appendingPathComponent(ToolUpdateInstaller.payloadDirectoryName, isDirectory: true)
    try manager.createDirectory(at: payload, withIntermediateDirectories: true)
    try launcher.write(to: root.appendingPathComponent(toolAssetName))
    try Data("python".utf8).write(to: payload.appendingPathComponent("Python"))
}

func toolLauncherBytes(in root: URL) throws -> Data {
    try Data(contentsOf: root.appendingPathComponent(toolAssetName))
}

/// What `ditto -x -k` leaves on disk, as a ``FakeToolProcessRunner`` side effect.
///
/// Scripting exit 0 alone would prove the installer copes with a successful expansion
/// while never testing one: the tree it went on to swap would be empty.
///
/// `storedDate` reproduces the one behaviour of `ditto` that a scratch directory does
/// not: an expanded file carries the date STORED IN THE ARCHIVE, not the time of
/// extraction. Measured — a file stamped 2026-01-15 09:00, zipped, and re-extracted
/// eight months later comes back at 2026-01-15 09:00. Tests that leave it `nil` get
/// today's date, exactly as a freshly written scratch file would.
func toolArchiveExpansion(
    launcher: Data = toolNewBytes,
    includeLauncher: Bool = true,
    includePayload: Bool = true,
    quarantine: Bool = false,
    storedDate: Date? = nil
) -> @Sendable (ToolSpawnRequest) -> Void {
    { request in
        guard request.tool == ToolUpdateInstaller.extractorURL, request.arguments.count == 4 else { return }
        let destination = URL(fileURLWithPath: request.arguments[3])
        let manager = FileManager.default
        try? manager.createDirectory(at: destination, withIntermediateDirectories: true)
        if includeLauncher {
            let file = destination.appendingPathComponent(toolAssetName)
            try? launcher.write(to: file)
            if quarantine { _ = treeSetQuarantine(on: file) }
            toolRestoreArchiveDate(storedDate, on: file)
        }
        guard includePayload else { return }
        let payload = destination
            .appendingPathComponent(ToolUpdateInstaller.payloadDirectoryName, isDirectory: true)
        try? manager.createDirectory(at: payload, withIntermediateDirectories: true)
        let nested = payload.appendingPathComponent("Python")
        try? Data("python".utf8).write(to: nested)
        if quarantine { _ = treeSetQuarantine(on: nested) }
        toolRestoreArchiveDate(storedDate, on: nested)
    }
}

/// Stamps `file` with the date an archive entry would have carried, when one is given.
func toolRestoreArchiveDate(_ storedDate: Date?, on file: URL) {
    guard let storedDate else { return }
    try? FileManager.default.setAttributes([.modificationDate: storedDate], ofItemAtPath: file.path)
}

/// A runner that expands an archive on every `ditto` spawn and follows `scripts` for
/// the rest. The FIRST script is always the expansion's own exit status.
func toolInstallRunner(
    _ scripts: [ToolProcessScript],
    expansion: @escaping @Sendable (ToolSpawnRequest) -> Void = toolArchiveExpansion()
) -> FakeToolProcessRunner {
    FakeToolProcessRunner(scripts: scripts, onSpawn: expansion)
}

/// Installs into `tree` with the fixture's archive and launcher names.
@discardableResult
func installToolTree(
    _ installer: ToolUpdateInstaller,
    release: ToolRelease = FakeToolReleaseFetcher.sampleRelease,
    at tree: URL
) async throws -> String {
    try await installer.installTree(
        release,
        archiveName: toolArchiveName,
        executableName: toolAssetName,
        at: tree
    )
}

// MARK: - The three plan scenarios

@Suite("Tool update installer")
struct ToolUpdateInstallerTests {
    @Test("a verified archive swaps its tree in, keeps the previous tree, and reports its version")
    func happySwap() async throws {
        let directory = try makeToolsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tree = directory.appendingPathComponent(toolTreeName, isDirectory: true)
        try writeToolTree(at: tree, launcher: toolOldBytes)

        let release = FakeToolReleaseFetcher.sampleRelease
        let releases = toolReleaseFetcher(manifest: toolManifestText(digest: toolNewDigest), asset: toolNewBytes)
        let runner = toolInstallRunner([
            .success(),
            .success(),
            .success(stdout: ["2026.09.09"]),
        ])
        let installer = ToolUpdateInstaller(releaseFetcher: releases, processRunner: runner)

        let installed = try await installToolTree(installer, at: tree)

        #expect(installed == "2026.09.09")
        let installedBytes = try toolLauncherBytes(in: tree)
        #expect(installedBytes == toolNewBytes)
        // The payload came across too — a launcher alone is not an engine.
        let payload = tree.appendingPathComponent(ToolUpdateInstaller.payloadDirectoryName)
        #expect(FileManager.default.fileExists(atPath: payload.appendingPathComponent("Python").path))
        let mode = try toolPosixPermissions(of: tree.appendingPathComponent(toolAssetName))
        #expect(mode == 0o755)
        // The rollback copy is a DIRECTORY carrying the whole previous engine.
        let previous = ToolUpdateInstaller.previousURL(for: tree)
        let previousBytes = try toolLauncherBytes(in: previous)
        #expect(previousBytes == toolOldBytes)
        let previousPayload = previous
            .appendingPathComponent(ToolUpdateInstaller.payloadDirectoryName)
            .appendingPathComponent("Python")
        #expect(FileManager.default.fileExists(atPath: previousPayload.path))
        // The manifest is fetched BEFORE the archive — bytes are never downloaded that
        // the app has no way to check.
        #expect(releases.fetchedURLs == [release.checksumURL, release.assetURL])
        #expect(runner.spawnCount == 3)
        let expand = try #require(runner.spawnRequests.first)
        #expect(expand.tool == ToolUpdateInstaller.extractorURL)
        #expect(expand.arguments.prefix(2) == ["-x", "-k"])
        #expect(runner.spawnRequests[1].tool == ToolUpdateInstaller.codesignURL)
        #expect(runner.lastSpawn?.tool == tree.appendingPathComponent(toolAssetName))
        #expect(runner.lastSpawn?.arguments == ["--version"])
        // No staging artifacts survive a success.
        let listed = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        #expect(listed == ["yt-dlp", "yt-dlp.previous"])
    }

    @Test("a checksum mismatch refuses BEFORE the archive is expanded and writes nothing")
    func badHashRefusesBeforeExpansion() async throws {
        let directory = try makeToolsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tree = directory.appendingPathComponent(toolTreeName, isDirectory: true)
        try writeToolTree(at: tree, launcher: toolOldBytes)

        // The manifest advertises the OLD digest while the archive carries the NEW
        // bytes: exactly the shape of a tampered or truncated download.
        let releases = toolReleaseFetcher(manifest: toolManifestText(digest: toolOldDigest), asset: toolNewBytes)
        let runner = toolInstallRunner([])
        let installer = ToolUpdateInstaller(releaseFetcher: releases, processRunner: runner)

        do {
            try await installToolTree(installer, at: tree)
            Issue.record("a checksum mismatch must refuse the install")
        } catch let error as DownloadError {
            #expect(error.detail?.contains("checksum mismatch") == true)
        }

        let installedBytes = try toolLauncherBytes(in: tree)
        #expect(installedBytes == toolOldBytes)
        // Nothing staged, nothing expanded, nothing backed up: the refusal happened
        // before the flow reached the filesystem at all. `spawnCount == 0` is the
        // strongest form of "before expansion" — `ditto` is a spawn.
        let listed = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(listed == [toolTreeName])
        #expect(runner.spawnCount == 0)
    }

    @Test("a post-swap --version failure rolls the previous tree back")
    func versionFailureRollsBack() async throws {
        let directory = try makeToolsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tree = directory.appendingPathComponent(toolTreeName, isDirectory: true)
        try writeToolTree(at: tree, launcher: toolOldBytes)

        let releases = toolReleaseFetcher(manifest: toolManifestText(digest: toolNewDigest), asset: toolNewBytes)
        let runner = toolInstallRunner([
            .success(),
            .success(),
            .exit(status: 1, stderr: ["killed: 9"]),
        ])
        let installer = ToolUpdateInstaller(releaseFetcher: releases, processRunner: runner)

        do {
            try await installToolTree(installer, at: tree)
            Issue.record("an engine that cannot run must not be declared installed")
        } catch let error as DownloadError {
            #expect(error.detail?.contains("failed to run") == true)
        }

        let restoredBytes = try toolLauncherBytes(in: tree)
        #expect(restoredBytes == toolOldBytes)
        let restoredPayload = tree
            .appendingPathComponent(ToolUpdateInstaller.payloadDirectoryName)
            .appendingPathComponent("Python")
        #expect(FileManager.default.fileExists(atPath: restoredPayload.path))
        // Unlike the single-file flow this replaced, `.previous` does NOT survive: the
        // restored tree IS the good one, so retaining it would duplicate ~124 MB of
        // bytes that are already live.
        let listed = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(listed == [toolTreeName])
    }
}

// MARK: - Signature validation

@Suite("Tool update installer — signature validation")
struct ToolUpdateInstallerSigningTests {
    @Test("an unsigned launcher is ad-hoc re-signed through the seam, then run")
    func unsignedBinaryIsResigned() async throws {
        let directory = try makeToolsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tree = directory.appendingPathComponent(toolTreeName, isDirectory: true)
        try writeToolTree(at: tree, launcher: toolOldBytes)

        let releases = toolReleaseFetcher(manifest: toolManifestText(digest: toolNewDigest), asset: toolNewBytes)
        let runner = toolInstallRunner([
            .success(),
            .exit(status: 1, stderr: ["code object is not signed at all"]),
            .success(),
            .success(stdout: ["2026.09.09"]),
        ])
        let installer = ToolUpdateInstaller(releaseFetcher: releases, processRunner: runner)

        let installed = try await installToolTree(installer, at: tree)

        #expect(installed == "2026.09.09")
        #expect(runner.spawnCount == 4)
        let resign = runner.spawnRequests[2]
        #expect(resign.tool == ToolUpdateInstaller.codesignURL)
        let launcher = tree.appendingPathComponent(toolAssetName)
        #expect(resign.arguments == ["-s", "-", "--force", launcher.path])
    }

    @Test("a failed ad-hoc signing rolls back and never runs the launcher")
    func failedResigningRollsBack() async throws {
        let directory = try makeToolsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tree = directory.appendingPathComponent(toolTreeName, isDirectory: true)
        try writeToolTree(at: tree, launcher: toolOldBytes)

        let releases = toolReleaseFetcher(manifest: toolManifestText(digest: toolNewDigest), asset: toolNewBytes)
        let runner = toolInstallRunner([
            .success(),
            .exit(status: 1, stderr: ["code object is not signed at all"]),
            .exit(status: 1, stderr: ["the specified item could not be found in the keychain"]),
        ])
        let installer = ToolUpdateInstaller(releaseFetcher: releases, processRunner: runner)

        do {
            try await installToolTree(installer, at: tree)
            Issue.record("an unsignable engine must not be declared installed")
        } catch let error as DownloadError {
            #expect(error.detail?.contains("ad-hoc signing failed") == true)
        }

        let restoredBytes = try toolLauncherBytes(in: tree)
        #expect(restoredBytes == toolOldBytes)
        #expect(runner.spawnCount == 3)
    }

    @Test("`codesign -dv` reports to STDERR, and the seam carries it into the diagnostic")
    func stderrReachesTheDiagnostic() async throws {
        let directory = try makeToolsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tree = directory.appendingPathComponent(toolTreeName, isDirectory: true)
        try writeToolTree(at: tree, launcher: toolOldBytes)

        let releases = toolReleaseFetcher(manifest: toolManifestText(digest: toolNewDigest), asset: toolNewBytes)
        let runner = toolInstallRunner([
            .success(),
            .exit(status: 1, stderr: ["Executable=/dev/null", "code object is not signed at all"]),
            .exit(status: 1, stderr: ["errSecInternalComponent"]),
        ])
        let installer = ToolUpdateInstaller(releaseFetcher: releases, processRunner: runner)

        do {
            try await installToolTree(installer, at: tree)
            Issue.record("the install must fail when signing fails")
        } catch let error as DownloadError {
            #expect(error.detail?.contains("errSecInternalComponent") == true)
        }
    }
}
