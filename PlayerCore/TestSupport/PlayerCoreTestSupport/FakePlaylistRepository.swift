// FakePlaylistRepository — an in-memory, recording ``PlaylistRepositoryProviding``.
//
// Assigns ids, stores ordered membership and records mutations in call order.
//
// A `struct` over a lock box rather than an `actor`, matching
// ``FakeSmartPlaylistRepository``: an actor's methods hop to its own executor,
// which would make "this ran off the calling actor" true by construction and
// therefore worthless as an assertion.
//
// `FakePlaylistRepositoryError` and `FakePlaylistRepositoryOperation` live in the
// sibling `FakePlaylistRepository+Errors.swift` — moved there verbatim for file-length
// headroom, not because they belong to a different concern. See that file's header.
//
// GRDB is imported for its `DatabaseValueConvertible` conformances alone: `Page`'s
// key parameter is constrained to it, so `Page<_, String>` is unusable without the
// conformance visible in THIS file. No query is built here. Nothing imports AppKit
// or UIKit (PlayerCore portability invariant).
import Foundation
import GRDB
import os
import Persistence

/// An in-memory playlist repository for hermetic tests and previews.
public struct FakePlaylistRepository: PlaylistRepositoryProviding {
    /// One recorded membership rewrite.
    public struct ReorderCall: Sendable, Equatable {
        public var playlistId: Int64
        public var orderedTrackIds: [Int64]

        public init(playlistId: Int64, orderedTrackIds: [Int64]) {
            self.playlistId = playlistId
            self.orderedTrackIds = orderedTrackIds
        }
    }

    /// One recorded single-track membership change.
    public struct MembershipCall: Sendable, Equatable {
        public var playlistId: Int64
        public var trackId: Int64

        public init(playlistId: Int64, trackId: Int64) {
            self.playlistId = playlistId
            self.trackId = trackId
        }
    }

    /// Everything the fake stores and observes, guarded as one unit.
    public struct Recording: Sendable {
        /// Stored playlists by id.
        public var playlists: [Int64: PlaylistRecord] = [:]
        /// Ordered membership by playlist id.
        public var membership: [Int64: [Int64]] = [:]
        /// Track rows served by ``playlistTracksPage(playlistId:after:limit:)``.
        /// A membership id with no entry here is served a bare placeholder row.
        public var tracks: [Int64: TrackRecord] = [:]
        /// The id the next insert hands out; bumped on every insert.
        public var nextId: Int64 = 1
        /// Names passed to `create`, in call order.
        public var createdNames: [String] = []
        /// Membership rewrites, in call order.
        public var reorderCalls: [ReorderCall] = []
        /// Single-track appends, in call order.
        public var addTrackCalls: [MembershipCall] = []
        /// Single-track removals, in call order.
        public var removeTrackCalls: [MembershipCall] = []
        /// Playlists passed to `update`, in call order.
        public var updateCalls: [PlaylistRecord] = []
        /// Ids passed to `deletePlaylist`, in call order.
        public var deleteCalls: [Int64] = []
        /// Operations armed to throw ``FakePlaylistRepositoryError/forcedFailure``.
        public var failing: Set<FakePlaylistRepositoryOperation> = []

        /// Every mutating call this fake has served, across all kinds — the single
        /// number a "zero side effects" assertion reads.
        public var mutationCount: Int {
            createdNames.count + reorderCalls.count + addTrackCalls.count
                + removeTrackCalls.count + updateCalls.count + deleteCalls.count
        }
    }

    private let state: OSAllocatedUnfairLock<Recording>

    public init(playlists: [PlaylistRecord] = [], membership: [Int64: [Int64]] = [:]) {
        var recording = Recording()
        for playlist in playlists {
            guard let id = playlist.id else { continue }
            recording.playlists[id] = playlist
            recording.nextId = max(recording.nextId, id + 1)
        }
        recording.membership = membership
        state = OSAllocatedUnfairLock(initialState: recording)
    }

    /// A snapshot of everything stored and recorded so far.
    public var recording: Recording {
        state.withLock { $0 }
    }

    /// Mutates the script — arm a failure, seed tracks, pre-load playlists.
    public func configure(_ mutate: @Sendable (inout Recording) -> Void) {
        state.withLock { mutate(&$0) }
    }

    /// Arms `operation` to throw. Pass an empty set to disarm everything.
    public func setFailing(_ operations: Set<FakePlaylistRepositoryOperation>) {
        state.withLock { $0.failing = operations }
    }
}

// MARK: - PlaylistRepositoryProviding

public extension FakePlaylistRepository {
    func fetchPlaylist(id: Int64) throws -> PlaylistRecord? {
        state.withLock { $0.playlists[id] }
    }

    @_disfavoredOverload
    @discardableResult
    func insert(_ playlist: PlaylistRecord) throws -> PlaylistRecord {
        try performInsert(playlist, operation: .insert)
    }

    @discardableResult
    func insert(_ playlist: PlaylistRecord) async throws -> PlaylistRecord {
        try performInsert(playlist, operation: .insert)
    }

    @_disfavoredOverload
    @discardableResult
    func create(named name: String, profileId: Int64) throws -> PlaylistRecord {
        try performCreate(named: name, profileId: profileId)
    }

    @discardableResult
    func create(named name: String, profileId: Int64) async throws -> PlaylistRecord {
        try performCreate(named: name, profileId: profileId)
    }

    @_disfavoredOverload
    func update(_ playlist: PlaylistRecord) throws {
        try performUpdate(playlist)
    }

    func update(_ playlist: PlaylistRecord) async throws {
        try performUpdate(playlist)
    }

    @_disfavoredOverload
    @discardableResult
    func deletePlaylist(id: Int64) throws -> Bool {
        try performDelete(id: id)
    }

    @discardableResult
    func deletePlaylist(id: Int64) async throws -> Bool {
        try performDelete(id: id)
    }

    func playlistsPage(
        profileId: Int64,
        after cursor: PageCursor<String>?,
        limit: Int
    ) throws -> Page<PlaylistRecord, String> {
        let rows = sortedPlaylists(profileId: profileId, after: cursor?.key, limit: limit)
        return Page(items: rows, nextCursor: nil)
    }

    @_disfavoredOverload
    func playlistsWithTrackCounts(
        profileId: Int64,
        after cursor: PageCursor<String>?,
        limit: Int
    ) throws -> Page<PlaylistWithTrackCount, String> {
        performCountedPage(profileId: profileId, after: cursor, limit: limit)
    }

    func playlistsWithTrackCounts(
        profileId: Int64,
        after cursor: PageCursor<String>?,
        limit: Int
    ) async throws -> Page<PlaylistWithTrackCount, String> {
        performCountedPage(profileId: profileId, after: cursor, limit: limit)
    }

    @_disfavoredOverload
    func playlistTracksPage(
        playlistId: Int64,
        after cursor: PageCursor<Int>?,
        limit: Int
    ) throws -> Page<PlaylistTrackItem, Int> {
        performTracksPage(playlistId: playlistId, after: cursor, limit: limit)
    }

    func playlistTracksPage(
        playlistId: Int64,
        after cursor: PageCursor<Int>?,
        limit: Int
    ) async throws -> Page<PlaylistTrackItem, Int> {
        performTracksPage(playlistId: playlistId, after: cursor, limit: limit)
    }

    /// A REAL membership lookup against the same `membership` map `addTrack` writes and
    /// `playlistTracksPage` serves — never a constant.
    ///
    /// A stub returning `false` would let a duplicate-suppression caller pass here and
    /// then double-append against the real repository, which is exactly the bug the
    /// caller's pre-check exists to prevent.
    func containsTrack(playlistId: Int64, trackId: Int64) async throws -> Bool {
        state.withLock { $0.membership[playlistId]?.contains(trackId) ?? false }
    }

    @_disfavoredOverload
    @discardableResult
    func addTrack(trackId: Int64, toPlaylist playlistId: Int64) throws -> PlaylistTrackRecord {
        try performAddTrack(trackId: trackId, playlistId: playlistId)
    }

    @discardableResult
    func addTrack(trackId: Int64, toPlaylist playlistId: Int64) async throws -> PlaylistTrackRecord {
        try performAddTrack(trackId: trackId, playlistId: playlistId)
    }

    @_disfavoredOverload
    @discardableResult
    func removeTrack(trackId: Int64, fromPlaylist playlistId: Int64) throws -> Int {
        try performRemoveTrack(trackId: trackId, playlistId: playlistId)
    }

    @discardableResult
    func removeTrack(trackId: Int64, fromPlaylist playlistId: Int64) async throws -> Int {
        try performRemoveTrack(trackId: trackId, playlistId: playlistId)
    }

    @_disfavoredOverload
    func reorder(playlistId: Int64, orderedTrackIds: [Int64]) throws {
        try performReorder(playlistId: playlistId, orderedTrackIds: orderedTrackIds)
    }

    func reorder(playlistId: Int64, orderedTrackIds: [Int64]) async throws {
        try performReorder(playlistId: playlistId, orderedTrackIds: orderedTrackIds)
    }

    func reorder(playlistId: Int64, orderedTrackIds: [Int64], expectedTrackIds: [Int64]) async throws {
        try performReorder(playlistId: playlistId, orderedTrackIds: orderedTrackIds, expectedTrackIds: expectedTrackIds)
    }
}

// MARK: - Shared bodies (sync + async funnel through these)

/// A sync twin cannot simply be called from its `async` sibling: overload
/// resolution inside an `async` context picks the `async` one and the function
/// recurses into itself.
private extension FakePlaylistRepository {
    func performInsert(
        _ playlist: PlaylistRecord,
        operation: FakePlaylistRepositoryOperation
    ) throws -> PlaylistRecord {
        try state.withLock { recording in
            guard !recording.failing.contains(operation) else {
                throw FakePlaylistRepositoryError.forcedFailure
            }
            var stored = playlist
            let id = playlist.id ?? recording.nextId
            stored.id = id
            recording.nextId = max(recording.nextId, id + 1)
            recording.playlists[id] = stored
            return stored
        }
    }

    func performCreate(named name: String, profileId: Int64) throws -> PlaylistRecord {
        state.withLock { $0.createdNames.append(name) }
        return try performInsert(
            PlaylistRecord(name: name, profileId: profileId),
            operation: .create
        )
    }

    func performUpdate(_ playlist: PlaylistRecord) throws {
        try state.withLock { recording in
            recording.updateCalls.append(playlist)
            guard !recording.failing.contains(.update) else {
                throw FakePlaylistRepositoryError.forcedFailure
            }
            guard let id = playlist.id, recording.playlists[id] != nil else {
                throw FakePlaylistRepositoryError.playlistNotFound(id: playlist.id ?? 0)
            }
            recording.playlists[id] = playlist
        }
    }

    func performDelete(id: Int64) throws -> Bool {
        try state.withLock { recording in
            recording.deleteCalls.append(id)
            guard !recording.failing.contains(.delete) else {
                throw FakePlaylistRepositoryError.forcedFailure
            }
            recording.membership[id] = nil
            return recording.playlists.removeValue(forKey: id) != nil
        }
    }

    func performAddTrack(trackId: Int64, playlistId: Int64) throws -> PlaylistTrackRecord {
        try state.withLock { recording in
            recording.addTrackCalls.append(MembershipCall(playlistId: playlistId, trackId: trackId))
            guard !recording.failing.contains(.addTrack) else {
                throw FakePlaylistRepositoryError.forcedFailure
            }
            var ids = recording.membership[playlistId] ?? []
            ids.append(trackId)
            recording.membership[playlistId] = ids
            return PlaylistTrackRecord(
                id: Int64(ids.count),
                playlistId: playlistId,
                trackId: trackId,
                position: ids.count - 1
            )
        }
    }

    func performRemoveTrack(trackId: Int64, playlistId: Int64) throws -> Int {
        try state.withLock { recording in
            recording.removeTrackCalls.append(MembershipCall(playlistId: playlistId, trackId: trackId))
            guard !recording.failing.contains(.removeTrack) else {
                throw FakePlaylistRepositoryError.forcedFailure
            }
            let ids = recording.membership[playlistId] ?? []
            let kept = ids.filter { $0 != trackId }
            recording.membership[playlistId] = kept
            return ids.count - kept.count
        }
    }

    func performReorder(playlistId: Int64, orderedTrackIds: [Int64], expectedTrackIds: [Int64]? = nil) throws {
        try state.withLock { recording in
            if let expectedTrackIds {
                guard recording.playlists[playlistId] != nil else {
                    throw PlaylistMembershipError.playlistNotFound(id: playlistId)
                }
                guard (recording.membership[playlistId] ?? []) == expectedTrackIds else {
                    throw PlaylistMembershipError.changed(id: playlistId)
                }
            }
            recording.reorderCalls.append(
                ReorderCall(playlistId: playlistId, orderedTrackIds: orderedTrackIds)
            )
            guard !recording.failing.contains(.reorder) else {
                throw FakePlaylistRepositoryError.forcedFailure
            }
            recording.membership[playlistId] = orderedTrackIds
        }
    }

    func sortedPlaylists(profileId: Int64, after key: String?, limit: Int) -> [PlaylistRecord] {
        let rows = state.withLock { recording in
            recording.playlists.values
                .filter { $0.profileId == profileId }
                .sorted { ($0.name, $0.id ?? 0) < ($1.name, $1.id ?? 0) }
        }
        let remaining = key.map { anchor in rows.filter { $0.name > anchor } } ?? rows
        return Array(remaining.prefix(max(1, limit)))
    }

    func performCountedPage(
        profileId: Int64,
        after cursor: PageCursor<String>?,
        limit: Int
    ) -> Page<PlaylistWithTrackCount, String> {
        let rows = sortedPlaylists(profileId: profileId, after: cursor?.key, limit: limit)
        let counted = state.withLock { recording in
            rows.map { playlist in
                PlaylistWithTrackCount(
                    playlist: playlist,
                    trackCount: recording.membership[playlist.id ?? 0]?.count ?? 0
                )
            }
        }
        return Page(items: counted, nextCursor: nil)
    }

    func performTracksPage(
        playlistId: Int64,
        after cursor: PageCursor<Int>?,
        limit: Int
    ) -> Page<PlaylistTrackItem, Int> {
        let items = state.withLock { recording -> [PlaylistTrackItem] in
            let ids = recording.membership[playlistId] ?? []
            return ids.enumerated().compactMap { position, trackId in
                guard position > (cursor?.key ?? -1) else { return nil }
                let track = recording.tracks[trackId]
                    ?? TrackRecord(id: trackId, filePath: "/fake/\(trackId).flac")
                return PlaylistTrackItem(id: Int64(position + 1), position: position, track: track)
            }
        }
        return Page(items: Array(items.prefix(max(1, limit))), nextCursor: nil)
    }
}
