// MixCandidateResolver — candidate ids to the three facts the ranking needs.
//
// A candidate source knows an id and a score and nothing else: co-occurrence is
// computed from `playEvent` rows that carry no duration, and a rediscovery list
// is built from `profileTrackState`. De-clumping needs an artist, the duration
// target needs a length, and the energy arc needs an analysed energy — so one
// bounded read sits between the pool and the pipeline.
//
// Two bounds are load-bearing:
//
//  * Ids are CHUNKED to ``InsightPaging/resolveChunkSize`` and each chunk is
//    resolved in the caller's own ranked order.
//    ``TrackRepository/resolvedTracks(profileId:trackIds:)`` does
//    `Array(Set(trackIds).prefix(500))` internally — `Set` iteration is
//    unordered, so handing it more ids than that bound silently keeps a
//    DIFFERENT subset on every run and would make a "same seed, same draft"
//    promise a lie. The chunk size is what keeps this call below the bound; the
//    bound is not a chunk size and must never be read as one.
//  * Duplicates are dropped before chunking, first occurrence wins, so a pool
//    that names a track twice costs one lookup and cannot appear twice in a mix.
//
// Like ``RediscoveryService`` and ``DaypartService``, this resolves history by
// id and applies NO ``LibraryVisibility`` scoping: the ids already came from a
// profile-scoped pool, and a track that has moved outside the profile's current
// roots must still resolve so the draft can name it. Availability is likewise
// the source's business — each insight service already filters to `present`.
import Foundation
import GRDB
import Persistence

/// What the ranking pipeline needs to know about one candidate track.
public struct MixTrackFacts: Sendable, Equatable, Hashable {
    /// The de-clump identity.
    ///
    /// The denormalised `artistName` is preferred over `artistId` because every
    /// scanned row carries a name, while the FK is only populated once the v6
    /// artist/album graph backfill has linked it — keying on the FK would let an
    /// unlinked album clump freely. Case is folded with `lowercased()`, which is
    /// Unicode-default and therefore locale-independent, matching the
    /// `caseInsensitiveCompare` discipline in ``SimilarityService``.
    public var artistKey: String?

    /// Playing time in seconds, when the row has one.
    public var duration: TimeInterval?

    /// Analysed energy (`0...1`) from `trackAudioFeature`, `nil` when the track
    /// has not been analysed. `nil` is the normal state until the opt-in audio
    /// pass has run, which is exactly what the arc's coverage gate measures.
    public var energy: Double?

    public init(artistKey: String? = nil, duration: TimeInterval? = nil, energy: Double? = nil) {
        self.artistKey = artistKey
        self.duration = duration
        self.energy = energy
    }
}

/// Resolves candidate track ids to their ranking facts.
public protocol MixCandidateResolving: Sendable {
    /// The facts for `trackIds`, keyed by id.
    ///
    /// An id with no library row — or whose file is `missing` /
    /// `externalOffline` — is simply ABSENT, and ``MixGeneratorService`` drops
    /// it. A mix is a list of things to play, so the availability state machine
    /// applies here exactly as it does to every other candidate list: the row
    /// stays in the library, rediscovery never proposes it, and neither does a
    /// mix.
    func facts(profileId: Int64, trackIds: [Int64]) async throws -> [Int64: MixTrackFacts]
}

/// The production ``MixCandidateResolving`` over the library and the v16
/// `trackAudioFeature` table.
public struct MixCandidateResolver: MixCandidateResolving {
    private let tracks: TrackRepository
    private let appDatabase: AppDatabase

    /// - Parameter appDatabase: The application database. Held for the audio
    ///   feature read, which has no repository of its own.
    public init(_ appDatabase: AppDatabase) {
        self.appDatabase = appDatabase
        tracks = TrackRepository(appDatabase)
    }

    public func facts(profileId: Int64, trackIds: [Int64]) async throws -> [Int64: MixTrackFacts] {
        let ids = Self.deduplicated(trackIds)
        guard !ids.isEmpty else { return [:] }
        var resolved: [Int64: MixTrackFacts] = [:]
        resolved.reserveCapacity(ids.count)
        var index = ids.startIndex
        while index < ids.endIndex {
            let end = min(index + InsightPaging.resolveChunkSize, ids.endIndex)
            let chunk = Array(ids[index ..< end])
            let rows = try await tracks.resolvedTracks(profileId: profileId, trackIds: chunk)
            let energies = try await analysedEnergies(for: chunk)
            for trackId in chunk {
                guard let scoped = rows[trackId], scoped.track.availability == .present else { continue }
                resolved[trackId] = MixTrackFacts(
                    artistKey: Self.artistKey(scoped.track),
                    duration: scoped.track.duration,
                    energy: energies[trackId]
                )
            }
            index = end
        }
        return resolved
    }
}

private extension MixCandidateResolver {
    /// First occurrence wins, order preserved — so the chunk boundaries are a
    /// function of the caller's ranking, not of a `Set`'s hashing.
    static func deduplicated(_ trackIds: [Int64]) -> [Int64] {
        var seen: Set<Int64> = []
        var unique: [Int64] = []
        unique.reserveCapacity(trackIds.count)
        for trackId in trackIds where seen.insert(trackId).inserted {
            unique.append(trackId)
        }
        return unique
    }

    static func artistKey(_ track: TrackRecord) -> String? {
        if let name = track.artistName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return "name:\(name.lowercased())"
        }
        guard let artistId = track.artistId else { return nil }
        return "id:\(artistId)"
    }

    /// The analysed energies for one already-bounded chunk of ids.
    ///
    /// A missing row is simply an absent key: `trackAudioFeature` is sparse until
    /// the opt-in analysis pass has covered the library, and an unanalysed track
    /// is a normal candidate that merely cannot take part in the arc.
    func analysedEnergies(for ids: [Int64]) async throws -> [Int64: Double] {
        try await appDatabase.writer.read { db in
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
            let rows = try TrackAudioFeatureRecord.fetchAll(db, sql: """
            SELECT * FROM trackAudioFeature WHERE trackId IN (\(placeholders))
            """, arguments: StatementArguments(ids))
            var energies: [Int64: Double] = [:]
            energies.reserveCapacity(rows.count)
            for row in rows {
                energies[row.trackId] = row.energy
            }
            return energies
        }
    }
}
