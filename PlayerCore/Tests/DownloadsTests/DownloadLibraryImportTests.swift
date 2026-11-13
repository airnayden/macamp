// The ADOPTED library-integration mechanism, proven end to end: the downloads folder is
// NOT a library root, its intermediates are never walked, and a finished file reaches
// every profile through one explicit file scan.
//
// These are `Services`-level tests on purpose. The wiring itself lives in the macOS
// shell (`AppEnvironment+Downloads.swift`), which `swift test` cannot reach, so what is
// covered here is the PlayerCore contract that wiring stands on — the same disposition
// SKILL.md records for the app-shell watch service.
import Foundation
import Metadata
import Persistence
import PlayerCoreTestSupport
import Services
import Testing

@Suite(.serialized)
struct DownloadLibraryImportTests {
    /// The exclusion, with its own control.
    ///
    /// A yt-dlp intermediate looks exactly like a finished download — `Ghost [abc].m4a`
    /// is a name the engine really writes — so the only thing keeping it out of the
    /// library is the scanner exclusion. The control scan proves the file IS importable
    /// audio, which is what makes the excluded run's zero a statement about the
    /// exclusion rather than about the fixture.
    @Test("a ghost in the staging directory is never walked, even by a scan of its parent")
    func stagingGhostIsNeverImportedByADirectoryScan() async throws {
        let applicationSupport = try downloadLibraryTempDirectory("appsupport")
        defer { try? FileManager.default.removeItem(at: applicationSupport) }
        let staging = DownloadStagingLocation.directory(inApplicationSupport: applicationSupport)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try downloadLibraryWriteAudioFile(in: staging, named: "Ghost [abc].m4a")

        let controlDatabase = try AppDatabase.makeEmpty()
        let control = LibraryScanner(database: controlDatabase, metadataReader: FakeMetadataReader())
        #expect(await control.scan(.directory(applicationSupport)) == ScanSummary(added: 1))

        let database = try AppDatabase.makeEmpty()
        let scanner = LibraryScanner(
            database: database,
            metadataReader: FakeMetadataReader(),
            excludedDirectories: [staging]
        )

        let summary = await scanner.scan(.directory(applicationSupport))

        #expect(summary == ScanSummary())
        let paths = try await database.writer.read { db in try TrackRecord.fetchAll(db).map(\.filePath) }
        #expect(paths.isEmpty)
    }

    /// The whole adopted mechanism in one test.
    ///
    /// Two profiles own DIFFERENT library roots, and the downloads folder is under
    /// neither — so `LibraryVisibility`'s predicate is fully populated (a root set of one
    /// would let a trivially-`"1"` predicate pass by accident) and the imported track can
    /// only be visible through the ownerless clause. The seam fires ONE
    /// `scan(.files([url]))` for the file the engine reported, and both profiles see it.
    ///
    /// Auto-import is stated explicitly rather than defaulted: it ships OFF, so a rig
    /// that assumed it would make this suite describe a configuration nobody has.
    @Test("a finished download imports by explicit file scan and is visible to every profile")
    func finishedDownloadImportsOnceAndIsVisibleToEveryProfile() async throws {
        let fixture = try DownloadLibraryFixture.make()
        defer { fixture.cleanUp() }
        let rig = await DownloadLibraryImportRig(
            scanner: fixture.scanner,
            destination: fixture.destination,
            staging: fixture.staging,
            finishedFiles: [fixture.downloadedFile],
            isAutoImportEnabled: { true }
        )

        let url = try downloadTestURL(DownloadFixture.watchURL)
        _ = await rig.service.enqueue(urls: [url])
        await rig.waitForImportDecisions(1)

        #expect(await rig.scanSummaries == [ScanSummary(added: 1)])
        #expect(rig.recorder.finished.map(\.fileURL) == [fixture.downloadedFile])
        let guestPaths = try fixture.visiblePaths(profileId: ProfileRecord.guestID)
        let secondPaths = try fixture.visiblePaths(profileId: fixture.secondProfileID)
        #expect(guestPaths.contains(fixture.downloadedFile.path))
        #expect(secondPaths.contains(fixture.downloadedFile.path))
    }

    /// The negative control for the test above: a file under ONE profile's root is
    /// visible to that profile alone.
    ///
    /// Without this, "both profiles see it" could be explained by the visibility
    /// predicate being inert in this fixture rather than by the ownerless clause.
    @Test("a file under one profile's root stays invisible to the other")
    func ownedFileIsNotVisibleToTheOtherProfile() async throws {
        let fixture = try DownloadLibraryFixture.make()
        defer { fixture.cleanUp() }
        let owned = try downloadLibraryWriteAudioFile(in: fixture.guestRoot, named: "Guest Only.m4a")

        #expect(await fixture.scanner.scan(.files([owned])) == ScanSummary(added: 1))

        let guestPaths = try fixture.visiblePaths(profileId: ProfileRecord.guestID)
        let secondPaths = try fixture.visiblePaths(profileId: fixture.secondProfileID)
        #expect(guestPaths.contains(owned.path))
        #expect(!secondPaths.contains(owned.path))
    }
}
