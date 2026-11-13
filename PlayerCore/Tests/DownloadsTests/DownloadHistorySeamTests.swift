// Runs the real queue and history recorder against scripted engine results.
import Foundation
import Persistence
import PlayerCoreTestSupport
import Services
import Testing

@MainActor
@Suite("Download history seam")
struct DownloadHistorySeamTests {
    /// The shipped path: a finished download becomes exactly one row, and the fields it
    /// carries are the ENRICHED ones.
    ///
    /// `applyOutcome` re-reads the row out of `active` before it fires, so the copy the
    /// seam hands over has already been through `-J` enrichment and the format stamp.
    /// Title, uploader and duration are asserted against the `-J` document rather than
    /// merely against non-`nil`, because a recorder reading a pre-enrichment copy would
    /// still produce a row — one whose title is the bare canonical id.
    ///
    /// The rig's fallback format is deliberately `flac/medium` while the queue runs
    /// `m4a/best`, so the two format columns distinguish the stamp from the setting.
    @Test("a finished download lands one row carrying its enriched fields and its stamp")
    func aFinishedDownloadLandsOneEnrichedRow() async throws {
        let rig = try DownloadHistorySeamRig(fallbackFormat: .audio(.flac, .medium))
        let harness = DownloadQueueHarness(scripts: [
            DownloadFixture.infoScript(),
            DownloadFixture.happyDownloadScript,
        ])
        rig.chain(onto: harness.service)
        let url = try downloadTestURL(DownloadFixture.watchURL)

        _ = await harness.service.enqueue(urls: [url])
        await harness.waitForTerminals(1)
        await rig.recorder.flushAndWait()

        // The handler the harness installed FIRST still ran: chaining added a link, it
        // did not replace one. This is the `wireDownloadSeams` contract, restated where
        // a regression would be visible.
        #expect(harness.recorder.finished.count == 1)

        let rows = try await rig.rows()
        #expect(rows.count == 1)
        let row = try #require(rows.first)
        #expect(row.canonicalVideoID == DownloadFixture.videoID)
        #expect(row.title == "Never Gonna Give You Up")
        #expect(row.uploader == "Rick Astley")
        #expect(row.durationSeconds == 213)
        #expect(row.filePath == DownloadFixture.finishedPath)
        #expect(row.audioFormat == "m4a")
        #expect(row.audioQuality == "best")
        #expect(row.sourceURL == DownloadFixture.watchURL)
    }

    @Test("a failed download records one retryable history row")
    func aFailedDownloadRecordsHistory() async throws {
        let rig = try DownloadHistorySeamRig()
        let harness = DownloadQueueHarness(scripts: [
            DownloadFixture.infoScript(),
            .exit(status: 1, stderr: ["ERROR: video unavailable"]),
        ])
        rig.chain(onto: harness.service)
        let url = try downloadTestURL(DownloadFixture.watchURL)

        _ = await harness.service.enqueue(urls: [url])
        await harness.waitForTerminals(1)
        await rig.recorder.flushAndWait()

        let id = try harness.firstEnqueuedID()
        let terminal = try #require(harness.recorder.states(of: id).last)
        #expect(terminal.isTerminal)
        if case let .failed(error) = terminal {
            #expect(error == .downloadFailed(detail: "ERROR: video unavailable"))
        } else {
            Issue.record("expected a failure, got \(terminal)")
        }
        #expect(harness.recorder.finished.isEmpty)
        let rows = try await rig.rows()
        let row = try #require(rows.first)
        #expect(rows.count == 1)
        #expect(row.canonicalVideoID == DownloadFixture.videoID)
        #expect(row.title == "Never Gonna Give You Up")
        #expect(row.sourceURL == DownloadFixture.watchURL)
        #expect(row.filePath.isEmpty)
        #expect(row.failureReason?.contains("ERROR: video unavailable") == true)
        #expect(try await rig.repository.latestEntry(canonicalVideoID: row.canonicalVideoID) == nil)
        #expect(try await rig.repository.knownVideoIDs(in: [row.canonicalVideoID]).isEmpty)
    }

    /// A cancelled download records nothing.
    ///
    /// Driven on `VideoScriptedRunner` because cancellation there is the proven shape
    /// (`DownloadQueueSemanticsTests.cancelStopsExactlyOneRow`): the cancel rides the
    /// `onItemProgress` seam, which the driver awaits before reading the next engine
    /// line, so the interruption lands mid-transfer with no sleep to race.
    @Test("a cancelled download records no history row")
    func aCancelledDownloadRecordsNothing() async throws {
        let rig = try DownloadHistorySeamRig()
        let harness = ConcurrentDownloadHarness(
            videoIDs: [DownloadFixture.videoID],
            maxConcurrent: { 1 }
        )
        rig.chain(onto: harness.service)
        let cancelled = CancelledRowBox()
        harness.cancelFirstDownloadingRow(into: cancelled)

        _ = await harness.enqueueAll()
        await harness.waitForTerminals(1)
        await rig.recorder.flushAndWait()

        #expect(cancelled.videoID == DownloadFixture.videoID)
        let id = try #require(harness.idOfRow(videoID: DownloadFixture.videoID))
        #expect(harness.recorder.states(of: id).last == .cancelled)
        #expect(harness.recorder.finished.isEmpty)
        let rows = try await rig.rows()
        #expect(rows.isEmpty)
    }

    /// The case the plan singles out: `.alreadyDownloaded` records nothing.
    ///
    /// It is the one terminal state that is reached by a CLEAN engine exit — status 0
    /// with no `MACAMP-FILE|` line, which is what re-pasting a video already sitting in
    /// the destination folder produces. That makes it the failure most likely to be
    /// mistaken for a success by a future change, and the reason it records nothing is
    /// structural rather than filtered: `applyOutcome` routes it to the `.failed` branch,
    /// which fires no `onItemFinished` at all. Asserting the terminal state AND the empty
    /// seam log AND the empty table is what pins all three links of that chain.
    ///
    /// History must never name a file that was not written on this run — the row's
    /// `filePath` would point at a file this download did not produce.
    @Test("an alreadyDownloaded outcome records no history row and fires no finish seam")
    func anAlreadyDownloadedOutcomeRecordsNothing() async throws {
        let rig = try DownloadHistorySeamRig()
        let harness = DownloadQueueHarness(scripts: [
            DownloadFixture.infoScript(),
            // A clean exit that moved no file: progress, a post-process sentinel, and
            // NO `MACAMP-FILE|` line. Deliberately not `.exit(status:)` — the whole
            // point is that the engine succeeded.
            .success(stdout: [
                DownloadFixture.quarterProgress,
                DownloadFixture.halfProgress,
                DownloadFixture.postProcessLine,
            ]),
        ])
        rig.chain(onto: harness.service)
        let url = try downloadTestURL(DownloadFixture.watchURL)

        _ = await harness.service.enqueue(urls: [url])
        await harness.waitForTerminals(1)
        await rig.recorder.flushAndWait()

        let id = try harness.firstEnqueuedID()
        #expect(harness.recorder.states(of: id).last == .failed(.alreadyDownloaded))
        #expect(harness.recorder.finished.isEmpty)
        let rows = try await rig.rows()
        #expect(rows.isEmpty)
    }

    /// Four genuinely overlapping transfers land four distinct rows — none lost, none
    /// duplicated, and none carrying a sibling's fields.
    ///
    /// The barrier is the OVERLAP PROOF, not a synchronization convenience: every row
    /// must reach it before any is released, which a serial driver can never do. A
    /// `timedOut` barrier means the rows ran one at a time, and the row count alone
    /// would not have said so.
    ///
    /// Cross-row corruption is checked per row rather than in aggregate: `filePath`,
    /// `title` and `uploader` are each derived from that row's own video id, so an
    /// interleave that mixed two rows' fields fails on the pairing even though every
    /// individual value is present and well-formed.
    @Test("four parallel finishes each land their own row")
    func parallelFinishesEachLandTheirOwnRow() async throws {
        let videoIDs = DownloadFixture.generatedIDs(count: 4)
        let barrier = TransferBarrier(count: videoIDs.count)
        let rig = try DownloadHistorySeamRig()
        let harness = ConcurrentDownloadHarness(
            videoIDs: videoIDs,
            maxConcurrent: { videoIDs.count },
            gate: { await barrier.arrive($0) }
        )
        rig.chain(onto: harness.service)

        _ = await harness.enqueueAll()
        await harness.waitForTerminals(videoIDs.count)
        await rig.recorder.flushAndWait()

        let timedOut = await barrier.timedOut
        #expect(timedOut == false)
        #expect(harness.recorder.finished.count == videoIDs.count)

        let rows = try await rig.rows()
        #expect(rows.count == videoIDs.count)
        #expect(Set(rows.map(\.canonicalVideoID)) == Set(videoIDs))
        #expect(Set(rows.map(\.id)).count == videoIDs.count)
        for row in rows {
            #expect(row.filePath == VideoScriptedRunner.finishedPath(for: row.canonicalVideoID))
            #expect(row.title == "Track \(row.canonicalVideoID)")
            #expect(row.uploader == "Uploader \(row.canonicalVideoID)")
        }
    }

    @Test("a mixed drain records successes and failures without mixing their data")
    func aMixedDrainRecordsEachAttempt() async throws {
        let videoIDs = DownloadFixture.generatedIDs(count: 3)
        let failing = videoIDs[1]
        let rig = try DownloadHistorySeamRig()
        let harness = ConcurrentDownloadHarness(
            videoIDs: videoIDs,
            terminations: [failing: ProcessTermination(status: 1, reason: .normalExit)],
            maxConcurrent: { videoIDs.count }
        )
        rig.chain(onto: harness.service)

        _ = await harness.enqueueAll()
        await harness.waitForTerminals(videoIDs.count)
        await rig.recorder.flushAndWait()

        let failedID = try #require(harness.idOfRow(videoID: failing))
        #expect(harness.recorder.states(of: failedID).last?.isTerminal == true)
        let rows = try await rig.rows()
        #expect(Set(rows.map(\.canonicalVideoID)) == Set(videoIDs))
        #expect(rows.filter { $0.failureReason != nil }.map(\.canonicalVideoID) == [failing])
        let completed = rows.filter { $0.failureReason == nil }
        #expect(completed.count == 2)
        #expect(completed.allSatisfy { $0.filePath == VideoScriptedRunner.finishedPath(for: $0.canonicalVideoID) })
    }
}

// MARK: - Rig

/// A real recorder over a real migrated in-memory database, plus the chaining helper.
@MainActor
struct DownloadHistorySeamRig {
    let repository: DownloadHistoryRepository
    let recorder: DownloadHistoryRecorder

    init(fallbackFormat: DownloadFormat = .default) throws {
        repository = try DownloadHistoryRepository(AppDatabase.makeEmpty())
        recorder = DownloadHistoryRecorder(
            history: repository,
            fallbackFormat: { fallbackFormat }
        )
    }

    /// Chains the recorder onto `service.onItemFinished`, PRESERVING whatever handler is
    /// already installed.
    ///
    /// Byte-for-byte the shape `wireDownloadSeams` uses — read the previous handler,
    /// call it first, then hop to the main actor for the recorder. Keeping the harness's
    /// own handler alive is what lets every test read both the seam log and the table,
    /// and it means a chain written as a REPLACEMENT fails here rather than silently in
    /// the shell.
    func chain(onto service: DownloadQueueService) {
        let recorder = recorder
        let previous = service.onItemFinished
        service.onItemFinished = { item, fileURL in
            previous?(item, fileURL)
            MainActor.assumeIsolated { recorder.record(item, at: fileURL) }
        }
        service.onItemFailed = { item, error in
            MainActor.assumeIsolated { recorder.recordFailure(item, error: error) }
        }
    }

    /// Every row, newest first, read through the shipped keyset page.
    func rows(limit: Int = 100) async throws -> [DownloadHistoryRecord] {
        try await repository.entries(before: nil, limit: limit).items
    }
}
