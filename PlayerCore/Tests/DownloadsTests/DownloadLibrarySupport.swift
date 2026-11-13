// The rig the two library-integration suites share: real temp directories, a real
// migrated in-memory database, and a `DownloadQueueService` whose engine script reports
// a file that ACTUALLY EXISTS on disk.
//
// The existing `DownloadQueueHarness` cannot serve here: its destination is a path that
// is never created and its `MACAMP-FILE|` line names a fixed fictional file, which is
// exactly right for testing the queue's own state machine and useless for testing an
// import. These suites need the seam's URL to be a scannable file, so the fixture is
// built the other way round — write the file first, then script the engine to report it.
//
// Names are prefixed `downloadLibrary…` / `DownloadLibrary…` because the whole
// `DownloadsTests` target shares one namespace (todo 7's learning).
import Foundation
import Metadata
import Persistence
import PlayerCoreTestSupport
import Services
import Testing

/// The fixture's own failures, so a helper outside a `@Test` body never has to reach for
/// `#require` (which expands to a non-throwing unwrap out there) or a force-unwrap.
enum DownloadLibraryFixtureError: Error {
    case profileHasNoID
    case defaultsSuiteUnavailable(String)
}

/// A temp directory that the caller is responsible for removing.
func downloadLibraryTempDirectory(_ label: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("downloads-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Writes a file `FakeMetadataReader` will happily read, so a scan of it imports a row.
@discardableResult
func downloadLibraryWriteAudioFile(in directory: URL, named name: String) throws -> URL {
    let url = directory.appendingPathComponent(name)
    try Data(repeating: 0xAB, count: 16).write(to: url)
    return url
}

/// A `DownloadQueueService` wired the way the composition root wires it: the engine
/// scripts report `finishedFiles` in order, and `onItemFinished` drives the SHIPPED
/// ``DownloadLibraryImporter`` — the same type `AppEnvironment+Downloads.swift` builds.
///
/// Routing the seam through the production importer rather than restating its body is
/// what makes the auto-import gate testable here at all: a rig that called
/// `scanner.scan` directly would go green over a gate that had been deleted.
///
/// Every decision the importer returns is recorded, so a test can assert BOTH how many
/// imports the queue asked for and how many actually scanned — which is what
/// distinguishes "the switch was off" from "the seam never fired".
@MainActor
struct DownloadLibraryImportRig {
    let service: DownloadQueueService
    let recorder = DownloadQueueRecorder()
    private let decisions = DownloadLibraryScanLog()

    init(
        scanner: any LibraryScanning,
        destination: URL,
        staging: URL,
        finishedFiles: [URL],
        videoIDs: [String] = [DownloadFixture.videoID],
        isAutoImportEnabled: @escaping @Sendable () -> Bool
    ) {
        let runner = FakeToolProcessRunner(scripts: zip(videoIDs, finishedFiles).flatMap { id, file in
            [
                DownloadFixture.infoScript(id: id),
                ToolProcessScript.success(stdout: [
                    DownloadFixture.quarterProgress,
                    DownloadFixture.postProcessLine,
                    "MACAMP-FILE|" + file.path,
                ]),
            ]
        })
        service = DownloadQueueService(
            toolProvider: FakeDownloadToolProvider(),
            processRunner: runner,
            stagingDirectory: staging,
            destinationDirectory: { destination },
            downloadFormat: { .default },
            isDirectoryWritable: { _ in true }
        )
        let sink = recorder
        let log = decisions
        let importer = DownloadLibraryImporter(scanner: scanner, isAutoImportEnabled: isAutoImportEnabled)
        service.onQueueChanged = { sink.record(snapshot: $0) }
        service.onItemProgress = { sink.record(id: $0, state: $1) }
        service.onItemFinished = { item, fileURL in
            sink.record(item: item, fileURL: fileURL)
            Task { @MainActor in
                await log.record(importer.importFinished(at: fileURL))
            }
        }
    }

    /// Every scan the import seam actually ran, in order — declined imports are absent.
    var scanSummaries: [ScanSummary] {
        get async { await decisions.recorded.compactMap(\.self) }
    }

    /// Waits until the import seam has answered `count` times, whether or not it scanned.
    func waitForImportDecisions(_ count: Int, timeout: Duration = .seconds(10)) async {
        let log = decisions
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await log.recorded.count >= count { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// Collects what the import seam decided per finished item: a `ScanSummary` when it
/// scanned, `nil` when auto-import was off. An `actor` rather than a lock, because the
/// import is `async` and the recording happens after an `await`.
actor DownloadLibraryScanLog {
    private(set) var recorded: [ScanSummary?] = []

    func record(_ decision: ScanSummary?) {
        recorded.append(decision)
    }
}

/// A migrated in-memory library with TWO profiles owning two DIFFERENT roots, plus a
/// downloads folder under neither of them holding one finished download.
///
/// The two-root shape is load-bearing: `LibraryVisibility.predicate` short-circuits to
/// `"1"` (everything visible) when no `libraryRoot` row exists anywhere, so a fixture
/// with an empty root table would pass an ownerless-visibility assertion without the
/// ownerless clause ever running.
struct DownloadLibraryFixture {
    let database: AppDatabase
    let scanner: LibraryScanner
    let guestRoot: URL
    let secondRoot: URL
    let destination: URL
    let staging: URL
    let downloadedFile: URL
    let secondProfileID: Int64

    static func make() throws -> DownloadLibraryFixture {
        let database = try AppDatabase.makeEmpty()
        let guestRoot = try downloadLibraryTempDirectory("guest-root")
        let secondRoot = try downloadLibraryTempDirectory("second-root")
        let destination = try downloadLibraryTempDirectory("destination")
        let staging = try downloadLibraryTempDirectory("staging")
        let roots = LibraryRootRepository(database)
        try roots.addRoot(profileId: ProfileRecord.guestID, path: guestRoot.path)
        let second = try ProfileRepository(database).create(ProfileRecord(
            name: "Second",
            lastName: nil,
            bio: nil,
            avatarId: "waveform-vice",
            pinHash: nil,
            pinSalt: nil,
            createdAt: Date()
        ))
        guard let secondProfileID = second.id else { throw DownloadLibraryFixtureError.profileHasNoID }
        try roots.addRoot(profileId: secondProfileID, path: secondRoot.path)
        let downloadedFile = try downloadLibraryWriteAudioFile(
            in: destination,
            named: "Never Gonna Give You Up [\(DownloadFixture.videoID)].m4a"
        )
        let scanner = LibraryScanner(
            database: database,
            metadataReader: FakeMetadataReader(),
            excludedDirectories: [staging]
        )
        return DownloadLibraryFixture(
            database: database,
            scanner: scanner,
            guestRoot: guestRoot,
            secondRoot: secondRoot,
            destination: destination,
            staging: staging,
            downloadedFile: downloadedFile,
            secondProfileID: secondProfileID
        )
    }

    /// The file paths `profileId` can see, read through the same profile-scoped keyset
    /// query the library browser uses — so the assertion exercises the shipped
    /// visibility predicate rather than a test-local restatement of it.
    func visiblePaths(profileId: Int64) throws -> [String] {
        try TrackRepository(database).tracksPage(profileId: profileId, limit: 200).items.map(\.filePath)
    }

    func cleanUp() {
        for directory in [guestRoot, secondRoot, destination, staging] {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
