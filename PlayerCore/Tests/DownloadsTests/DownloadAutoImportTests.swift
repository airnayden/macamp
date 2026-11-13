// The auto-import switch, driven through the real queue rather than around it.
//
// `DownloadLibraryImportTests` proves the import mechanism when the listener has asked
// for it. This suite proves the other three states the switch can be in — off, on, and
// flipped while the app is running — and it drives them through the SAME
// `DownloadLibraryImporter` the composition root wires, a real `DownloadQueueService`, a
// real `LibraryScanner` and a real migrated database.
//
// The load-bearing assertion in every case is `scanSummaries`, which records only the
// scans that ACTUALLY RAN. A gate that merely discarded the result afterwards would
// still walk the destination file and still write a `track` row, so counting rows in the
// database is what tells a real gate apart from a cosmetic one — and every case here
// checks both.
import Foundation
import Persistence
import PlayerCoreTestSupport
import Services
import Testing

@Suite(.serialized)
struct DownloadAutoImportTests {
    /// OFF: the file lands, the seam fires, and NOTHING is scanned or imported.
    ///
    /// `recorder.finished.count == 1` is the control. Without it a zero scan count could
    /// equally mean the download never completed, which would make the test pass for a
    /// reason that has nothing to do with the switch.
    @Test("with auto-import off a finished download runs no scan and enters no library")
    func autoImportOffRunsNoScanAtAll() async throws {
        let fixture = try DownloadLibraryFixture.make()
        defer { fixture.cleanUp() }
        let rig = await DownloadLibraryImportRig(
            scanner: fixture.scanner,
            destination: fixture.destination,
            staging: fixture.staging,
            finishedFiles: [fixture.downloadedFile],
            isAutoImportEnabled: { false }
        )

        let url = try downloadTestURL(DownloadFixture.watchURL)
        _ = await rig.service.enqueue(urls: [url])
        await rig.waitForImportDecisions(1)

        #expect(await rig.scanSummaries.isEmpty)
        #expect(rig.recorder.finished.map(\.fileURL) == [fixture.downloadedFile])
        #expect(try fixture.visiblePaths(profileId: ProfileRecord.guestID).isEmpty)
    }

    /// ON: exactly one scan, of exactly the one file the engine reported.
    ///
    /// The summary equality is what pins "one FILE scan" rather than "one scan": a
    /// `.directory` request over the destination would report the same `added: 1` here,
    /// but `DownloadLibraryImporter` can only issue `.files([url])`, and the imported
    /// path is asserted to be that url.
    @Test("with auto-import on a finished download runs exactly one file scan")
    func autoImportOnRunsExactlyOneFileScan() async throws {
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
        #expect(try fixture.visiblePaths(profileId: ProfileRecord.guestID)
            == [fixture.downloadedFile.path])
    }

    /// Flipping the switch mid-session reaches the NEXT finished item, with no relaunch
    /// and nothing rebuilt — the whole reason the enablement is a provider closure the
    /// importer re-reads rather than a `Bool` captured when the queue was assembled.
    ///
    /// The two downloads are enqueued one at a time and each is fenced on its own import
    /// decision, so the flip provably lands between them. Racing a flip against a
    /// two-item drain would test the scheduler, not the switch.
    @Test("flipping auto-import on reaches the next finished item without a relaunch")
    func flippingTheSwitchReachesTheNextFinishedItem() async throws {
        let fixture = try DownloadLibraryFixture.make()
        defer { fixture.cleanUp() }
        let second = try downloadLibraryWriteAudioFile(
            in: fixture.destination,
            named: "Gangnam Style [\(DownloadFixture.otherVideoID)].m4a"
        )
        let enabled = DownloadAutoImportSwitch(isOn: false)
        let rig = await DownloadLibraryImportRig(
            scanner: fixture.scanner,
            destination: fixture.destination,
            staging: fixture.staging,
            finishedFiles: [fixture.downloadedFile, second],
            videoIDs: [DownloadFixture.videoID, DownloadFixture.otherVideoID],
            isAutoImportEnabled: { enabled.isOn }
        )
        let urls = try [
            downloadTestURL(DownloadFixture.watchURL),
            downloadTestURL(DownloadFixture.otherWatchURL),
        ]

        _ = await rig.service.enqueue(urls: [urls[0]])
        await rig.waitForImportDecisions(1)
        #expect(await rig.scanSummaries.isEmpty)

        enabled.isOn = true
        _ = await rig.service.enqueue(urls: [urls[1]])
        await rig.waitForImportDecisions(2)

        #expect(await rig.scanSummaries == [ScanSummary(added: 1)])
        #expect(try fixture.visiblePaths(profileId: ProfileRecord.guestID) == [second.path])
    }
}

/// The listener's switch, as a value the `@Sendable` provider closure can read.
///
/// Lock-guarded because the importer's provider is `@Sendable` by contract, mirroring
/// how `AppEnvironment+Downloads.swift` feeds it from an `OSAllocatedUnfairLock` box.
final class DownloadAutoImportSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool

    init(isOn: Bool) {
        value = isOn
    }

    var isOn: Bool {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
