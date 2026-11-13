// The recorder's own contract, driven over a REAL migrated in-memory database.
//
// A `FakeDownloadHistoryRepository` would let every assertion below pass over a
// recorder that never spoke SQL at all, so these read the rows back through the
// shipped ``DownloadHistoryRepository`` — the same type the composition root builds.
// The two doubles that DO appear here exist to inject a FAILURE, which a real GRDB
// writer will not produce on demand.
import Foundation
import Persistence
import Services
import Testing

@MainActor
@Suite("Download history recorder")
struct DownloadHistoryRecorderTests {
    /// The mapping in full: every descriptive field comes from the item, the format
    /// pair from its stamp, and the instant from the injected clock.
    ///
    /// The fallback format is deliberately a DIFFERENT container and quality from the
    /// stamped one, so a recorder that consulted the setting instead of the row would
    /// be caught by the format columns rather than pass on a coincidence.
    @Test("a finished item becomes one row carrying its enriched fields and its stamp")
    func finishedItemBecomesAnEnrichedRow() async throws {
        let rig = try DownloadHistoryRig(
            now: Date(timeIntervalSince1970: 1_700_000_000),
            timeZone: #require(TimeZone(secondsFromGMT: 7200)),
            fallbackFormat: .audio(.flac, .medium)
        )
        let item = DownloadHistoryRig.item(
            title: "Caminandes 3: Llamigos",
            uploader: "Blender",
            durationSeconds: 150,
            resolvedFormat: .audio(.mp3, .high)
        )

        rig.recorder.record(item, at: URL(fileURLWithPath: "/tmp/downloads/Llamigos [\(item.canonicalVideoID)].mp3"))
        await rig.recorder.flushAndWait()

        let rows = try await rig.rows()
        let row = try #require(rows.first)
        #expect(row.canonicalVideoID == item.canonicalVideoID)
        #expect(row.title == "Caminandes 3: Llamigos")
        #expect(row.uploader == "Blender")
        #expect(row.durationSeconds == 150)
        #expect(row.filePath == "/tmp/downloads/Llamigos [\(item.canonicalVideoID)].mp3")
        #expect(row.sourceURL == item.sourceURL.absoluteString)
        #expect(row.audioFormat == "mp3")
        #expect(row.audioQuality == "high")
        #expect(row.downloadedAt == 1_700_000_000)
        #expect(row.utcOffsetSeconds == 7200)
    }

    /// The offset is the zone's offset FOR THE CAPTURED INSTANT, not a constant.
    ///
    /// Two records taken either side of a daylight-saving boundary in the same zone
    /// must therefore disagree. A recorder that stamped `secondsFromGMT` with no date
    /// would report the same number twice.
    @Test("the UTC offset is resolved for the capture instant, not for 'now'")
    func offsetFollowsTheCaptureInstant() async throws {
        let zone = try #require(TimeZone(identifier: "Europe/Sofia"))
        let winter = Date(timeIntervalSince1970: 1_704_067_200) // 2024-01-01, EET  (+2h)
        let summer = Date(timeIntervalSince1970: 1_719_792_000) // 2024-07-01, EEST (+3h)
        let clock = DownloadHistoryClockBox(winter)
        let rig = try DownloadHistoryRig(clock: clock, timeZone: zone)

        rig.recorder.record(DownloadHistoryRig.item(videoID: "winterVideo"), at: DownloadHistoryRig.anyFile)
        clock.advance(to: summer)
        rig.recorder.record(DownloadHistoryRig.item(videoID: "summerVideo"), at: DownloadHistoryRig.anyFile)
        await rig.recorder.flushAndWait()

        let byVideo = try await rig.rowsByVideoID()
        let winterRow = try #require(byVideo["winterVideo"])
        let summerRow = try #require(byVideo["summerVideo"])
        #expect(winterRow.utcOffsetSeconds == 7200)
        #expect(summerRow.utcOffsetSeconds == 10800)
    }

    /// The defensive path. `stampResolvedFormat` runs immediately before the transfer
    /// spawns, so no shipped finish can reach this — but dropping the row instead
    /// would lose a download that really happened, so the setting answers and the
    /// recorder warns.
    @Test("a finished item with no stamped format falls back to the configured one")
    func unstampedItemFallsBackToTheConfiguredFormat() async throws {
        let rig = try DownloadHistoryRig(fallbackFormat: .audio(.opus, .medium))

        rig.recorder.record(DownloadHistoryRig.item(resolvedFormat: nil), at: DownloadHistoryRig.anyFile)
        await rig.recorder.flushAndWait()

        let row = try #require(await rig.rows().first)
        #expect(row.audioFormat == "opus")
        #expect(row.audioQuality == "medium")
    }

    /// The fallback is read AT CAPTURE, so it reports the setting in force when the
    /// download finished rather than whatever it was when the recorder was built.
    @Test("the fallback format is re-read per record, never captured at construction")
    func theFallbackIsReReadPerRecord() async throws {
        let box = DownloadHistoryFormatBox(.audio(.m4a, .best))
        let rig = try DownloadHistoryRig(fallbackFormatProvider: { box.value })

        rig.recorder.record(
            DownloadHistoryRig.item(videoID: "firstVideo0", resolvedFormat: nil),
            at: DownloadHistoryRig.anyFile
        )
        box.value = .audio(.flac, .high)
        rig.recorder.record(
            DownloadHistoryRig.item(videoID: "otherVideo0", resolvedFormat: nil),
            at: DownloadHistoryRig.anyFile
        )
        await rig.recorder.flushAndWait()

        let byVideo = try await rig.rowsByVideoID()
        #expect(try #require(byVideo["firstVideo0"]).audioFormat == "m4a")
        #expect(try #require(byVideo["otherVideo0"]).audioFormat == "flac")
    }

    /// N records taken in one main-actor turn — the shape N parallel finishes produce —
    /// all land, each as its own row with its own primary key.
    @Test("every record lands: N in one turn become N distinct rows")
    func everyRecordLands() async throws {
        let rig = try DownloadHistoryRig()
        let videoIDs = (0 ..< 12).map { "parallelV\($0)" }

        for videoID in videoIDs {
            rig.recorder.record(DownloadHistoryRig.item(videoID: videoID), at: DownloadHistoryRig.anyFile)
        }
        await rig.recorder.flushAndWait()

        let rows = try await rig.rows()
        #expect(rows.count == videoIDs.count)
        #expect(Set(rows.map(\.canonicalVideoID)) == Set(videoIDs))
        #expect(Set(rows.map(\.id)).count == videoIDs.count)
    }

    /// A failing insert leaves NO row and does not poison the chain.
    ///
    /// The write is one statement inside GRDB's own transaction, so "no partial row"
    /// is the writer's guarantee rather than the recorder's — what IS the recorder's
    /// is that the throw is absorbed. A recorder that let it escape would take the
    /// serial tail down with it and silently stop recording for the rest of the run.
    @Test("a failing insert writes nothing and the next record still lands")
    func aFailingInsertIsAbsorbed() async throws {
        let database = try AppDatabase.makeEmpty()
        let repository = DownloadHistoryRepository(database)
        let rig = try DownloadHistoryRig(
            database: database,
            history: FailingFirstDownloadHistoryRepository(wrapping: repository)
        )

        rig.recorder.record(DownloadHistoryRig.item(videoID: "refusedVid0"), at: DownloadHistoryRig.anyFile)
        rig.recorder.record(DownloadHistoryRig.item(videoID: "acceptedVi0"), at: DownloadHistoryRig.anyFile)
        await rig.recorder.flushAndWait()

        let rows = try await rig.rows()
        #expect(rows.map(\.canonicalVideoID) == ["acceptedVi0"])
    }

    /// The transactional claim, bound where the guarantee actually lives: a refused
    /// insert rolls back whole, leaving the table exactly as it was.
    ///
    /// A duplicate primary key is the one failure a real GRDB writer can be made to
    /// produce on demand, and the recorder mints its own UUID, so this drives the
    /// repository directly — asserting it through the recorder would be asserting a
    /// state the recorder cannot reach.
    @Test("a refused insert leaves the table byte-identical: no partial row")
    func aRefusedInsertLeavesNoPartialRow() async throws {
        let database = try AppDatabase.makeEmpty()
        let repository = DownloadHistoryRepository(database)
        let original = DownloadHistoryRig.record(id: "shared-id", videoID: "originalVi0", title: "Original")
        try await repository.insert(original)

        let collision = DownloadHistoryRig.record(id: "shared-id", videoID: "collidingV0", title: "Collision")
        await #expect(throws: (any Error).self) {
            try await repository.insert(collision)
        }

        let rows = try await repository.entries(before: nil, limit: 50).items
        #expect(rows == [original])
    }
}

// MARK: - Rig

/// A recorder over a real migrated in-memory database, plus read-back helpers.
@MainActor
struct DownloadHistoryRig {
    let repository: DownloadHistoryRepository
    let recorder: DownloadHistoryRecorder

    init(
        database: AppDatabase? = nil,
        history: (any DownloadHistoryRepositoryProviding)? = nil,
        clock: DownloadHistoryClockBox? = nil,
        now: Date = Date(timeIntervalSince1970: 1_600_000_000),
        timeZone: TimeZone = TimeZone(secondsFromGMT: 0) ?? .gmt,
        fallbackFormat: DownloadFormat = .default,
        fallbackFormatProvider: (@Sendable () -> DownloadFormat)? = nil
    ) throws {
        let database = try database ?? AppDatabase.makeEmpty()
        repository = DownloadHistoryRepository(database)
        let clockBox = clock ?? DownloadHistoryClockBox(now)
        recorder = DownloadHistoryRecorder(
            history: history ?? repository,
            fallbackFormat: fallbackFormatProvider ?? { fallbackFormat },
            now: { clockBox.value },
            timeZone: timeZone
        )
    }

    /// Every row, newest first, read through the shipped keyset page.
    func rows(limit: Int = 100) async throws -> [DownloadHistoryRecord] {
        try await repository.entries(before: nil, limit: limit).items
    }

    /// Every row keyed by its canonical video id — the assertion shape for tests whose
    /// rows share a timestamp, where ordering is a property of the rowid rather than
    /// something the test may claim.
    func rowsByVideoID() async throws -> [String: DownloadHistoryRecord] {
        try await Dictionary(rows().map { ($0.canonicalVideoID, $0) }, uniquingKeysWith: { first, _ in first })
    }

    static let anyFile = URL(fileURLWithPath: "/tmp/macamp-downloads/Track.m4a")

    static func item(
        videoID: String = DownloadFixture.videoID,
        title: String? = nil,
        uploader: String? = nil,
        durationSeconds: Int? = nil,
        resolvedFormat: DownloadFormat? = .default
    ) -> DownloadItem {
        DownloadItem(
            canonicalVideoID: videoID,
            sourceURL: URL(fileURLWithPath: "/").appendingPathComponent(videoID),
            title: title,
            uploader: uploader,
            durationSeconds: durationSeconds,
            resolvedFormat: resolvedFormat,
            state: .finished(fileURL: anyFile)
        )
    }

    static func record(id: String, videoID: String, title: String) -> DownloadHistoryRecord {
        DownloadHistoryRecord(
            id: id,
            canonicalVideoID: videoID,
            title: title,
            filePath: anyFile.path,
            audioFormat: "m4a",
            audioQuality: "best",
            sourceURL: "https://example.invalid/\(videoID)",
            downloadedAt: 1_600_000_000,
            utcOffsetSeconds: 0
        )
    }
}

/// A clock a test can move between records.
final class DownloadHistoryClockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Date

    init(_ value: Date) {
        stored = value
    }

    var value: Date {
        lock.withLock { stored }
    }

    func advance(to date: Date) {
        lock.withLock { stored = date }
    }
}

/// A configured format a test can change between records.
final class DownloadHistoryFormatBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: DownloadFormat

    init(_ value: DownloadFormat) {
        stored = value
    }

    var value: DownloadFormat {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// Refuses the first insert and delegates every one after it.
///
/// Wraps the REAL repository rather than standing in for it, so "the refused row is
/// absent" is read out of the same database the accepted row went into.
struct FailingFirstDownloadHistoryRepository: DownloadHistoryRepositoryProviding {
    enum Refusal: Error {
        case refused
    }

    private let wrapped: DownloadHistoryRepository
    private let refusalsRemaining = DownloadHistoryCountdown(1)

    init(wrapping wrapped: DownloadHistoryRepository) {
        self.wrapped = wrapped
    }

    func insert(_ entry: DownloadHistoryRecord) async throws {
        guard !refusalsRemaining.consume() else { throw Refusal.refused }
        try await wrapped.insert(entry)
    }

    func entries(
        before cursor: PageCursor<Double>?,
        limit: Int
    ) async throws -> Page<DownloadHistoryRecord, Double> {
        try await wrapped.entries(before: cursor, limit: limit)
    }

    @discardableResult
    func delete(id: String) async throws -> Bool {
        try await wrapped.delete(id: id)
    }

    @discardableResult
    func deleteAll() async throws -> Int {
        try await wrapped.deleteAll()
    }

    func latestEntry(canonicalVideoID: String) async throws -> DownloadHistoryRecord? {
        try await wrapped.latestEntry(canonicalVideoID: canonicalVideoID)
    }

    func knownVideoIDs(in ids: [String]) async throws -> Set<String> {
        try await wrapped.knownVideoIDs(in: ids)
    }
}

/// Answers `true` for its first `count` callers and `false` forever after.
final class DownloadHistoryCountdown: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int

    init(_ count: Int) {
        remaining = count
    }

    func consume() -> Bool {
        lock.withLock {
            guard remaining > 0 else { return false }
            remaining -= 1
            return true
        }
    }
}
