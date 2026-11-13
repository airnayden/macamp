// ListeningStatsHarness — fixtures, seeding and counting spies for the listening-stats
// view-model suite.
//
// Split out of `ListeningStatsViewModelTests.swift` for the same reason
// `ListeningDigestHarness.swift` sits beside its own suite: the assertions and the
// scaffolding that feeds them are read at different times, and one file carrying both
// had reached the 400-line ceiling.
import Foundation
import GRDB
import os
import Persistence
import PlayerCoreTestSupport
import Services
import Testing
import ViewModels

/// 2026-07-25T00:00:00Z — the pinned instant every window is measured back from.
let pinnedNow: Double = 1_784_937_600
let guestId = ProfileRecord.guestID
let otherProfileId: Int64 = 2
let spikeBuckets: [UInt32] = (0 ..< PlaySegmentHeatRecord.bucketCount).map { $0 == 50 ? 100 : 0 }

func daysAgo(_ days: Int) -> Double {
    pinnedNow - Double(days) * 86400
}

func flatBuckets(_ value: UInt32) -> [UInt32] {
    [UInt32](repeating: value, count: PlaySegmentHeatRecord.bucketCount)
}

func identityKey(_ title: String) -> String {
    ListeningTrackIdentity(artistName: "Artist", title: title, albumTitle: "Album").identityKey
}

struct EventSeed {
    var trackId: Int64?
    var title: String? = "Title"
    var startedAt: Double
    var completion: Double = 1
}

struct Harness {
    let model: ListeningStatsViewModel
    let digest: SpyDigest
    let repositories: SpyRepositories
}

@MainActor
func makeHarness(_ database: AppDatabase, gate: Gate? = nil, gated: Int64? = nil) -> Harness {
    let repositories = SpyRepositories(database)
    let digest = SpyDigest(repositories, gate: gate, gatedProfileId: gated)
    let tracks = TrackRepository(database)
    let model = ListeningStatsViewModel(digestBuilder: digest, events: repositories, heat: repositories, tracks: tracks)
    return Harness(model: model, digest: digest, repositories: repositories)
}

func insertTrack(_ database: AppDatabase, trackId: Int64, title: String) throws {
    var record = TrackRecord(id: trackId, filePath: "/Music/\(trackId).flac", title: title, artistName: "Artist")
    try database.writer.write { db in try record.insert(db) }
}

func insertEvent(_ database: AppDatabase, _ seed: EventSeed, times: Int = 1) throws {
    for offset in 0 ..< times {
        let startedAt = seed.startedAt - Double(offset) * 86400
        var record = PlayEventRecord(profileId: guestId, startedAt: startedAt, utcOffsetSeconds: 0)
        record.trackId = seed.trackId
        record.artistName = "Artist"
        record.title = seed.title
        record.albumTitle = "Album"
        record.completionFraction = seed.completion
        try database.writer.write { db in try record.insert(db) }
    }
}

func insertHeat(_ database: AppDatabase, trackId: Int64, buckets: [UInt32], passes: Int) throws {
    var record = try PlaySegmentHeatRecord(
        profileId: guestId,
        trackId: trackId,
        durationSeconds: 250,
        bucketCounts: PlaySegmentHeatRecord.encodeBuckets(buckets),
        totalPasses: passes,
        updatedAt: pinnedNow
    )
    record.title = "Song \(trackId)"
    try database.writer.write { db in try record.insert(db) }
}

func seedBasicHistory(_ database: AppDatabase) throws {
    for index in 1 ... 3 {
        try insertTrack(database, trackId: Int64(index), title: "Song \(index)")
        try insertEvent(database, EventSeed(trackId: Int64(index), title: "Song \(index)", startedAt: daysAgo(index)))
    }
    try insertHeat(database, trackId: 1, buckets: spikeBuckets, passes: 5)
    try insertHeat(database, trackId: 2, buckets: flatBuckets(3), passes: 4)
    try insertHeat(database, trackId: 3, buckets: flatBuckets(2), passes: 2)
}

/// Fifty-one distinct two-play identities, all older than the thirty-day window.
func seedCrowdedHistory(_ database: AppDatabase) throws {
    for filler in 0 ..< 51 {
        let seed = EventSeed(trackId: Int64(1000 + filler), title: "Filler \(filler)", startedAt: daysAgo(100))
        try insertEvent(database, seed, times: 2)
    }
}

/// An array's element buffer: a rebuilt array allocates a fresh one, and the original
/// stays retained here so the address cannot be reused. Compared, never dereferenced.
func bufferAddress(_ array: [some Any]) -> UnsafeRawPointer? {
    array.withUnsafeBufferPointer { UnsafeRawPointer($0.baseAddress) }
}

typealias EventPage = Page<PlayEventRecord, Double>
typealias RollupPage = Page<PlayEventRollupRecord, String>
typealias HeatPage = Page<PlaySegmentHeatRecord, Int64>

/// ``isOpen`` is load-bearing: the test may open the gate before the stalled task
/// reaches ``wait()``, and that ordering would otherwise deadlock.
actor Gate {
    private var waiter: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func open() {
        isOpen = true
        waiter?.resume()
        waiter = nil
    }
}

final class SpyDigest: ListeningDigestBuilding {
    private let counter = OSAllocatedUnfairLock(initialState: 0)
    private let wrapped: ListeningDigestBuilder
    private let gate: Gate?
    private let gatedProfileId: Int64?

    var calls: Int {
        counter.withLock { $0 }
    }

    init(_ repositories: SpyRepositories, gate: Gate?, gatedProfileId: Int64?) {
        let clock = FakeClock(epochSeconds: pinnedNow)
        wrapped = ListeningDigestBuilder(events: repositories, heat: repositories, now: clock.nowProvider)
        self.gate = gate
        self.gatedProfileId = gatedProfileId
    }

    func buildDigest(profileId: Int64) async throws -> ListeningDigest {
        counter.withLock { $0 += 1 }
        if let gate, profileId == gatedProfileId {
            await gate.wait()
        }
        return try await wrapped.buildDigest(profileId: profileId)
    }
}

final class SpyRepositories: PlayEventRepositoryProviding, PlaySegmentHeatRepositoryProviding {
    private let counter = OSAllocatedUnfairLock(initialState: 0)
    private let events: PlayEventRepository
    private let heat: PlaySegmentHeatRepository

    var calls: Int {
        counter.withLock { $0 }
    }

    init(_ database: AppDatabase) {
        events = PlayEventRepository(database)
        heat = PlaySegmentHeatRepository(database)
    }

    private func counted<Value>(_ value: Value) -> Value {
        counter.withLock { $0 += 1 }
        return value
    }

    func insertPlayEvent(_ event: PlayEventRecord) async throws -> Int64 {
        try await counted(events.insertPlayEvent(event))
    }

    func playEvents(profileId: Int64, before: PageCursor<Double>?, limit: Int) async throws -> EventPage {
        try await counted(events.playEvents(profileId: profileId, before: before, limit: limit))
    }

    func rollups(profileId: Int64, after: PageCursor<String>?, limit: Int) async throws -> RollupPage {
        try await counted(events.rollups(profileId: profileId, after: after, limit: limit))
    }

    func deleteEventsOlderThan(_ cutoff: TimeInterval, profileId: Int64, limit: Int) async throws -> Int {
        try await counted(events.deleteEventsOlderThan(cutoff, profileId: profileId, limit: limit))
    }

    func upsertRollup(_ rollup: PlayEventRollupRecord) async throws {
        try await counted(events.upsertRollup(rollup))
    }

    func trackPlayStats(profileId: Int64, trackId: Int64) async throws -> TrackPlayStats? {
        try await counted(events.trackPlayStats(profileId: profileId, trackId: trackId))
    }

    func topTrackIds(profileId: Int64, since: TimeInterval, limit: Int) async throws -> [TopTrackId] {
        try await counted(events.topTrackIds(profileId: profileId, since: since, limit: limit))
    }

    func segmentHeat(profileId: Int64, trackId: Int64) async throws -> PlaySegmentHeatRecord? {
        try await counted(heat.segmentHeat(profileId: profileId, trackId: trackId))
    }

    func mergeSegmentHeat(
        profileId _: Int64,
        trackId _: Int64,
        identity _: PlaySegmentIdentity,
        deltas _: [UInt32],
        updatedAt _: TimeInterval
    ) async throws {
        counter.withLock { $0 += 1 }
    }

    func allSegmentHeat(profileId: Int64, after: PageCursor<Int64>?, limit: Int) async throws -> HeatPage {
        try await counted(heat.allSegmentHeat(profileId: profileId, after: after, limit: limit))
    }
}
