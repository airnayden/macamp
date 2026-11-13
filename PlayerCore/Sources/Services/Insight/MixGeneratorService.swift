// MixGeneratorService — one candidate pool in, one ranked ``PlaylistDraft`` out.
//
// This is the join between the insight engine (todos 5–7: rules results,
// similarity, rediscovery, dayparts) and everything that proposes a playlist to
// the user (todo 9's generated auto-mixes, todo 14's assistant). It owns no
// scoring policy of its own: each source supplies its own ranking, this service
// normalises it into ``MixCandidate`` values, and ``MixRanking``'s four pure
// steps decide the playing order.
//
// Three properties are the contract:
//
//  * DETERMINISM. The only inputs to the ordering are the spec, the seed and the
//    library. There is no `Date()`, no unseeded `shuffled()`, no `Int.random`
//    anywhere in the pipeline — so a preview and the apply that follows it show
//    the same mix, and an evidence run reproduces exactly.
//  * NO WRITES. Generating a mix reads; it never materialises anything. That is
//    why ``MixCandidateSource/rulesResult(trackIds:)`` takes ids rather than a
//    playlist id: evaluating smart-playlist rules rewrites `playlistTrack` rows,
//    and the caller must be the one to decide when that happens.
//  * NO PADDING. A pool smaller than the target yields a shorter draft flagged
//    ``PlaylistDraft/underfilled``. Repeating a track to hit a number would be a
//    worse mix than a short one, and a duplicate id would break materialisation
//    (`playlistTrack` is positioned, and a preview cannot explain a repeat).
//
// Bounds: the pool is capped at ``MixGeneratorService/maxPoolSize``, which is
// also the ceiling the insight services impose on their own lists, and every
// metadata read goes through ``MixCandidateResolving``'s chunked path.
import Foundation
import Persistence

/// Builds a ranked, annotated track proposal from one candidate pool.
public protocol MixGenerating: Sendable {
    /// The draft `spec` describes. Empty — never an error — when the pool is
    /// empty; short and ``PlaylistDraft/underfilled`` when it is merely small.
    func generate(_ spec: MixSpec) async throws -> PlaylistDraft
}

/// The production ``MixGenerating`` over the todo 5–7 insight services.
public struct MixGeneratorService: MixGenerating {
    /// How much bigger than the target the candidate pool is drawn.
    ///
    /// De-clumping can only move a track it has; asking for exactly the target
    /// leaves the greedy placement no alternatives and every pool degrades to
    /// its score order. Three is the smallest multiplier that gives the spacing
    /// rule real choices at the default spacing of three.
    public static let poolMultiplier = 3

    /// Ceiling on the candidate pool. Matches ``RediscoveryService/maxLimit``
    /// and ``DaypartService/maxLimit`` — a larger request would be clamped by
    /// the source anyway, so asking for one would only misreport the pool size.
    public static let maxPoolSize = 100

    private let similarity: any SimilarityProviding
    private let rediscovery: any RediscoveryProviding
    private let dayparts: any DaypartProviding
    private let resolver: any MixCandidateResolving

    /// - Parameters:
    ///   - similarity: The seed-based pool.
    ///   - rediscovery: The three "you have forgotten this" pools.
    ///   - dayparts: The time-of-day pools, and the clock behind
    ///     ``MixCandidateSource/daypart(part:)``'s `nil` request.
    ///   - resolver: Artist, duration and energy for the pooled ids.
    public init(
        similarity: any SimilarityProviding,
        rediscovery: any RediscoveryProviding,
        dayparts: any DaypartProviding,
        resolver: any MixCandidateResolving
    ) {
        self.similarity = similarity
        self.rediscovery = rediscovery
        self.dayparts = dayparts
        self.resolver = resolver
    }

    /// Convenience over the application database.
    ///
    /// `now` is plumbing for the insight services' own recency windows — this
    /// service never reads a clock, and nothing in its ordering depends on one.
    public init(_ appDatabase: AppDatabase, now: @escaping @Sendable () -> Date = { Date() }) {
        self.init(
            similarity: SimilarityService(appDatabase, now: now),
            rediscovery: RediscoveryService(appDatabase, now: now),
            dayparts: DaypartService(appDatabase, now: now),
            resolver: MixCandidateResolver(appDatabase)
        )
    }

    public func generate(_ spec: MixSpec) async throws -> PlaylistDraft {
        let source = resolvedSource(spec.source)
        let raw = try await candidates(
            from: source,
            profileId: spec.profileId,
            limit: Self.poolLimit(targetCount: spec.targetCount)
        )
        let pool = try await enriched(raw, profileId: spec.profileId)
        var generator = MixRandom(seed: spec.seed)
        let scored = MixRanking.scoreOrdered(pool, using: &generator)
        let spaced = MixRanking.deClumped(scored, spacing: spec.constraints.artistSpacing)
        let chosen = MixRanking.selected(
            spaced,
            targetCount: spec.targetCount,
            targetDuration: spec.targetDuration
        )
        let arced = spec.constraints.energyArc ? MixRanking.energyArced(chosen) : nil
        return Self.draft(
            arced ?? chosen,
            spec: spec,
            source: source,
            poolSize: pool.count,
            arcApplied: arced != nil
        )
    }
}

// MARK: - Candidate pools

private extension MixGeneratorService {
    /// Turns a `nil` daypart request into the concrete bucket it is now, once,
    /// so every step downstream — including the draft's name slot — records the
    /// bucket the mix was actually built for.
    func resolvedSource(_ source: MixCandidateSource) -> MixCandidateSource {
        guard case let .daypart(part) = source, part == nil else { return source }
        return .daypart(part: dayparts.currentDaypart())
    }

    static func poolLimit(targetCount: Int) -> Int {
        min(maxPoolSize, max(targetCount, targetCount * poolMultiplier))
    }

    func candidates(
        from source: MixCandidateSource,
        profileId: Int64,
        limit: Int
    ) async throws -> [MixCandidate] {
        switch source {
        case let .rulesResult(trackIds):
            Self.rankScored(Array(trackIds.prefix(limit)), provenance: .rulesResult)
        case let .similaritySeed(trackId):
            try await similarCandidates(seed: trackId, profileId: profileId, limit: limit)
        case let .rediscovery(list):
            try await rediscoveryCandidates(list, profileId: profileId, limit: limit)
        case let .daypart(part):
            try await daypartCandidates(part ?? dayparts.currentDaypart(), profileId: profileId, limit: limit)
        }
    }

    func similarCandidates(seed: Int64, profileId: Int64, limit: Int) async throws -> [MixCandidate] {
        let neighbours = try await similarity.similar(to: seed, profileId: profileId, limit: limit)
        return neighbours.map { neighbour in
            MixCandidate(
                trackId: neighbour.trackId,
                provenance: neighbour.basis == .coSession ? .coSession : .metadataNeighbour,
                score: neighbour.score
            )
        }
    }

    func rediscoveryCandidates(
        _ list: RediscoveryList,
        profileId: Int64,
        limit: Int
    ) async throws -> [MixCandidate] {
        switch list {
        case .forgottenFavourites:
            let rows = try await rediscovery.forgottenFavourites(profileId: profileId, limit: limit)
            return Self.rankScored(rows.map(\.trackId), provenance: .forgottenFavourite)
        case .neverPlayed:
            // This list walks the library in `(sortTitle, id)` order and stops
            // early, so it is ALPHABETICAL, not ranked. A rank-derived score
            // would bake that bias into the playing order; a flat score hands the
            // whole pool to the seeded tie-break, which shuffles it reproducibly
            // through the same mechanism that breaks every other tie.
            let rows = try await rediscovery.neverPlayed(profileId: profileId, limit: limit)
            return rows.map { MixCandidate(trackId: $0.trackId, provenance: .neverPlayed, score: 1) }
        case .throwbacks:
            let rows = try await rediscovery.throwbacks(profileId: profileId, limit: limit)
            return Self.rankScored(rows.map(\.trackId), provenance: .throwback)
        }
    }

    func daypartCandidates(_ part: Daypart, profileId: Int64, limit: Int) async throws -> [MixCandidate] {
        let rows = try await dayparts.topTracks(profileId: profileId, daypart: part, limit: limit)
        return rows.map { row in
            MixCandidate(trackId: row.trackId, provenance: .daypart(part), score: Double(row.plays))
        }
    }

    /// Scores an already-ranked id list by its position, so the source's own
    /// ordering survives step 1 intact and no two candidates tie.
    static func rankScored(_ trackIds: [Int64], provenance: MixProvenance) -> [MixCandidate] {
        let count = Double(max(1, trackIds.count))
        return trackIds.enumerated().map { index, trackId in
            MixCandidate(
                trackId: trackId,
                provenance: provenance,
                score: 1 - Double(index) / count
            )
        }
    }
}

// MARK: - Enrichment and assembly

private extension MixGeneratorService {
    /// Attaches artist, duration and energy, DROPPING any candidate the library
    /// could not resolve to a `present` row.
    ///
    /// Dropping is the point, not a side effect. `playEvent.trackId` is a bare
    /// integer with no foreign key, so co-session similarity can legitimately
    /// name a track whose row has since been removed — proposing it would put an
    /// id in a draft that materialisation could not insert. And a `missing` or
    /// `externalOffline` row is still in the library by design, but a mix is a
    /// list of things to PLAY, so it is filtered here for the same reason
    /// ``RediscoveryService`` filters it: the two candidate sources that do not
    /// filter for themselves are co-session similarity (scored from `playEvent`,
    /// which records no availability) and ``MixCandidateSource/rulesResult(trackIds:)``
    /// (whatever the caller hands over).
    func enriched(_ raw: [MixCandidate], profileId: Int64) async throws -> [MixCandidate] {
        guard !raw.isEmpty else { return [] }
        let facts = try await resolver.facts(profileId: profileId, trackIds: raw.map(\.trackId))
        return raw.compactMap { candidate in
            guard let fact = facts[candidate.trackId] else { return nil }
            var enriched = candidate
            enriched.artistKey = fact.artistKey
            enriched.duration = fact.duration
            enriched.energy = fact.energy
            return enriched
        }
    }

    static func draft(
        _ chosen: [MixCandidate],
        spec: MixSpec,
        source: MixCandidateSource,
        poolSize: Int,
        arcApplied: Bool
    ) -> PlaylistDraft {
        PlaylistDraft(
            entries: chosen.map { candidate in
                MixDraftEntry(
                    trackId: candidate.trackId,
                    provenance: candidate.provenance,
                    score: candidate.score,
                    energy: candidate.energy
                )
            },
            nameHint: MixNameHint(
                sourceKind: source.kind,
                trackCount: chosen.count,
                seedTrackId: source.seedTrackId,
                daypart: source.requestedDaypart
            ),
            underfilled: poolSize < spec.targetCount,
            artistSpacingSatisfied: MixRanking.spacingSatisfied(
                chosen,
                spacing: spec.constraints.artistSpacing
            ),
            energyArcApplied: arcApplied,
            totalDuration: chosen.reduce(0) { $0 + ($1.duration ?? 0) }
        )
    }
}
