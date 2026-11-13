import Foundation
import GRDB
import Persistence
import Testing

/// Reads, writes and the keyset stale-candidate window of ``TrackLoudnessRepository``.
@Suite("TrackLoudnessRepositoryTests")
struct TrackLoudnessRepositoryTests {
    private static let analysisVersion = 1

    private static func makeLibrary(trackCount: Int = 5) throws -> AppDatabase {
        let appDB = try AppDatabase.makeEmpty()
        try appDB.writer.write { db in
            try TrackLoudnessFixtures.seedTracks(db, count: trackCount)
        }
        return appDB
    }

    @Test("upsert then read returns the same row")
    func upsertRoundTrips() async throws {
        let repository = try TrackLoudnessRepository(Self.makeLibrary())
        let record = TrackLoudnessFixtures.record(trackId: 2, integratedLUFS: -16.5)
        try await repository.upsert(record)
        #expect(try await repository.loudness(forTrackId: 2) == record)
        #expect(try await repository.loudness(forTrackId: 3) == nil)
    }

    /// Repeated upserts are what re-analysis looks like; they must replace rather than
    /// accumulate.
    @Test("upserting the same trackId twice leaves one row")
    func upsertIsIdempotentPerTrack() async throws {
        let appDB = try Self.makeLibrary()
        let repository = TrackLoudnessRepository(appDB)
        try await repository.upsert(TrackLoudnessFixtures.record(trackId: 1, integratedLUFS: -20))
        try await repository.upsert(TrackLoudnessFixtures.record(trackId: 1, integratedLUFS: -8))

        let count = try await appDB.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM trackLoudness") ?? -1
        }
        #expect(count == 1)
        #expect(try await repository.loudness(forTrackId: 1)?.integratedLUFS == -8)
    }

    /// The batch album pooling needs: a page-50 batch routinely splits an album, and a
    /// member outside the page must be pooled from its stored histogram.
    @Test("the batch read returns present ids in trackId order and skips absent ones")
    func batchReadIsOrderedAndSparse() async throws {
        let repository = try TrackLoudnessRepository(Self.makeLibrary())
        for trackId in [3, 1, 5] as [Int64] {
            try await repository.upsert(TrackLoudnessFixtures.record(trackId: trackId))
        }
        let rows = try await repository.loudness(forTrackIds: [5, 4, 3, 2, 1])
        #expect(rows.map(\.trackId) == [1, 3, 5])
        #expect(try await repository.loudness(forTrackIds: []).isEmpty)
    }

    @Test("every present track is a stale candidate before any analysis")
    func allTracksStartStale() async throws {
        let repository = try TrackLoudnessRepository(Self.makeLibrary(trackCount: 5))
        #expect(try await repository.staleCandidateCount(analysisVersion: Self.analysisVersion) == 5)
        let page = try await repository.staleCandidates(
            analysisVersion: Self.analysisVersion,
            after: nil,
            limit: 100
        )
        #expect(page.items.map(\.id) == [1, 2, 3, 4, 5])
        #expect(!page.hasMore)
    }

    @Test("a matching row removes its track from the candidate set")
    func analysedTrackStopsBeingACandidate() async throws {
        let repository = try TrackLoudnessRepository(Self.makeLibrary(trackCount: 3))
        try await repository.upsert(TrackLoudnessFixtures.record(trackId: 2))

        #expect(try await repository.staleCandidateCount(analysisVersion: Self.analysisVersion) == 2)
        let page = try await repository.staleCandidates(
            analysisVersion: Self.analysisVersion,
            after: nil,
            limit: 100
        )
        #expect(page.items.map(\.id) == [1, 3])
    }

    /// The three reasons to re-analyse, asserted through the one clause that covers
    /// them: the file changed, the analyser changed, and the segment bounds changed.
    @Test("a stale fingerprint, version or cue bound makes a track a candidate again")
    func stalenessCoversEveryReason() async throws {
        let repository = try TrackLoudnessRepository(Self.makeLibrary(trackCount: 3))
        try await repository.upsert(TrackLoudnessFixtures.record(
            trackId: 1,
            fingerprint: TrackLoudnessFixtures.fingerprint(fileSize: 999)
        ))
        try await repository.upsert(TrackLoudnessFixtures.record(trackId: 2, analysisVersion: 0))
        try await repository.upsert(TrackLoudnessFixtures.record(
            trackId: 3,
            fingerprint: TrackLoudnessFixtures.fingerprint(cueStartFrame: 0, cueEndFrame: 588)
        ))

        let page = try await repository.staleCandidates(
            analysisVersion: Self.analysisVersion,
            after: nil,
            limit: 100
        )
        #expect(page.items.map(\.id) == [1, 2, 3])
    }

    /// `track.fileSize`/`mtime` are nullable, and a bare NULL comparison is never true.
    /// Without the `COALESCE(…, 0)` sentinel on both sides such a track would be
    /// re-analysed on every pass forever.
    @Test("a track with no fingerprint terminates after one analysis")
    func nullFingerprintTerminates() async throws {
        let appDB = try AppDatabase.makeEmpty()
        try await appDB.writer.write { db in
            try db.execute(sql: "INSERT INTO track (id, filePath) VALUES (1, '/no-stat.flac')")
        }
        let repository = TrackLoudnessRepository(appDB)
        #expect(try await repository.staleCandidateCount(analysisVersion: Self.analysisVersion) == 1)

        try await repository.upsert(TrackLoudnessFixtures.record(
            trackId: 1,
            fingerprint: TrackLoudnessFixtures.fingerprint(fileSize: 0, mtime: 0)
        ))
        #expect(try await repository.staleCandidateCount(analysisVersion: Self.analysisVersion) == 0)
    }

    @Test("non-present tracks are never candidates")
    func skipsUnavailableTracks() async throws {
        let appDB = try Self.makeLibrary(trackCount: 3)
        try await appDB.writer.write { db in
            try db.execute(sql: "UPDATE track SET availability = 'missing' WHERE id = 2")
            try db.execute(sql: "UPDATE track SET availability = 'externalOffline' WHERE id = 3")
        }
        let repository = TrackLoudnessRepository(appDB)
        #expect(try await repository.staleCandidateCount(analysisVersion: Self.analysisVersion) == 1)
    }

    @Test("the candidate window pages by track id without gaps or repeats")
    func candidateWindowPagesCleanly() async throws {
        let repository = try TrackLoudnessRepository(Self.makeLibrary(trackCount: 7))
        var seen: [Int64] = []
        var cursor: PageCursor<Int64>?
        repeat {
            let page = try await repository.staleCandidates(
                analysisVersion: Self.analysisVersion,
                after: cursor,
                limit: 3
            )
            seen.append(contentsOf: page.items.compactMap(\.id))
            cursor = page.nextCursor
        } while cursor != nil
        #expect(seen == [1, 2, 3, 4, 5, 6, 7])
    }

    @Test("the page limit is clamped to the repository ceiling")
    func pageLimitIsClamped() async throws {
        let repository = try TrackLoudnessRepository(Self.makeLibrary(trackCount: 3))
        let page = try await repository.staleCandidates(
            analysisVersion: Self.analysisVersion,
            after: nil,
            limit: TrackLoudnessRepository.fetchLimit * 10
        )
        #expect(page.items.count == 3)
    }

    /// The album figures go onto every member, including one that pooled in an earlier
    /// batch, so a group can never hold two different album gains.
    @Test("album loudness is written back to every member at once")
    func albumLoudnessAppliesToWholeGroup() async throws {
        let repository = try TrackLoudnessRepository(Self.makeLibrary(trackCount: 4))
        for trackId in [1, 2, 3] as [Int64] {
            try await repository.upsert(TrackLoudnessFixtures.record(trackId: trackId))
        }
        try await repository.upsert(TrackLoudnessFixtures.record(trackId: 4, albumLUFS: -30, albumPeak: 0.1))

        try await repository.applyAlbumLoudness(trackIds: [1, 2, 3, 4], albumLUFS: -12.5, albumPeak: 1.05)

        let rows = try await repository.loudness(forTrackIds: [1, 2, 3, 4])
        #expect(rows.allSatisfy { $0.albumLUFS == -12.5 && $0.albumPeak == 1.05 })
        #expect(rows.count == 4)
    }

    @Test("an album write-back for an unanalysed member affects nothing")
    func albumLoudnessSkipsAbsentRows() async throws {
        let repository = try TrackLoudnessRepository(Self.makeLibrary(trackCount: 3))
        try await repository.upsert(TrackLoudnessFixtures.record(trackId: 1))

        try await repository.applyAlbumLoudness(trackIds: [1, 2, 3], albumLUFS: -11, albumPeak: 1)

        let rows = try await repository.loudness(forTrackIds: [1, 2, 3])
        #expect(rows.count == 1)
        #expect(rows.first?.albumLUFS == -11)
    }

    @Test("deleteAll empties the cache so the next pass re-analyses everything")
    func deleteAllRestoresEveryCandidate() async throws {
        let repository = try TrackLoudnessRepository(Self.makeLibrary(trackCount: 4))
        for trackId in [1, 2, 3, 4] as [Int64] {
            try await repository.upsert(TrackLoudnessFixtures.record(trackId: trackId))
        }
        #expect(try await repository.staleCandidateCount(analysisVersion: Self.analysisVersion) == 0)

        try await repository.deleteAll()

        #expect(try await repository.staleCandidateCount(analysisVersion: Self.analysisVersion) == 4)
        #expect(try await repository.loudness(forTrackId: 1) == nil)
    }
}
