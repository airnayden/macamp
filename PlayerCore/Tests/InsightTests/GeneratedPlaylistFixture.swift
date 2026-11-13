import Foundation
import GRDB
import os
import Persistence
import PlayerCoreTestSupport
import Services
import Testing

/// A ``PlaylistRepositoryProviding`` that counts every call and forwards it to a
/// real repository.
///
/// Counting is the point. "The master toggle is a recorded no-op" and "a fresh mix
/// costs one refresh, not two" are both assertions about calls that did NOT
/// happen — and a canned fake cannot prove the second, because the service must
/// still really create and materialise on the FIRST call for the second to have
/// anything to find.
final class SpyPlaylistRepository: PlaylistRepositoryProviding {
    struct Recording {
        var callCount = 0
        var createdNames: [String] = []
        var deletedIds: [Int64] = []
    }

    private let wrapped: PlaylistRepository
    private let state = OSAllocatedUnfairLock(initialState: Recording())

    init(_ wrapped: PlaylistRepository) {
        self.wrapped = wrapped
    }

    var recording: Recording {
        state.withLock { $0 }
    }

    private func note() {
        state.withLock { $0.callCount += 1 }
    }

    private func noteCreate(_ name: String) {
        state.withLock {
            $0.callCount += 1
            $0.createdNames.append(name)
        }
    }

    private func noteDelete(_ id: Int64) {
        state.withLock {
            $0.callCount += 1
            $0.deletedIds.append(id)
        }
    }

    func fetchPlaylist(id: Int64) throws -> PlaylistRecord? {
        note()
        return try wrapped.fetchPlaylist(id: id)
    }

    @_disfavoredOverload
    @discardableResult
    func insert(_ playlist: PlaylistRecord) throws -> PlaylistRecord {
        note()
        return try wrapped.insert(playlist)
    }

    @discardableResult
    func insert(_ playlist: PlaylistRecord) async throws -> PlaylistRecord {
        note()
        return try await wrapped.insert(playlist)
    }

    @_disfavoredOverload
    @discardableResult
    func create(named name: String, profileId: Int64) throws -> PlaylistRecord {
        noteCreate(name)
        return try wrapped.create(named: name, profileId: profileId)
    }

    @discardableResult
    func create(named name: String, profileId: Int64) async throws -> PlaylistRecord {
        noteCreate(name)
        return try await wrapped.create(named: name, profileId: profileId)
    }

    @_disfavoredOverload
    func update(_ playlist: PlaylistRecord) throws {
        note()
        try wrapped.update(playlist)
    }

    func update(_ playlist: PlaylistRecord) async throws {
        note()
        try await wrapped.update(playlist)
    }

    @_disfavoredOverload
    @discardableResult
    func deletePlaylist(id: Int64) throws -> Bool {
        noteDelete(id)
        return try wrapped.deletePlaylist(id: id)
    }

    @discardableResult
    func deletePlaylist(id: Int64) async throws -> Bool {
        noteDelete(id)
        return try await wrapped.deletePlaylist(id: id)
    }

    func playlistsPage(
        profileId: Int64,
        after cursor: PageCursor<String>?,
        limit: Int
    ) throws -> Page<PlaylistRecord, String> {
        note()
        return try wrapped.playlistsPage(profileId: profileId, after: cursor, limit: limit)
    }

    @_disfavoredOverload
    func playlistsWithTrackCounts(
        profileId: Int64,
        after cursor: PageCursor<String>?,
        limit: Int
    ) throws -> Page<PlaylistWithTrackCount, String> {
        note()
        return try wrapped.playlistsWithTrackCounts(profileId: profileId, after: cursor, limit: limit)
    }

    func playlistsWithTrackCounts(
        profileId: Int64,
        after cursor: PageCursor<String>?,
        limit: Int
    ) async throws -> Page<PlaylistWithTrackCount, String> {
        note()
        return try await wrapped.playlistsWithTrackCounts(profileId: profileId, after: cursor, limit: limit)
    }

    @_disfavoredOverload
    func playlistTracksPage(
        playlistId: Int64,
        after cursor: PageCursor<Int>?,
        limit: Int
    ) throws -> Page<PlaylistTrackItem, Int> {
        note()
        return try wrapped.playlistTracksPage(playlistId: playlistId, after: cursor, limit: limit)
    }

    func playlistTracksPage(
        playlistId: Int64,
        after cursor: PageCursor<Int>?,
        limit: Int
    ) async throws -> Page<PlaylistTrackItem, Int> {
        note()
        return try await wrapped.playlistTracksPage(playlistId: playlistId, after: cursor, limit: limit)
    }

    func containsTrack(playlistId: Int64, trackId: Int64) async throws -> Bool {
        note()
        return try await wrapped.containsTrack(playlistId: playlistId, trackId: trackId)
    }

    @_disfavoredOverload
    @discardableResult
    func addTrack(trackId: Int64, toPlaylist playlistId: Int64) throws -> PlaylistTrackRecord {
        note()
        return try wrapped.addTrack(trackId: trackId, toPlaylist: playlistId)
    }

    @discardableResult
    func addTrack(trackId: Int64, toPlaylist playlistId: Int64) async throws -> PlaylistTrackRecord {
        note()
        return try await wrapped.addTrack(trackId: trackId, toPlaylist: playlistId)
    }

    @_disfavoredOverload
    @discardableResult
    func removeTrack(trackId: Int64, fromPlaylist playlistId: Int64) throws -> Int {
        note()
        return try wrapped.removeTrack(trackId: trackId, fromPlaylist: playlistId)
    }

    @discardableResult
    func removeTrack(trackId: Int64, fromPlaylist playlistId: Int64) async throws -> Int {
        note()
        return try await wrapped.removeTrack(trackId: trackId, fromPlaylist: playlistId)
    }

    @_disfavoredOverload
    func reorder(playlistId: Int64, orderedTrackIds: [Int64]) throws {
        note()
        try wrapped.reorder(playlistId: playlistId, orderedTrackIds: orderedTrackIds)
    }

    func reorder(playlistId: Int64, orderedTrackIds: [Int64]) async throws {
        note()
        try await wrapped.reorder(playlistId: playlistId, orderedTrackIds: orderedTrackIds)
    }

    func reorder(playlistId: Int64, orderedTrackIds: [Int64], expectedTrackIds: [Int64]) async throws {
        note()
        try await wrapped.reorder(
            playlistId: playlistId,
            orderedTrackIds: orderedTrackIds,
            expectedTrackIds: expectedTrackIds
        )
    }
}

/// A migrated in-memory database, a scripted generator, a spy repository and a
/// settable clock — everything a generated-playlist assertion is made against.
///
/// The database is REAL because the promises under test are all about rows: that
/// membership is rewritten transactionally, that a fresh kind writes nothing, and
/// that a failed refresh leaves the previous materialisation whole.
@MainActor
final class GeneratedPlaylistFixture {
    /// The reference instant every TTL is measured from.
    static let start: TimeInterval = 1_700_000_000

    let appDB: AppDatabase
    let generator = FakeMixGeneratorService()
    let settings = FakeAISettings()
    let repository: SpyPlaylistRepository
    let clock = FakeClock(epochSeconds: GeneratedPlaylistFixture.start)

    private(set) lazy var service = GeneratedPlaylistService(
        appDB.writer,
        playlists: repository,
        generator: generator,
        aiSettings: settings,
        now: clock.nowProvider
    )

    init() throws {
        appDB = try AppDatabase.makeEmpty()
        repository = SpyPlaylistRepository(PlaylistRepository(appDB))
    }

    /// Inserts library rows at explicit ids so a scripted draft can name them.
    func library(ids: [Int64]) throws {
        try appDB.writer.write { db in
            for trackId in ids {
                var record = TrackRecord(
                    id: trackId,
                    filePath: "/Music/\(trackId).flac",
                    title: "Track \(trackId)",
                    artistName: "Artist \(trackId)",
                    duration: 200
                )
                try record.insert(db)
            }
        }
    }

    @discardableResult
    func makeProfile(named name: String) throws -> Int64 {
        try appDB.writer.write { db in
            var record = ProfileRecord(name: name)
            try record.insert(db)
            return record.id ?? 0
        }
    }

    /// Scripts one draft per generator kind.
    func seedDrafts(daypart: [Int64], rediscovery: [Int64]) {
        generator.seed(.daypart, draft: Self.draft(daypart, kind: .daypart, daypart: .evening))
        generator.seed(.rediscovery, draft: Self.draft(rediscovery, kind: .rediscovery))
    }

    /// The materialised membership of a playlist, in `position` order.
    func membership(playlistId: Int64) throws -> [Int64] {
        try appDB.writer.read { db in
            try PlaylistTrackRecord
                .filter(PlaylistTrackRecord.Columns.playlistId == playlistId)
                .order(PlaylistTrackRecord.Columns.position)
                .fetchAll(db)
                .map(\.trackId)
        }
    }

    /// The stored generator row for one kind of one profile.
    func storedRecord(kind: GeneratedPlaylistKind, profileId: Int64) throws -> GeneratedPlaylistRecord? {
        try appDB.writer.read { db in
            try GeneratedPlaylistRecord
                .filter(GeneratedPlaylistRecord.Columns.generatorKind == kind.rawValue)
                .joining(
                    required: GeneratedPlaylistRecord.playlist
                        .filter(PlaylistRecord.Columns.profileId == profileId)
                )
                .fetchOne(db)
        }
    }

    /// Every playlist owned by a profile, oldest first.
    func playlists(profileId: Int64) throws -> [PlaylistRecord] {
        try appDB.writer.read { db in
            try PlaylistRecord
                .filter(PlaylistRecord.Columns.profileId == profileId)
                .order(PlaylistRecord.Columns.id)
                .fetchAll(db)
        }
    }

    /// Total playlist rows, whoever owns them — the assertion that a failed
    /// refresh left no orphan behind.
    func playlistCount() throws -> Int {
        try appDB.writer.read { db in try PlaylistRecord.fetchCount(db) }
    }

    static func draft(_ ids: [Int64], kind: MixSourceKind, daypart: Daypart? = nil) -> PlaylistDraft {
        PlaylistDraft(
            entries: ids.map { MixDraftEntry(trackId: $0, provenance: .rulesResult, score: 1) },
            nameHint: MixNameHint(sourceKind: kind, trackCount: ids.count, daypart: daypart)
        )
    }
}
