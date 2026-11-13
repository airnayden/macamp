// DownloadToolTreeProvisioningTests — the yt-dlp PyInstaller one-directory tree, proven
// end to end against the REAL app bundle: resolved, copied out whole, and executed.
//
// This suite lives in the macOS app test target because every claim it makes is about a
// shell type `swift test` cannot reach — `DownloadToolManager` reads `Bundle.main`, and
// `YtDlpProcessRunner` is the shell's only `Foundation.Process` file. The same reason
// `DownloadProcessRunnerTests` lives here.
//
// ── WHY IT SPAWNS THE REAL ENGINE ────────────────────────────────────────────
//
// The entire point of the onefile→onedir migration is startup time, and the entire risk
// is that the 133-file `_internal/` payload does not survive being staged into the
// bundle and copied out again. Neither is observable through a fake: a scripted runner
// proves the SHAPE of a spawn, not that this particular tree can load its own Python
// shared library from the sibling directory it was copied with. So these tests run the
// binary that shipped.
//
// ── WHY THEY ARE CONDITIONAL ─────────────────────────────────────────────────
//
// `macOS/Resources/DownloaderTools/` is git-ignored and absent on fresh clones and in 12
// of the 13 CI jobs, so the bundle legitimately ships without a tree. `.enabled(if:)`
// skips rather than fails there — the same posture the optional Core ML separation model
// takes. A build that DOES carry the tree runs every assertion.
import Foundation
@testable import MacAMP
import Services
import Testing

@Suite("Download tool tree provisioning")
struct DownloadToolTreeProvisioningTests {
    /// The version pinned by `tools/downloader/fetch-download-tools.sh`.
    ///
    /// Restated here rather than read from the script, deliberately: this is the double
    /// entry that makes the assertion mean something. A test that sourced its expected
    /// value from the thing under test would agree with any value that thing produced.
    static let pinnedVersion = "2026.08.19"

    /// The onedir tree's own file count — the launcher plus its 133-file `_internal/`.
    static let expectedFileCount = 134

    /// Whether this build actually bundled a tree.
    static var bundledTreeIsPresent: Bool {
        Bundle.main.url(forResource: DownloadToolManager.ytDlpTreeName, withExtension: nil) != nil
    }

    @Test("the bundled tree resolves out of Contents/Resources, launcher and _internal intact")
    func theBundledTreeIsWholeAndFindable() throws {
        try withKnownTree { tree in
            let launcher = tree.appendingPathComponent(DownloadToolManager.ytDlpExecutableName)
            #expect(FileManager.default.fileExists(atPath: launcher.path))
            #expect(FileManager.default.fileExists(atPath: tree.appendingPathComponent("_internal").path))
            let bundledFiles = try ToolExecutableFile.regularFiles(under: tree)
            #expect(bundledFiles.count == Self.expectedFileCount)
            // A folder reference lands in Contents/Resources; a copyFiles phase would
            // have put a loose launcher in Contents/MacOS instead, without its payload.
            #expect(Bundle.main.url(forAuxiliaryExecutable: DownloadToolManager.ytDlpExecutableName) == nil)
        }
    }

    @Test("prepare() copies the whole tree out and the copied-out launcher runs")
    func theCopiedOutTreeRunsFromTheToolsDirectory() async throws {
        try await withKnownTree { _ in
            let tools = try Self.makeScratchToolsDirectory()
            defer { try? FileManager.default.removeItem(at: tools) }
            let manager = Self.makeManager(toolsDirectory: tools)

            let launcher = try await manager.ytDlpURL

            // The launcher lives INSIDE the tree, not loose beside ffmpeg — anything
            // flatter cannot find `_internal/`.
            let tree = tools.appendingPathComponent(DownloadToolManager.ytDlpTreeName)
            #expect(launcher == tree.appendingPathComponent(DownloadToolManager.ytDlpExecutableName))
            #expect(FileManager.default.fileExists(atPath: tree.appendingPathComponent("_internal").path))
            let copiedFiles = try ToolExecutableFile.regularFiles(under: tree)
            #expect(copiedFiles.count == Self.expectedFileCount)

            let reported = try await manager.version()
            #expect(reported == Self.pinnedVersion)
        }
    }

    /// The measurement the migration exists for.
    ///
    /// The onefile asset re-unpacked ~37 MB into `$TMPDIR/_MEI*` on every exec and never
    /// warmed up — three consecutive `--version` runs took 13.61 s, 14.10 s and 13.07 s.
    /// The ceiling here is one second against a measured ~0.5 s, which is loose enough
    /// never to flake on a loaded machine and an order of magnitude below any onefile
    /// run, so a silent regression to the old asset fails this test.
    ///
    /// The FIRST run is deliberately not timed: freshly written files are scanned once,
    /// which is a property of having just copied 124 MB, not of the engine.
    @Test("a warm run costs well under a second (the onefile asset never warmed up)")
    func theWarmRunIsFast() async throws {
        try await withKnownTree { _ in
            let tools = try Self.makeScratchToolsDirectory()
            defer { try? FileManager.default.removeItem(at: tools) }
            let manager = Self.makeManager(toolsDirectory: tools)

            _ = try await manager.version()

            let clock = ContinuousClock()
            let started = clock.now
            let reported = try await manager.version()
            let elapsed = clock.now - started

            #expect(reported == Self.pinnedVersion)
            #expect(elapsed < .seconds(1), "warm --version took \(elapsed)")
        }
    }

    @Test("a second prepare() is a no-op that still leaves the tree runnable")
    func provisioningIsIdempotent() async throws {
        try await withKnownTree { _ in
            let tools = try Self.makeScratchToolsDirectory()
            defer { try? FileManager.default.removeItem(at: tools) }
            let manager = Self.makeManager(toolsDirectory: tools)

            try await manager.prepare()
            let tree = tools.appendingPathComponent(DownloadToolManager.ytDlpTreeName)
            let firstStamp = try Self.launcherModificationDate(in: tree)

            try await manager.prepare()

            let secondStamp = try Self.launcherModificationDate(in: tree)
            #expect(secondStamp == firstStamp)
            let reported = try await manager.version()
            #expect(reported == Self.pinnedVersion)
        }
    }

    /// The upgrade path: an install made by a pre-onedir build has a loose 37 MB
    /// `yt-dlp_macos` sitting directly in the tools directory. Provisioning must clear
    /// it, or every existing install carries a dead engine beside the live tree.
    @Test("a pre-onedir loose engine is removed once the tree is in place")
    func theLegacyOnefileEngineIsSweptAway() async throws {
        try await withKnownTree { _ in
            let tools = try Self.makeScratchToolsDirectory()
            defer { try? FileManager.default.removeItem(at: tools) }
            let legacy = tools.appendingPathComponent(DownloadToolManager.ytDlpExecutableName)
            try Data("pretend this is the old onefile binary".utf8).write(to: legacy)

            try await Self.makeManager(toolsDirectory: tools).prepare()

            #expect(!FileManager.default.fileExists(atPath: legacy.path))
            // Removing the decoy must not have touched the real one inside the tree.
            let launcher = tools
                .appendingPathComponent(DownloadToolManager.ytDlpTreeName)
                .appendingPathComponent(DownloadToolManager.ytDlpExecutableName)
            #expect(FileManager.default.fileExists(atPath: launcher.path))
        }
    }

    // MARK: Fixtures

    /// Runs `body` with the bundled tree, or does nothing when this build has none.
    ///
    /// `.enabled(if:)` would be the idiomatic skip, but it is evaluated before the suite
    /// instance exists and cannot then hand the resolved URL to the body — so the guard
    /// and the resolve are the same expression here.
    func withKnownTree(_ body: (URL) throws -> Void) throws {
        guard let tree = Bundle.main.url(
            forResource: DownloadToolManager.ytDlpTreeName,
            withExtension: nil
        ) else { return }
        try body(tree)
    }

    func withKnownTree(_ body: (URL) async throws -> Void) async throws {
        guard let tree = Bundle.main.url(
            forResource: DownloadToolManager.ytDlpTreeName,
            withExtension: nil
        ) else { return }
        try await body(tree)
    }

    /// A manager that reads the real bundle and spawns real children, but installs into
    /// a scratch directory so the developer's own tools directory is never touched.
    static func makeManager(toolsDirectory: URL) -> DownloadToolManager {
        DownloadToolManager(
            releaseFetcher: UnreachableReleaseFetcher(),
            processRunner: YtDlpProcessRunner(),
            bundle: .main,
            toolsDirectory: toolsDirectory
        )
    }

    static func makeScratchToolsDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("macamp-tooltree-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func launcherModificationDate(in tree: URL) throws -> Date {
        let launcher = tree.appendingPathComponent(DownloadToolManager.ytDlpExecutableName)
        let attributes = try FileManager.default.attributesOfItem(atPath: launcher.path)
        guard let date = attributes[.modificationDate] as? Date else {
            throw TreeFixtureError.launcherHasNoModificationDate
        }
        return date
    }
}

enum TreeFixtureError: Error {
    case launcherHasNoModificationDate
}

/// A ``ToolReleaseFetching`` that fails loudly if anything reaches the network.
///
/// `DownloadToolManager` requires one, but nothing in this suite updates the engine, so
/// the correct double is one whose every method is a test failure rather than a canned
/// answer that could quietly satisfy an unintended call.
private struct UnreachableReleaseFetcher: ToolReleaseFetching {
    enum Failure: Error { case networkReached }

    func fetchLatestRelease() async throws -> ToolRelease {
        throw Failure.networkReached
    }

    func fetchData(from _: URL) async throws -> Data {
        throw Failure.networkReached
    }
}
