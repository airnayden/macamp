// The tree-shaped failures the one-directory engine introduced, and the hygiene the
// installer owes the tree it swaps in.
//
// A onefile install could only be right or absent. A onedir install can be PARTIAL:
// an archive that expands to a launcher with no `_internal/` produces something that
// exists, signs, and dies at first exec with "Failed to load Python shared library".
// Every test here drives one shape of that and asserts the installed engine survived.
//
// Shares the fixture declared in `ToolUpdateInstallerTests.swift`.
import Foundation
import PlayerCoreTestSupport
import Services
import Testing

@Suite("Tool update installer — archive integrity")
struct ToolUpdateInstallerTreeTests {
    @Test("an archive that expands without _internal/ is refused and the engine survives")
    func missingPayloadIsRefused() async throws {
        let directory = try makeToolsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tree = directory.appendingPathComponent(toolTreeName, isDirectory: true)
        try writeToolTree(at: tree, launcher: toolOldBytes)

        let releases = toolReleaseFetcher(manifest: toolManifestText(digest: toolNewDigest), asset: toolNewBytes)
        let runner = toolInstallRunner(
            [.success()],
            expansion: toolArchiveExpansion(includePayload: false)
        )
        let installer = ToolUpdateInstaller(releaseFetcher: releases, processRunner: runner)

        do {
            try await installToolTree(installer, at: tree)
            Issue.record("a flattened archive must not replace a working engine")
        } catch let error as DownloadError {
            #expect(error.detail?.contains("_internal/ payload") == true)
        }

        #expect(try toolLauncherBytes(in: tree) == toolOldBytes)
        // Refused during STAGING, so the swap never happened and there is no `.previous`.
        let listed = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(listed == [toolTreeName])
        #expect(runner.spawnCount == 1)
    }

    @Test("an archive that expands without the launcher is refused and the engine survives")
    func missingLauncherIsRefused() async throws {
        let directory = try makeToolsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tree = directory.appendingPathComponent(toolTreeName, isDirectory: true)
        try writeToolTree(at: tree, launcher: toolOldBytes)

        let releases = toolReleaseFetcher(manifest: toolManifestText(digest: toolNewDigest), asset: toolNewBytes)
        let runner = toolInstallRunner(
            [.success()],
            expansion: toolArchiveExpansion(includeLauncher: false)
        )
        let installer = ToolUpdateInstaller(releaseFetcher: releases, processRunner: runner)

        do {
            try await installToolTree(installer, at: tree)
            Issue.record("an archive with no launcher must not replace a working engine")
        } catch let error as DownloadError {
            #expect(error.detail?.contains(toolAssetName) == true)
        }

        #expect(try toolLauncherBytes(in: tree) == toolOldBytes)
        let listed = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(listed == [toolTreeName])
    }

    @Test("a failed expansion is refused and the engine survives")
    func failedExpansionIsRefused() async throws {
        let directory = try makeToolsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tree = directory.appendingPathComponent(toolTreeName, isDirectory: true)
        try writeToolTree(at: tree, launcher: toolOldBytes)

        let releases = toolReleaseFetcher(manifest: toolManifestText(digest: toolNewDigest), asset: toolNewBytes)
        let runner = toolInstallRunner(
            [.exit(status: 2, stderr: ["ditto: Couldn't read pkzip signature"])],
            expansion: toolArchiveExpansion(includeLauncher: false, includePayload: false)
        )
        let installer = ToolUpdateInstaller(releaseFetcher: releases, processRunner: runner)

        do {
            try await installToolTree(installer, at: tree)
            Issue.record("an archive that will not expand must not replace a working engine")
        } catch let error as DownloadError {
            #expect(error.detail?.contains("could not expand") == true)
            #expect(error.detail?.contains("pkzip") == true)
        }

        #expect(try toolLauncherBytes(in: tree) == toolOldBytes)
        let listed = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(listed == [toolTreeName])
    }

    /// The expanded archive carries `com.apple.quarantine` on every file, exactly as a
    /// LaunchServices-mediated download does. A single-file strip would clear the
    /// launcher and leave the payload the launcher `dlopen`s still flagged.
    @Test("the whole expanded tree is un-quarantined, not just its launcher")
    func expansionIsUnquarantinedThroughout() async throws {
        let directory = try makeToolsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tree = directory.appendingPathComponent(toolTreeName, isDirectory: true)

        let releases = toolReleaseFetcher(manifest: toolManifestText(digest: toolNewDigest), asset: toolNewBytes)
        let runner = toolInstallRunner(
            [.success(), .success(), .success(stdout: ["2026.09.09"])],
            expansion: toolArchiveExpansion(quarantine: true)
        )
        let installer = ToolUpdateInstaller(releaseFetcher: releases, processRunner: runner)

        try await installToolTree(installer, at: tree)

        let launcher = tree.appendingPathComponent(toolAssetName)
        let nested = tree
            .appendingPathComponent(ToolUpdateInstaller.payloadDirectoryName)
            .appendingPathComponent("Python")
        #expect(!treeHasQuarantine(launcher))
        #expect(!treeHasQuarantine(nested), "the _internal/ payload must be stripped too")
    }

    /// The archive is written beside the tree so the expansion lands on the same
    /// volume, which is what makes the swap a rename. It must not outlive the install.
    @Test("the staged archive and staging directory never survive an install")
    func stagingArtifactsAreCleanedUp() async throws {
        let directory = try makeToolsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tree = directory.appendingPathComponent(toolTreeName, isDirectory: true)

        let releases = toolReleaseFetcher(manifest: toolManifestText(digest: toolNewDigest), asset: toolNewBytes)
        let runner = toolInstallRunner([.success(), .success(), .success(stdout: ["2026.09.09"])])
        let installer = ToolUpdateInstaller(releaseFetcher: releases, processRunner: runner)

        try await installToolTree(installer, at: tree)

        let listed = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(listed == [toolTreeName])
    }

    /// `installTree` hands `ditto` the archive it just wrote and the staging directory
    /// it is about to swap — both inside the tree's own parent, never `$TMPDIR`.
    @Test("the expansion runs ditto -x -k on a same-volume staging pair")
    func expansionArgumentsAreSameVolume() async throws {
        let directory = try makeToolsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tree = directory.appendingPathComponent(toolTreeName, isDirectory: true)

        let releases = toolReleaseFetcher(manifest: toolManifestText(digest: toolNewDigest), asset: toolNewBytes)
        let runner = toolInstallRunner([.success(), .success(), .success(stdout: ["2026.09.09"])])
        let installer = ToolUpdateInstaller(releaseFetcher: releases, processRunner: runner)

        try await installToolTree(installer, at: tree)

        let expand = try #require(runner.spawnRequests.first)
        #expect(expand.tool == ToolUpdateInstaller.extractorURL)
        #expect(expand.arguments.count == 4)
        #expect(Array(expand.arguments.prefix(2)) == ["-x", "-k"])
        let archive = URL(fileURLWithPath: expand.arguments[2])
        let staged = URL(fileURLWithPath: expand.arguments[3])
        #expect(archive.deletingLastPathComponent().path == directory.path)
        #expect(staged.deletingLastPathComponent().path == directory.path)
        #expect(archive.pathExtension == "zip")
        #expect(staged.lastPathComponent.hasPrefix(".macamp-tool-"))
    }
}

// MARK: - Install timestamps

/// The launch path decides whether the bundle's seed replaces the installed engine by
/// asking "is the installed launcher OLDER than the seed?" — so an installed launcher's
/// date has to be the date it was INSTALLED.
///
/// The onefile flow got that for free: it wrote the binary with
/// `Data.write(to:options:.atomic)`, which stamps "now". `ditto -x -k` does not — it
/// restores each entry's date out of the archive. In a SIGNED release the seed carries
/// the app's `codesign` time, which is always later than the yt-dlp version it pins, so
/// an un-stamped self-update looks stale and is reverted on the next launch, for ever.
/// Unsigned dev builds cannot reproduce that, which is why the rest of this file's
/// scratch-directory tests never saw it.
@Suite("Tool update installer — install timestamps")
struct ToolUpdateInstallerStampTests {
    /// 2026-01-15 09:00 UTC — an archive entry's stored date, months before "now".
    static let archiveStoredDate = Date(timeIntervalSince1970: 1_768_467_600)

    @Test("the installed launcher carries the install time, not the archive's stored date")
    func theInstalledLauncherIsStampedWithTheInstallTime() async throws {
        let directory = try makeToolsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tree = directory.appendingPathComponent(toolTreeName, isDirectory: true)
        try writeToolTree(at: tree, launcher: toolOldBytes)

        let releases = toolReleaseFetcher(manifest: toolManifestText(digest: toolNewDigest), asset: toolNewBytes)
        let runner = toolInstallRunner(
            [.success(), .success(), .success(stdout: ["2026.09.09"])],
            expansion: toolArchiveExpansion(storedDate: Self.archiveStoredDate)
        )
        let installer = ToolUpdateInstaller(releaseFetcher: releases, processRunner: runner)
        let startedAt = Date()

        try await installToolTree(installer, at: tree)

        let launcher = tree.appendingPathComponent(toolAssetName)
        let stamped = try #require(try toolModificationDate(of: launcher))
        #expect(stamped > Self.archiveStoredDate, "the archive's stored date must not survive the install")
        #expect(stamped >= startedAt.addingTimeInterval(-1), "the launcher must carry the install time")
        // The stamp is the launcher's alone: nothing else compares payload dates, and
        // walking 133 files to rewrite timestamps nobody reads would be pure cost.
        let nested = tree
            .appendingPathComponent(ToolUpdateInstaller.payloadDirectoryName)
            .appendingPathComponent("Python")
        let payloadDate = try #require(try toolModificationDate(of: nested))
        #expect(payloadDate == Self.archiveStoredDate)
    }
}
