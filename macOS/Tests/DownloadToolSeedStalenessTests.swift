// DownloadToolSeedStalenessTests — the launch-path decision that either keeps or
// destroys a successful engine self-update.
//
// `DownloadToolManager.shouldCopy(_:over:)` runs on every launch and asks one question:
// is the installed yt-dlp launcher OLDER than the seed inside the app bundle? "Yes"
// copies the bundle's engine over the installed one. That is correct for an app update
// and catastrophic for a self-update, and which of the two it does depends entirely on
// two modification dates that NOTHING in the code makes obvious.
//
// ── WHY THESE TESTS BUILD THE DATES BY HAND ──────────────────────────────────
//
// `DownloadToolTreeProvisioningTests` provisions into a scratch directory, where seed
// and install are both written moments apart and every comparison is trivially true.
// A shipped release is not like that:
//
//   seed launcher   ← `codesign` rewrote the Mach-O, so it carries the APP's SIGNING
//                     date; `FileManager.copyItem` then preserves it out to the tools
//                     directory.
//   installed tree  ← `ditto -x -k` restores each entry's date STORED IN THE ARCHIVE,
//                     so a self-update would otherwise carry yt-dlp's own release date.
//
// An app is always signed after the yt-dlp version it pins, so those two dates are
// skewed in exactly the direction that reverts every successful update, for ever, with
// no error anywhere in it. Unsigned dev builds never stamp the seed with a signing time
// at all, so the skew cannot be reproduced by "building and trying it" — only by
// constructing it, which is what this suite does.
//
// The first test therefore drives the REAL installer (`ToolUpdateInstaller.installTree`)
// rather than writing a tree by hand: the property under test is what the install path
// leaves on disk, and a hand-written fixture would assert the fixture.
import Foundation
@testable import MacAMP
import Services
import Testing

@Suite("Download tool seed staleness")
struct DownloadToolSeedStalenessTests {
    static let seedBytes = Data("macamp-seed-engine".utf8)
    static let updatedBytes = Data("macamp-new-engine".utf8)

    /// `shasum -a 256` of ``updatedBytes``, produced independently of `CryptoKit`.
    static let updatedDigest = "e3ff958839da6e51f07fdbe3082ded7abe4d15eb037300f308d6c43520e47ccb"

    static let hour: TimeInterval = 3600
    static let month: TimeInterval = 30 * 24 * 3600

    /// The regression: a self-update installed through the real installer must survive a
    /// launch whose bundled seed carries a LATER date than the archive it came from.
    @Test("a self-updated tree survives a launch whose seed carries a later signing date")
    func theSelfUpdatedTreeSurvivesTheNextLaunch() async throws {
        let scratch = try Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let tools = try Self.makeToolsDirectory(in: scratch)
        // The app was signed an hour ago; the engine it downloads was released a month
        // ago. Both are in the past, and the seed is the NEWER of the two.
        let bundle = try Self.makeSeedBundle(in: scratch, launcherDate: Date() - Self.hour)
        try await Self.installUpdate(into: tools, archiveDate: Date() - Self.month)

        let manager = Self.makeManager(bundle: bundle, toolsDirectory: tools)
        try await manager.provisionYtDlpTree()

        #expect(try Self.installedLauncherBytes(in: tools) == Self.updatedBytes)
    }

    /// The other half of the same rule: a real app update must still win.
    @Test("an app update whose seed is genuinely newer still takes over")
    func aNewerAppSeedStillTakesOver() async throws {
        let scratch = try Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let tools = try Self.makeToolsDirectory(in: scratch)
        try Self.writeTree(at: Self.treeURL(in: tools), launcher: Self.updatedBytes, date: Date() - Self.month)
        let bundle = try Self.makeSeedBundle(in: scratch, launcherDate: Date())

        let manager = Self.makeManager(bundle: bundle, toolsDirectory: tools)
        try await manager.provisionYtDlpTree()

        #expect(try Self.installedLauncherBytes(in: tools) == Self.seedBytes)
    }

    @Test("an absent install is provisioned from the seed, payload and all")
    func anAbsentInstallIsCopiedFromTheSeed() async throws {
        let scratch = try Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let tools = try Self.makeToolsDirectory(in: scratch)
        let bundle = try Self.makeSeedBundle(in: scratch, launcherDate: Date() - Self.hour)

        let manager = Self.makeManager(bundle: bundle, toolsDirectory: tools)
        try await manager.provisionYtDlpTree()

        #expect(try Self.installedLauncherBytes(in: tools) == Self.seedBytes)
        let payload = Self.treeURL(in: tools)
            .appendingPathComponent(ToolUpdateInstaller.payloadDirectoryName)
            .appendingPathComponent(Self.payloadFileName)
        #expect(FileManager.default.fileExists(atPath: payload.path))
    }

    /// A seed tree with no launcher inside it has no readable date, and clobbering a
    /// working engine on the strength of missing metadata is the worse of the two
    /// mistakes — so the install is left exactly as it was.
    @Test("a seed whose date cannot be read leaves the installed engine alone")
    func anUnreadableSeedDateLeavesTheInstallAlone() async throws {
        let scratch = try Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let tools = try Self.makeToolsDirectory(in: scratch)
        try Self.writeTree(at: Self.treeURL(in: tools), launcher: Self.updatedBytes, date: Date() - Self.month)
        let bundle = try Self.makeSeedBundle(in: scratch, launcherDate: Date(), includeLauncher: false)

        let manager = Self.makeManager(bundle: bundle, toolsDirectory: tools)
        try await manager.provisionYtDlpTree()

        #expect(try Self.installedLauncherBytes(in: tools) == Self.updatedBytes)
    }
}

// MARK: - Fixtures

extension DownloadToolSeedStalenessTests {
    static let payloadFileName = "Python"

    static func treeURL(in tools: URL) -> URL {
        tools.appendingPathComponent(DownloadToolManager.ytDlpTreeName, isDirectory: true)
    }

    static func launcherURL(in tree: URL) -> URL {
        tree.appendingPathComponent(DownloadToolManager.ytDlpExecutableName)
    }

    static func installedLauncherBytes(in tools: URL) throws -> Data {
        try Data(contentsOf: launcherURL(in: treeURL(in: tools)))
    }

    static func makeScratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("macamp-seed-staleness-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func makeToolsDirectory(in scratch: URL) throws -> URL {
        let url = scratch.appendingPathComponent("Tools", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The PyInstaller onedir shape in miniature, stamped as a whole.
    static func writeTree(at root: URL, launcher: Data, date: Date) throws {
        let manager = FileManager.default
        let payload = root.appendingPathComponent(ToolUpdateInstaller.payloadDirectoryName, isDirectory: true)
        try manager.createDirectory(at: payload, withIntermediateDirectories: true)
        let launcherURL = launcherURL(in: root)
        try launcher.write(to: launcherURL)
        let nested = payload.appendingPathComponent(payloadFileName)
        try Data("python".utf8).write(to: nested)
        for file in [launcherURL, nested] {
            try manager.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
        }
    }

    /// A real `Bundle` over a scratch `.bundle` directory, so `seedTreeURL` resolves
    /// through the same `url(forResource:withExtension:)` lookup production uses.
    static func makeSeedBundle(in scratch: URL, launcherDate: Date, includeLauncher: Bool = true) throws -> Bundle {
        let root = scratch.appendingPathComponent("Seed.bundle", isDirectory: true)
        let tree = root
            .appendingPathComponent("Contents/Resources", isDirectory: true)
            .appendingPathComponent(DownloadToolManager.ytDlpTreeName, isDirectory: true)
        try writeTree(at: tree, launcher: seedBytes, date: launcherDate)
        if !includeLauncher {
            try FileManager.default.removeItem(at: launcherURL(in: tree))
        }
        return try #require(Bundle(url: root))
    }

    /// A manager that reads `bundle` and installs into `toolsDirectory`, and whose
    /// network and process seams both fail loudly — nothing in this suite updates or
    /// spawns, so a canned answer would let an unintended call pass unnoticed.
    static func makeManager(bundle: Bundle, toolsDirectory: URL) -> DownloadToolManager {
        DownloadToolManager(
            releaseFetcher: OfflineReleaseFetcher(),
            processRunner: UnusedToolRunner(),
            bundle: bundle,
            toolsDirectory: toolsDirectory
        )
    }

    /// Installs an engine update through the REAL installer, with a `ditto` double that
    /// reproduces the one behaviour that matters here: an expanded file carries the
    /// date stored in the archive, not the time of extraction.
    static func installUpdate(into tools: URL, archiveDate: Date) async throws {
        let release = OfflineReleaseFetcher.release
        let fetcher = OfflineReleaseFetcher(payloads: [
            release.checksumURL: Data("\(updatedDigest)  \(DownloadToolManager.ytDlpArchiveName)\n".utf8),
            release.assetURL: updatedBytes,
        ])
        let runner = ScriptedToolRunner(scripts: [
            [.terminated(.success)],
            [.terminated(.success)],
            [.stdout("2026.09.09"), .terminated(.success)],
        ]) { tool, arguments in
            guard tool == ToolUpdateInstaller.extractorURL, arguments.count == 4 else { return }
            try? writeTree(
                at: URL(fileURLWithPath: arguments[3]),
                launcher: updatedBytes,
                date: archiveDate
            )
        }
        let installer = ToolUpdateInstaller(releaseFetcher: fetcher, processRunner: runner)
        try await installer.installTree(
            release,
            archiveName: DownloadToolManager.ytDlpArchiveName,
            executableName: DownloadToolManager.ytDlpExecutableName,
            at: treeURL(in: tools)
        )
    }
}

// MARK: - Doubles

/// A ``ToolReleaseFetching`` that answers from a fixed table and never reaches a network.
private struct OfflineReleaseFetcher: ToolReleaseFetching {
    enum Failure: Error { case noPayload }

    static let release = ToolRelease(
        tag: "2026.09.09",
        assetURL: URL(string: "https://example.invalid/yt-dlp_macos.zip")!,
        checksumURL: URL(string: "https://example.invalid/SHA2-256SUMS")!
    )

    var payloads: [URL: Data] = [:]

    func fetchLatestRelease() async throws -> ToolRelease {
        Self.release
    }

    func fetchData(from url: URL) async throws -> Data {
        guard let data = payloads[url] else { throw Failure.noPayload }
        return data
    }
}

/// A ``ToolProcessRunning`` that replays one scripted event list per spawn, in order,
/// and runs a side effect first so `ditto` can be given something to expand.
private final class ScriptedToolRunner: ToolProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var scripts: [[ToolOutputEvent]]
    private let onSpawn: @Sendable (URL, [String]) -> Void

    init(scripts: [[ToolOutputEvent]], onSpawn: @escaping @Sendable (URL, [String]) -> Void) {
        self.scripts = scripts
        self.onSpawn = onSpawn
    }

    func spawn(tool: URL, arguments: [String]) async throws -> AsyncThrowingStream<ToolOutputEvent, any Error> {
        onSpawn(tool, arguments)
        let events = lock.withLock { scripts.isEmpty ? [.terminated(.success)] : scripts.removeFirst() }
        return AsyncThrowingStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }
}

/// A ``ToolProcessRunning`` for the provisioning tests, where every spawn is a bug.
private struct UnusedToolRunner: ToolProcessRunning {
    enum Failure: Error { case processSpawned }

    func spawn(tool _: URL, arguments _: [String]) async throws -> AsyncThrowingStream<ToolOutputEvent, any Error> {
        throw Failure.processSpawned
    }
}
