// GeneratedPlaylistService — materialised auto-mixes with lazy TTL refresh.
//
// Nothing here runs on its own. There is no timer, no scheduled task, no resident
// observer: a mix is built or rebuilt only when a caller asks — at app launch and
// when a surface that shows it appears. That is the whole reason staleness is a
// stored timestamp compared against an injected clock rather than a countdown.
//
// Three properties are the contract:
//
//  * A FRESH kind writes NOTHING. The freshness check is one bounded read of
//    `generatedPlaylist` and it returns before the mix generator or the playlist
//    repository is touched, so two calls inside a TTL window cost one refresh.
//  * A refresh is ONE transaction. The membership rewrite and the
//    `lastRefreshedAt` stamp commit together, so a generator that throws — or a
//    write that fails — leaves the PREVIOUS materialisation exactly as it was. A
//    stale-but-whole mix always beats a half-rewritten one.
//  * Both toggles are checked FIRST. Master off, or the kind's own bundle off,
//    and the call returns having read nothing and written nothing.
//
// Mixes materialise into ordinary `playlistTrack` rows, exactly like a smart
// playlist (``SmartPlaylistEvaluator``): counts, paging, export, playback and
// manual reorder all keep working, and a mix that stops refreshing (toggle off)
// simply stays an ordinary playlist the listener owns. Nothing is ever deleted
// because a feature was switched off.
import Foundation
import GRDB
import Persistence

// MARK: - Results

/// What one kind's refresh did.
public struct GeneratedPlaylistRefresh: Sendable, Equatable {
    /// The generator that ran.
    public let kind: GeneratedPlaylistKind
    /// The playlist whose membership was written.
    public let playlistId: Int64
    /// The materialised ids, in the order they were written to
    /// `playlistTrack.position` (`0..<count`).
    public let trackIds: [Int64]
    /// `true` when this refresh created the playlist rather than rewriting one.
    public let created: Bool
    /// The instant stamped into `generatedPlaylist.lastRefreshedAt`.
    public let refreshedAt: Double

    public init(
        kind: GeneratedPlaylistKind,
        playlistId: Int64,
        trackIds: [Int64],
        created: Bool,
        refreshedAt: Double
    ) {
        self.kind = kind
        self.playlistId = playlistId
        self.trackIds = trackIds
        self.created = created
        self.refreshedAt = refreshedAt
    }
}

/// One generator-backed playlist, for a surface that only lists them.
public struct GeneratedPlaylistSummary: Sendable, Equatable {
    /// The listed playlist.
    public let playlistId: Int64
    /// Its stored display name.
    public let name: String
    /// The raw stored kind — a `String`, not ``GeneratedPlaylistKind``, so a row
    /// written by a generator this build does not know about still lists.
    public let generatorKind: String
    /// When it last regenerated, or `nil` if it never has.
    public let lastRefreshedAt: Double?

    /// The recognised kind, or `nil` for a row this build does not know.
    public var kind: GeneratedPlaylistKind? {
        GeneratedPlaylistKind(rawValue: generatorKind)
    }

    public init(playlistId: Int64, name: String, generatorKind: String, lastRefreshedAt: Double?) {
        self.playlistId = playlistId
        self.name = name
        self.generatorKind = generatorKind
        self.lastRefreshedAt = lastRefreshedAt
    }
}

/// Why a refresh could not complete.
public enum GeneratedPlaylistError: Error, Sendable, Equatable {
    /// The repository returned a playlist without an id, so nothing could be
    /// attached to it.
    case playlistNotCreated(GeneratedPlaylistKind)
    /// The generator spec did not encode to UTF-8 text for the `specJson` column.
    case specEncodingFailed(generatorKind: String)
}

// MARK: - Protocol

/// Creates and refreshes one profile's generator-backed playlists.
@MainActor
public protocol GeneratedPlaylistProviding: AnyObject {
    /// Brings every enabled kind up to date, creating its playlist on first call.
    ///
    /// Returns one entry per kind that was actually created or rewritten — empty
    /// when everything is fresh, or when the master toggle or every relevant
    /// bundle toggle is off. Never starts anything in the background: when this
    /// returns, the work is done.
    @discardableResult
    func refreshIfStale(profileId: Int64) async throws -> [GeneratedPlaylistRefresh]

    /// The profile's generator-backed playlists, bounded and ordered by kind.
    func generatedPlaylists(profileId: Int64) async throws -> [GeneratedPlaylistSummary]
}

// MARK: - Service

/// The production ``GeneratedPlaylistProviding`` over `generatedPlaylist`.
@MainActor
public final class GeneratedPlaylistService: GeneratedPlaylistProviding {
    /// Tracks one auto-mix asks for.
    public static let targetCount = MixSpec.defaultTargetCount

    /// Ceiling on ``generatedPlaylists(profileId:)`` — a listing, not a scan.
    public static let maxSummaries = 50

    private let dbWriter: any DatabaseWriter
    private let playlists: any PlaylistRepositoryProviding
    private let generator: any MixGenerating
    private let aiSettings: any AISettingsProviding
    private let now: @Sendable () -> Date
    private let naming: @Sendable (GeneratedPlaylistKind) -> String

    /// Profiles with a refresh in flight.
    ///
    /// The two wired callers — app launch and a destination appearing — can fire
    /// within milliseconds of each other, and both would see "no row yet" and
    /// create a playlist. Marking the profile before the first `await` (this type
    /// is `@MainActor`, so the mark is atomic against another caller's entry) is
    /// what keeps that from producing a duplicate.
    private var refreshing: Set<Int64> = []

    /// - Parameters:
    ///   - naming: Supplies each kind's playlist name. Defaults to the kind's
    ///     English fallback — a shell that can localise should inject its own,
    ///     because the name is persisted into `playlist.name`.
    public init(
        _ dbWriter: any DatabaseWriter,
        playlists: any PlaylistRepositoryProviding,
        generator: any MixGenerating,
        aiSettings: any AISettingsProviding,
        now: @escaping @Sendable () -> Date = { Date() },
        naming: @escaping @Sendable (GeneratedPlaylistKind) -> String = { $0.fallbackName }
    ) {
        self.dbWriter = dbWriter
        self.playlists = playlists
        self.generator = generator
        self.aiSettings = aiSettings
        self.now = now
        self.naming = naming
    }

    /// Convenience over the application database.
    public convenience init(
        _ appDatabase: AppDatabase,
        generator: any MixGenerating,
        aiSettings: any AISettingsProviding,
        now: @escaping @Sendable () -> Date = { Date() },
        naming: @escaping @Sendable (GeneratedPlaylistKind) -> String = { $0.fallbackName }
    ) {
        self.init(
            appDatabase.writer,
            playlists: PlaylistRepository(appDatabase),
            generator: generator,
            aiSettings: aiSettings,
            now: now,
            naming: naming
        )
    }

    @discardableResult
    public func refreshIfStale(profileId: Int64) async throws -> [GeneratedPlaylistRefresh] {
        guard aiSettings.intelligenceEnabled, !refreshing.contains(profileId) else { return [] }
        refreshing.insert(profileId)
        defer { refreshing.remove(profileId) }
        var applied: [GeneratedPlaylistRefresh] = []
        for kind in GeneratedPlaylistKind.allCases where aiSettings.isEnabled(kind.bundle) {
            guard let refresh = try await refresh(kind, profileId: profileId) else { continue }
            applied.append(refresh)
        }
        return applied
    }

    public func generatedPlaylists(profileId: Int64) async throws -> [GeneratedPlaylistSummary] {
        let limit = Self.maxSummaries
        return try await dbWriter.read { db in
            try GeneratedPlaylistRecord
                .including(
                    required: GeneratedPlaylistRecord.playlist
                        .filter(PlaylistRecord.Columns.profileId == profileId)
                )
                .order(GeneratedPlaylistRecord.Columns.generatorKind, GeneratedPlaylistRecord.Columns.id)
                .limit(limit)
                .asRequest(of: GeneratedPlaylistRow.self)
                .fetchAll(db)
                .map(\.summary)
        }
    }
}

// MARK: - One kind's refresh

private extension GeneratedPlaylistService {
    /// The whole per-kind decision: absent ⇒ create, stale ⇒ rewrite, fresh ⇒
    /// `nil` without a single further query.
    func refresh(_ kind: GeneratedPlaylistKind, profileId: Int64) async throws -> GeneratedPlaylistRefresh? {
        let instant = now().timeIntervalSince1970
        guard let record = try await storedRecord(kind: kind, profileId: profileId) else {
            return try await create(kind, profileId: profileId, at: instant)
        }
        guard Self.isStale(record.lastRefreshedAt, at: instant, ttl: kind.refreshInterval) else { return nil }
        let generated = try await generate(kind, profileId: profileId, at: instant)
        return try await materialise(
            Materialisation(
                kind: kind,
                playlistId: record.playlistId,
                existing: record,
                draft: generated.draft,
                spec: generated.spec,
                instant: instant
            )
        )
    }

    /// A kind that has never refreshed is stale; `>=` so a mix that is exactly one
    /// interval old rebuilds, matching ``SmartPlaylistRepository``'s own rule.
    static func isStale(_ lastRefreshedAt: Double?, at instant: Double, ttl: TimeInterval) -> Bool {
        guard let lastRefreshedAt else { return true }
        return instant - lastRefreshedAt >= ttl
    }

    /// This profile's row for `kind`, found by joining through `playlist` — the
    /// `generatedPlaylist` table carries no profile of its own, and the ownership
    /// that matters is the playlist's.
    func storedRecord(kind: GeneratedPlaylistKind, profileId: Int64) async throws -> GeneratedPlaylistRecord? {
        try await dbWriter.read { db in
            try GeneratedPlaylistRecord
                .filter(GeneratedPlaylistRecord.Columns.generatorKind == kind.rawValue)
                .joining(
                    required: GeneratedPlaylistRecord.playlist
                        .filter(PlaylistRecord.Columns.profileId == profileId)
                )
                .order(GeneratedPlaylistRecord.Columns.id)
                .fetchOne(db)
        }
    }

    /// Generates BEFORE creating anything, so a generator failure on first access
    /// leaves no empty playlist behind.
    func create(
        _ kind: GeneratedPlaylistKind,
        profileId: Int64,
        at instant: Double
    ) async throws -> GeneratedPlaylistRefresh {
        let generated = try await generate(kind, profileId: profileId, at: instant)
        let playlist = try await playlists.create(named: naming(kind), profileId: profileId)
        guard let playlistId = playlist.id else { throw GeneratedPlaylistError.playlistNotCreated(kind) }
        do {
            return try await materialise(
                Materialisation(
                    kind: kind,
                    playlistId: playlistId,
                    existing: nil,
                    draft: generated.draft,
                    spec: generated.spec,
                    instant: instant
                )
            )
        } catch {
            // The playlist exists but nothing claims it — leaving it would show the
            // listener a named, empty list they never asked for, and the next
            // refresh would create a second one beside it.
            _ = try? await playlists.deletePlaylist(id: playlistId)
            throw error
        }
    }

    func generate(
        _ kind: GeneratedPlaylistKind,
        profileId: Int64,
        at instant: Double
    ) async throws -> (draft: PlaylistDraft, spec: GeneratedPlaylistSpec) {
        let seed = GeneratedPlaylistSeed.derive(kind: kind, profileId: profileId, at: instant)
        let draft = try await generator.generate(
            MixSpec(
                profileId: profileId,
                source: kind.source,
                targetCount: Self.targetCount,
                seed: seed
            )
        )
        return (
            draft,
            GeneratedPlaylistSpec(
                kind: kind,
                seed: seed,
                targetCount: Self.targetCount,
                daypart: draft.nameHint.daypart
            )
        )
    }
}

// MARK: - Materialisation

/// One refresh's write, bundled so the transaction takes a single argument.
private struct Materialisation {
    let kind: GeneratedPlaylistKind
    let playlistId: Int64
    let existing: GeneratedPlaylistRecord?
    let draft: PlaylistDraft
    let spec: GeneratedPlaylistSpec
    let instant: Double
}

private extension GeneratedPlaylistService {
    /// Writes the membership and the freshness stamp in ONE transaction.
    ///
    /// Same delete-then-insert shape as ``SmartPlaylistEvaluator/rewriteOrder(_:playlistId:orderedTrackIds:)``
    /// and `PlaylistRepository.reorder`: inside a transaction the
    /// `UNIQUE(playlistId, position)` constraint is never transiently violated,
    /// and repeating a refresh is idempotent because the previous rows are gone
    /// before the new ones land. Restated here rather than reused because that
    /// helper is internal to `Persistence`.
    func materialise(_ plan: Materialisation) async throws -> GeneratedPlaylistRefresh {
        let json = try plan.spec.encodedJSON()
        let trackIds = plan.draft.trackIds
        let playlistId = plan.playlistId
        let instant = plan.instant
        let kind = plan.kind
        let existing = plan.existing
        try await dbWriter.write { db in
            var record = existing ?? GeneratedPlaylistRecord(
                playlistId: playlistId,
                generatorKind: kind.rawValue,
                specJson: json,
                specVersion: GeneratedPlaylistSpec.currentVersion
            )
            record.specJson = json
            record.specVersion = GeneratedPlaylistSpec.currentVersion
            record.lastRefreshedAt = instant
            if record.id == nil {
                try record.insert(db)
            } else {
                try record.update(db)
            }
            try PlaylistTrackRecord
                .filter(PlaylistTrackRecord.Columns.playlistId == playlistId)
                .deleteAll(db)
            for (index, trackId) in trackIds.enumerated() {
                var entry = PlaylistTrackRecord(playlistId: playlistId, trackId: trackId, position: index)
                try entry.insert(db)
            }
        }
        return GeneratedPlaylistRefresh(
            kind: kind,
            playlistId: playlistId,
            trackIds: trackIds,
            created: existing == nil,
            refreshedAt: instant
        )
    }
}

// MARK: - Listing row

/// A `generatedPlaylist` row joined to the `playlist` it names.
private struct GeneratedPlaylistRow: Decodable, FetchableRecord {
    var playlistId: Int64
    var generatorKind: String
    var lastRefreshedAt: Double?
    var playlist: PlaylistRecord

    var summary: GeneratedPlaylistSummary {
        GeneratedPlaylistSummary(
            playlistId: playlistId,
            name: playlist.name,
            generatorKind: generatorKind,
            lastRefreshedAt: lastRefreshedAt
        )
    }
}
