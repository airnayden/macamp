// SimilarityService — "what else goes with this track", computed at query time.
//
// There is NO similarity matrix. Nothing is precomputed, materialised or cached: each
// call scans a bounded, recent window of the profile's own `playEvent` rows, cuts it
// into sessions (``ListeningSessionizer``) and tallies which tracks kept the seed
// company. At 100k tracks a materialised matrix would be 10^10 cells; the window this
// reads is capped at ``SimilarityService/maxScannedEvents`` rows, which is the whole
// reason the feature can exist at all.
//
// The scan follows `ListeningDigestBuilder.swift:158-198` exactly — repeated
// `playEvents(profileId:before:limit:)` calls advancing a `PageCursor`, never one
// unbounded `fetchAll`. Two extra bounds make it terminate early on a heavy history:
//
//  * a RECENCY HORIZON (``lookbackDays``): pages arrive newest-first, so the first
//    row older than the horizon ends the scan; and
//  * a ROW CEILING (``maxScannedEvents``) applied PER EVENT, never per page — taking
//    the first N rows of a totally-ordered stream is the same N rows whatever the page
//    size, which is what makes `pageSize: 3` and `pageSize: 500` agree byte for byte.
//
// Determinism, in the same four terms the digest uses: a total scan order (keyset with
// an `id` tie-break), order-independent folding (each session contributes to a track's
// score exactly once, and sessions are folded oldest-first), a total output ordering
// (score descending, then `trackId` ascending — never `Dictionary` order), and no
// ambient inputs (the clock is injected; recency is measured against it, never against
// `Date()` read mid-scoring).
import Foundation
import Persistence

/// Why a track was proposed as similar.
public enum SimilarityBasis: String, Sendable, Equatable, Hashable, CaseIterable, Codable {
    /// The listener actually played it in the same sitting as the seed.
    case coSession
    /// Nothing was played with the seed, so its tags stood in — the cold-start path.
    case metadata
}

/// One ranked neighbour of a seed track.
public struct SimilarTrack: Sendable, Equatable, Hashable {
    /// The library `track.id` being proposed.
    public let trackId: Int64
    /// The published, already-rounded ranking score. Higher is closer; the value is
    /// only ever comparable against other scores from the SAME call.
    public let score: Double
    /// What produced the score — carried so a consumer can annotate provenance
    /// rather than re-deriving it.
    public let basis: SimilarityBasis

    public init(trackId: Int64, score: Double, basis: SimilarityBasis) {
        self.trackId = trackId
        self.score = score
        self.basis = basis
    }
}

/// Query-time track similarity for one profile.
public protocol SimilarityProviding: Sendable {
    /// Tracks the listener played in the same sessions as `trackId`, most similar
    /// first. Empty when the seed has no plays in the scanned window.
    func coOccurring(with trackId: Int64, profileId: Int64, limit: Int) async throws -> [SimilarTrack]

    /// The cold-start path: tracks that merely RESEMBLE the seed — same artist, same
    /// genre, same decade — with no listening history involved. Empty when the seed
    /// is not in the library or carries no artist and no genre.
    func metadataNeighbors(for trackId: Int64, profileId: Int64, limit: Int) async throws -> [SimilarTrack]

    /// The neighbours a caller should normally use: co-session similarity, falling
    /// back to metadata when the seed has no listening history at all.
    func similar(to trackId: Int64, profileId: Int64, limit: Int) async throws -> [SimilarTrack]
}

public extension SimilarityProviding {
    /// Co-session first; metadata only when co-session found NOTHING.
    ///
    /// The fallback is all-or-nothing on purpose: mixing a real co-play with a
    /// same-genre guess would put two incomparable scores in one ranked list.
    func similar(to trackId: Int64, profileId: Int64, limit: Int) async throws -> [SimilarTrack] {
        let coPlayed = try await coOccurring(with: trackId, profileId: profileId, limit: limit)
        guard coPlayed.isEmpty else { return coPlayed }
        return try await metadataNeighbors(for: trackId, profileId: profileId, limit: limit)
    }
}

/// The production ``SimilarityProviding`` over the v15 listening history.
public struct SimilarityService: SimilarityProviding {
    /// How far back a co-occurrence scan reaches. A year is roughly four half-lives,
    /// past which a co-play's weight rounds away anyway.
    public static let lookbackDays: Double = 365

    /// The age at which a co-occurrence counts half as much. 90 days makes "what I am
    /// listening to lately" clearly outrank "what I listened to last spring" without
    /// erasing it.
    public static let recencyHalfLifeDays: Double = 90

    /// The hard ceiling on rows one call reads. Bounds both the scan and the sessions
    /// held in memory; a heavier history is simply truncated at the recent end, which
    /// is the end that matters.
    public static let maxScannedEvents = 5000

    /// The hard ceiling on library rows the cold-start path considers per pool.
    public static let maxMetadataCandidates = 500

    /// Weight for a candidate crediting the same artist as the seed.
    static let sameArtistWeight = 1.0
    /// Weight for a candidate tagged with the seed's genre.
    static let sameGenreWeight = 0.5
    /// Weight for a candidate released in the seed's decade.
    static let sameDecadeWeight = 0.25

    private let events: any PlayEventRepositoryProviding
    private let tracks: any TrackRepositoryProviding
    private let sessionizer: ListeningSessionizer
    private let now: @Sendable () -> Date
    private let pageSize: Int

    /// - Parameters:
    ///   - events: Windowed access to `playEvent`.
    ///   - tracks: The library, for the cold-start path only.
    ///   - sessionizer: The session cut. Injected so a caller can widen the gap
    ///     without a second implementation of the tally.
    ///   - now: The clock recency is measured back from. Injected so a fixture's
    ///     scores do not change with the wall clock.
    ///   - pageSize: Rows per keyset page. A free parameter precisely so a test can
    ///     prove the output does not depend on it.
    public init(
        events: any PlayEventRepositoryProviding,
        tracks: any TrackRepositoryProviding,
        sessionizer: ListeningSessionizer = ListeningSessionizer(),
        now: @escaping @Sendable () -> Date = { Date() },
        pageSize: Int = PlayEventRepository.fetchLimit
    ) {
        self.events = events
        self.tracks = tracks
        self.sessionizer = sessionizer
        self.now = now
        self.pageSize = max(1, pageSize)
    }

    /// Convenience over the application database.
    public init(
        _ appDatabase: AppDatabase,
        sessionizer: ListeningSessionizer = ListeningSessionizer(),
        now: @escaping @Sendable () -> Date = { Date() },
        pageSize: Int = PlayEventRepository.fetchLimit
    ) {
        self.init(
            events: PlayEventRepository(appDatabase),
            tracks: TrackRepository(appDatabase),
            sessionizer: sessionizer,
            now: now,
            pageSize: pageSize
        )
    }

    public func coOccurring(with trackId: Int64, profileId: Int64, limit: Int) async throws -> [SimilarTrack] {
        let capped = Self.cappedLimit(limit)
        guard capped > 0 else { return [] }
        let reference = now().timeIntervalSince1970
        let horizon = reference - Self.lookbackDays * ListeningLocalTime.secondsPerDay
        let window = try await scanEvents(profileId: profileId, notBefore: horizon)
        let sessions = sessionizer.sessions(from: window)
        let scores = Self.coSessionScores(sessions, seed: trackId, now: reference)
        return Self.ranked(scores, basis: .coSession, limit: capped)
    }

    public func metadataNeighbors(for trackId: Int64, profileId: Int64, limit: Int) async throws -> [SimilarTrack] {
        let capped = Self.cappedLimit(limit)
        guard capped > 0, let seed = try await fetchTrack(trackId) else { return [] }
        let pool = try await metadataCandidates(for: seed, profileId: profileId)
        var scores: [Int64: Double] = [:]
        for candidate in pool {
            guard let candidateId = candidate.id, candidateId != trackId else { continue }
            guard candidate.availability == .present else { continue }
            // Assignment, not accumulation: the artist and genre pools overlap, and a
            // candidate found twice must not outscore the same candidate found once.
            scores[candidateId] = Self.metadataScore(seed: seed, candidate: candidate)
        }
        return Self.ranked(scores, basis: .metadata, limit: capped)
    }
}

// MARK: - Bounded scans

private extension SimilarityService {
    /// The profile's recent plays, newest-first pages folded into one oldest-first
    /// window. Stops at the first row older than `horizon` (pages are ordered, so
    /// every later row is older still) or at ``maxScannedEvents``, whichever comes
    /// first.
    func scanEvents(profileId: Int64, notBefore horizon: TimeInterval) async throws -> [PlayEventRecord] {
        var collected: [PlayEventRecord] = []
        var cursor: PageCursor<Double>?
        repeat {
            let page = try await events.playEvents(profileId: profileId, before: cursor, limit: pageSize)
            for event in page.items {
                guard event.startedAt >= horizon, collected.count < Self.maxScannedEvents else {
                    return collected
                }
                collected.append(event)
            }
            cursor = page.nextCursor
        } while cursor != nil
        return collected
    }

    /// The library row a cold-start seed describes, or `nil` when the history refers
    /// to a track that is no longer there. Read off the calling actor, matching
    /// ``PlayEventRecorder``'s precedent for the synchronous repository surface.
    func fetchTrack(_ trackId: Int64) async throws -> TrackRecord? {
        let repository = tracks
        return try await Task.detached(priority: .utility) {
            try repository.fetchTrack(id: trackId)
        }.value
    }

    /// The bounded candidate pool: the seed's artist, plus the seed's genre. Both
    /// pools are `LIMIT`-capped and keyset-paged, and a seed with neither an artist
    /// nor a genre yields nothing rather than the whole library.
    ///
    /// The genre pool is profile-scoped (``LibraryVisibility``). The artist pool is
    /// narrowed by the `artistId` foreign key instead, matching what
    /// ``TrackRepository/tracksByArtist(artistId:after:limit:)`` already does for the
    /// artist-detail surface.
    func metadataCandidates(for seed: TrackRecord, profileId: Int64) async throws -> [TrackRecord] {
        var pool: [TrackRecord] = []
        if let artistId = seed.artistId {
            pool += try await artistCandidates(artistId: artistId)
        }
        if let genre = seed.genre, !genre.isEmpty {
            pool += try await genreCandidates(genre: genre, profileId: profileId)
        }
        return pool
    }

    func artistCandidates(artistId: Int64) async throws -> [TrackRecord] {
        let repository = tracks
        let size = pageSize
        return try await Task.detached(priority: .utility) {
            var pool: [TrackRecord] = []
            var cursor: PageCursor<String>?
            while pool.count < SimilarityService.maxMetadataCandidates {
                let page = try repository.tracksByArtist(artistId: artistId, after: cursor, limit: size)
                pool += page.items.prefix(SimilarityService.maxMetadataCandidates - pool.count)
                guard let next = page.nextCursor else { break }
                cursor = next
            }
            return pool
        }.value
    }

    func genreCandidates(genre: String, profileId: Int64) async throws -> [TrackRecord] {
        let repository = tracks
        let size = pageSize
        return try await Task.detached(priority: .utility) {
            var pool: [TrackRecord] = []
            var cursor: PageCursor<Int64>?
            while pool.count < SimilarityService.maxMetadataCandidates {
                let page = try repository.tracksByGenre(
                    profileId: profileId,
                    genre: genre,
                    after: cursor,
                    limit: size
                )
                pool += page.items.prefix(SimilarityService.maxMetadataCandidates - pool.count)
                guard let next = page.nextCursor else { break }
                cursor = next
            }
            return pool
        }.value
    }
}

// MARK: - Scoring

private extension SimilarityService {
    /// Rows one call may return, whatever a caller asks for.
    static func cappedLimit(_ limit: Int) -> Int {
        min(max(0, limit), PlayEventRepository.fetchLimit)
    }

    /// Co-session frequency, recency-weighted.
    ///
    /// A track scores ONCE per session it shared with the seed, not once per play:
    /// putting one song on repeat for an evening says far less about two songs
    /// belonging together than hearing them side by side on ten different evenings.
    static func coSessionScores(
        _ sessions: [ListeningSession],
        seed: Int64,
        now reference: TimeInterval
    ) -> [Int64: Double] {
        var scores: [Int64: Double] = [:]
        for session in sessions where session.trackIds.contains(seed) {
            let weight = recencyWeight(endedAt: session.endedAt, now: reference)
            for other in session.trackIds where other != seed {
                scores[other, default: 0] += weight
            }
        }
        return scores
    }

    /// Exponential decay with a ``recencyHalfLifeDays`` half-life, clamped so a
    /// session timestamped in the future (a clock that moved backwards) scores as
    /// "now" rather than as an impossible weight above 1.
    static func recencyWeight(endedAt: TimeInterval, now reference: TimeInterval) -> Double {
        let ageDays = max(0, (reference - endedAt) / ListeningLocalTime.secondsPerDay)
        return pow(0.5, ageDays / recencyHalfLifeDays)
    }

    /// Tag resemblance: artist outweighs genre outweighs decade, and the three stack.
    static func metadataScore(seed: TrackRecord, candidate: TrackRecord) -> Double {
        var score = 0.0
        if sharesArtist(seed, candidate) {
            score += sameArtistWeight
        }
        if sharesGenre(seed, candidate) {
            score += sameGenreWeight
        }
        if sharesDecade(seed, candidate) {
            score += sameDecadeWeight
        }
        return score
    }

    /// The normalised artist graph first; the denormalised name only when the graph
    /// has not been built for these rows.
    static func sharesArtist(_ seed: TrackRecord, _ candidate: TrackRecord) -> Bool {
        if let seedArtistId = seed.artistId, let candidateArtistId = candidate.artistId {
            return seedArtistId == candidateArtistId
        }
        guard let seedName = seed.artistName, !seedName.isEmpty,
              let candidateName = candidate.artistName, !candidateName.isEmpty
        else {
            return false
        }
        return seedName.caseInsensitiveCompare(candidateName) == .orderedSame
    }

    /// `caseInsensitiveCompare` rather than a `Locale`-aware comparison: the result
    /// must not change with the machine's language settings.
    static func sharesGenre(_ seed: TrackRecord, _ candidate: TrackRecord) -> Bool {
        guard let seedGenre = seed.genre, !seedGenre.isEmpty,
              let candidateGenre = candidate.genre, !candidateGenre.isEmpty
        else {
            return false
        }
        return seedGenre.caseInsensitiveCompare(candidateGenre) == .orderedSame
    }

    /// Integer division by ten — an untagged or zero year is "unknown", never the
    /// year-zero decade.
    static func sharesDecade(_ seed: TrackRecord, _ candidate: TrackRecord) -> Bool {
        guard let seedYear = seed.year, seedYear > 0,
              let candidateYear = candidate.year, candidateYear > 0
        else {
            return false
        }
        return seedYear / 10 == candidateYear / 10
    }

    /// Score descending, then `trackId` ascending.
    ///
    /// Ranking happens on the ROUNDED score — the value the caller is handed — so the
    /// published order can never disagree with the published numbers. A score that
    /// rounds to zero is dropped rather than tie-broken into the list: it means the
    /// evidence decayed past what four decimal places can express.
    static func ranked(_ scores: [Int64: Double], basis: SimilarityBasis, limit: Int) -> [SimilarTrack] {
        var neighbours: [SimilarTrack] = []
        neighbours.reserveCapacity(scores.count)
        for (trackId, raw) in scores {
            let score = StatsRounding.rounded(raw)
            guard score > 0 else { continue }
            neighbours.append(SimilarTrack(trackId: trackId, score: score, basis: basis))
        }
        neighbours.sort { lhs, rhs in
            lhs.score == rhs.score ? lhs.trackId < rhs.trackId : lhs.score > rhs.score
        }
        return Array(neighbours.prefix(limit))
    }
}
