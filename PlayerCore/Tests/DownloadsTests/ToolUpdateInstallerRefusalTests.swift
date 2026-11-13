// The installer's refusal paths, its first-install behaviour, and the executable
// hygiene every provisioned binary depends on.
//
// Continues `ToolUpdateInstallerTests.swift` (which owns the shared fixture) — split
// only because one file would exceed the 400-line ceiling. Archive-integrity refusals
// live in `ToolUpdateInstallerTreeTests.swift`.
import Darwin
import Foundation
import PlayerCoreTestSupport
import Services
import Testing

@Suite("Tool update installer — refusals and first install")
struct ToolUpdateInstallerRefusalTests {
    /// The manifest lists the ONEFILE asset, which is published in the same release
    /// under a name differing only by the `.zip` suffix. Matching it would install a
    /// binary that runs and permanently costs ~12 s per spawn.
    @Test("a release whose manifest does not cover the ARCHIVE never downloads it")
    func uncoveredArchiveIsNeverDownloaded() async throws {
        let directory = try makeToolsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tree = directory.appendingPathComponent(toolTreeName, isDirectory: true)
        try writeToolTree(at: tree, launcher: toolOldBytes)

        let release = FakeToolReleaseFetcher.sampleRelease
        let releases = toolReleaseFetcher(
            manifest: toolManifestText(digest: toolNewDigest, name: toolAssetName),
            asset: toolNewBytes
        )
        let runner = FakeToolProcessRunner()
        let installer = ToolUpdateInstaller(releaseFetcher: releases, processRunner: runner)

        do {
            try await installToolTree(installer, at: tree)
            Issue.record("an unverifiable archive must not be installed")
        } catch let error as DownloadError {
            #expect(error.detail?.contains("no SHA-256 published") == true)
            #expect(error.detail?.contains(toolArchiveName) == true)
        }

        #expect(releases.fetchedURLs == [release.checksumURL])
        #expect(try toolLauncherBytes(in: tree) == toolOldBytes)
        #expect(runner.spawnCount == 0)
    }

    @Test("a manifest that is not readable text refuses rather than decoding lossily")
    func unreadableManifestRefuses() async throws {
        let directory = try makeToolsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tree = directory.appendingPathComponent(toolTreeName, isDirectory: true)
        try writeToolTree(at: tree, launcher: toolOldBytes)

        let release = FakeToolReleaseFetcher.sampleRelease
        let releases = FakeToolReleaseFetcher(payloads: [
            release.checksumURL: Data([0xFF, 0xFE, 0xFD]),
            release.assetURL: toolNewBytes,
        ])
        let installer = ToolUpdateInstaller(releaseFetcher: releases, processRunner: FakeToolProcessRunner())

        do {
            try await installToolTree(installer, release: release, at: tree)
            Issue.record("a manifest that is not text must not be trusted")
        } catch let error as DownloadError {
            #expect(error.detail?.contains("not readable text") == true)
        }

        #expect(try toolLauncherBytes(in: tree) == toolOldBytes)
    }

    @Test("a first install needs no predecessor and leaves no rollback copy")
    func firstInstallHasNoPrevious() async throws {
        let directory = try makeToolsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tree = directory.appendingPathComponent(toolTreeName, isDirectory: true)

        let releases = toolReleaseFetcher(manifest: toolManifestText(digest: toolNewDigest), asset: toolNewBytes)
        let runner = toolInstallRunner([.success(), .success(), .success(stdout: ["2026.09.09"])])
        let installer = ToolUpdateInstaller(releaseFetcher: releases, processRunner: runner)

        let installed = try await installToolTree(installer, at: tree)

        #expect(installed == "2026.09.09")
        #expect(try toolLauncherBytes(in: tree) == toolNewBytes)
        let listed = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(listed == [toolTreeName])
    }

    @Test("a first install that will not run removes itself rather than leaving a broken engine")
    func firstInstallFailureRemovesTheTree() async throws {
        let directory = try makeToolsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tree = directory.appendingPathComponent(toolTreeName, isDirectory: true)

        let releases = toolReleaseFetcher(manifest: toolManifestText(digest: toolNewDigest), asset: toolNewBytes)
        let runner = toolInstallRunner([.success(), .success(), .exit(status: 1)])
        let installer = ToolUpdateInstaller(releaseFetcher: releases, processRunner: runner)

        do {
            try await installToolTree(installer, at: tree)
            Issue.record("a first install that cannot run must not survive")
        } catch let error as DownloadError {
            #expect(error.detail?.contains("failed to run") == true)
        }

        let listed = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(listed.isEmpty)
    }

    @Test("a cancelled validation stream is a cancellation, not a silent success")
    func cancelledStreamRollsBack() async throws {
        let directory = try makeToolsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tree = directory.appendingPathComponent(toolTreeName, isDirectory: true)
        try writeToolTree(at: tree, launcher: toolOldBytes)

        let releases = toolReleaseFetcher(manifest: toolManifestText(digest: toolNewDigest), asset: toolNewBytes)
        // `.cancelled` ends the stream WITHOUT a termination event — todo 1's contract
        // for a child that was killed. Scripted on the SECOND spawn so the cancellation
        // lands POST-swap, which is the rollback this test is about.
        let runner = toolInstallRunner([.success(), .cancelled()])
        let installer = ToolUpdateInstaller(releaseFetcher: releases, processRunner: runner)

        await #expect(throws: CancellationError.self) {
            try await installToolTree(installer, at: tree)
        }

        #expect(try toolLauncherBytes(in: tree) == toolOldBytes)
    }
}

// MARK: - Executable hygiene

@Suite("Tool executable file hygiene")
struct ToolExecutableFileTests {
    @Test("a freshly copied file becomes mode 0755")
    func setsExecutablePermissions() throws {
        let directory = try makeToolsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent(toolAssetName)
        try toolNewBytes.write(to: file)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o644)],
            ofItemAtPath: file.path
        )

        try ToolExecutableFile.makeRunnable(at: file)

        let mode = try toolPosixPermissions(of: file)
        #expect(mode == 0o755)
        #expect(FileManager.default.isExecutableFile(atPath: file.path))
    }

    @Test("an actual quarantine flag is stripped")
    func stripsQuarantine() throws {
        let directory = try makeToolsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent(toolAssetName)
        try toolNewBytes.write(to: file)
        let value = Array("0081;68c0a1b2;Test;".utf8)
        let written = file.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return setxattr(path, ToolExecutableFile.quarantineAttribute, value, value.count, 0, 0)
        }
        #expect(written == 0)

        try ToolExecutableFile.stripQuarantine(at: file)

        let size = file.withUnsafeFileSystemRepresentation { path -> Int in
            guard let path else { return -1 }
            return getxattr(path, ToolExecutableFile.quarantineAttribute, nil, 0, 0, 0)
        }
        #expect(size == -1)
    }

    @Test("stripping a quarantine that is not there is success, not a failure")
    func missingQuarantineIsSuccess() throws {
        let directory = try makeToolsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent(toolAssetName)
        try toolNewBytes.write(to: file)

        // ENOATTR must be tolerated, or the second (idempotent) call would fail on
        // every launch after the first.
        try ToolExecutableFile.stripQuarantine(at: file)
        try ToolExecutableFile.stripQuarantine(at: file)
    }

    @Test("a missing file cannot be made runnable")
    func missingFileFails() {
        let absent = FileManager.default.temporaryDirectory
            .appendingPathComponent("macamp-absent-\(UUID().uuidString)")
        #expect(throws: ToolExecutableFile.Failure.self) {
            try ToolExecutableFile.makeRunnable(at: absent)
        }
    }
}
