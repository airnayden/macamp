// AssistantQueryTranslation — the pure ``PlaylistQuerySpec`` -> rule-set mapping.
//
// A spec says what the listener asked for in the assistant's vocabulary; a
// ``SmartPlaylistRules`` set says it in the rule engine's. Every field maps onto a
// predicate that already exists (see `PlaylistQuerySpec`'s own provenance table),
// so this is a translation and never an invention.
//
// ── WHY IT RETURNS SEVERAL RULE SETS, NOT ONE ──────────────────────────────────
//
// `SmartPlaylistRules` has ONE flat `match` mode for the whole predicate list, so
// it cannot express `(genre = Rock OR genre = Metal) AND year IN 1990...1999` —
// `.all` would demand a track be both genres at once, and `.any` would let the
// year fall away. The identity
//
//     (g1 OR g2) AND rest  ==  (g1 AND rest) UNION (g2 AND rest)
//
// makes the fan-out exact rather than approximate: one `.all` rule set per genre,
// each carrying every other constraint, unioned by ``mergedTrackIds(_:limit:)``.
// The alternative — keeping only the first genre — silently drops half a request.
//
// ── WHY THE MOOD RANGES LIVE HERE ──────────────────────────────────────────────
//
// `PlaylistQuerySpec` says bucket ranges "live with the parser", but the parser
// emits ``PlaylistMoodTag`` VALUES, not ranges — the tag survives into the spec,
// so the tag -> `trackAudioFeature` range mapping necessarily happens at
// resolution, which is here. All four buckets are deliberately generous: an
// un-analysed track is never excluded by a feature predicate anyway (todo 5
// compiles them as `col IS NULL OR range`), so a narrow bucket would only bite the
// listeners who DID run the analysis pass.
//
// Nothing in this file performs I/O, reads a clock or touches a repository: `now`
// is a parameter, so every recency window is testable on its exact boundary.
//
// This file imports only Foundation + Persistence + Services; it MUST NOT import
// AppKit or UIKit (PlayerCore portability invariant).
import Foundation
import Persistence
import Services

/// Lowers an assistant query spec into bounded, read-only rule sets.
public enum AssistantQueryTranslation {
    /// How many genre (or artist) variants one request may fan out into.
    ///
    /// Matches `HeuristicQueryParser`'s own `maxMatchedGenres`, so a tier-2 spec
    /// can never produce more variants than the parser was willing to match.
    public static let maxVariants = 6

    /// Ceiling on the merged candidate pool.
    ///
    /// The mix generator clamps its own pool to `MixGeneratorService.maxPoolSize`
    /// anyway; this bounds what is carried between the two so a six-variant fan-out
    /// cannot materialise thousands of ids in memory first.
    public static let maxPoolIds = 300

    /// Days back that `.freshlyAdded` counts as fresh.
    public static let freshlyAddedWindowDays = 30
    /// Days back that `.recentlyPlayed` counts as recent.
    public static let recentlyPlayedWindowDays = 30
    /// Silence, in days, that `.rediscovery` asks for.
    public static let rediscoveryWindowDays = 90

    /// One `.all` rule set per name variant — always at least one.
    ///
    /// - Parameters:
    ///   - spec: The parsed request.
    ///   - now: The instant recency windows are measured back from.
    ///   - limit: Rows each variant may select. Clamped by
    ///     ``SmartPlaylistRules/effectiveLimit`` regardless.
    public static func ruleVariants(
        for spec: PlaylistQuerySpec,
        now: Date,
        limit: Int
    ) -> [SmartPlaylistRules] {
        let shared = sharedPredicates(for: spec, now: now)
        return nameVariants(for: spec).map { variant in
            SmartPlaylistRules(
                match: .all,
                predicates: shared + variant,
                sort: SmartPlaylistSort(field: .playCount, direction: .descending),
                limit: limit
            )
        }
    }

    /// Round-robin union of each variant's ids, de-duplicated, order-preserving.
    ///
    /// Round-robin rather than concatenation because the merged list is scored BY
    /// POSITION downstream (`MixCandidateSource.rulesResult`), so concatenating
    /// would hand the whole mix to the first genre and starve the rest.
    public static func mergedTrackIds(_ variantResults: [[Int64]], limit: Int = maxPoolIds) -> [Int64] {
        let ceiling = max(0, limit)
        guard ceiling > 0 else { return [] }
        var merged: [Int64] = []
        var seen = Set<Int64>()
        var cursor = 0
        let deepest = variantResults.map(\.count).max() ?? 0
        while cursor < deepest, merged.count < ceiling {
            for result in variantResults where cursor < result.count {
                guard merged.count < ceiling else { break }
                let trackId = result[cursor]
                guard seen.insert(trackId).inserted else { continue }
                merged.append(trackId)
            }
            cursor += 1
        }
        return merged
    }
}

// MARK: - Predicate assembly

private extension AssistantQueryTranslation {
    /// Everything the request constrains EXCEPT the genre/artist name, which is
    /// what the variants differ by.
    static func sharedPredicates(for spec: PlaylistQuerySpec, now: Date) -> [SmartPlaylistPredicate] {
        var predicates: [SmartPlaylistPredicate] = [.metadata(.availability(equals: .present))]
        if let yearRange = spec.yearRange {
            predicates.append(.metadata(.year(range: yearRange)))
        }
        if let tempoRange = spec.tempoRange {
            predicates.append(.audioFeature(.bpm(range: tempoRange)))
        }
        predicates.append(contentsOf: spec.moodTags.map { .audioFeature(featurePredicate(for: $0)) })
        if let recency = spec.recency {
            predicates.append(recencyPredicate(for: recency, now: now))
        }
        return predicates
    }

    /// The name filters to fan out over.
    ///
    /// Genres win when present: a spec carrying both genres and seed artists is
    /// asking for "rock BY Radiohead", and a flat rule set cannot AND two OR-groups
    /// — so widening to "rock OR Radiohead" would answer a different question.
    /// Artists are still carried on the proposal's `querySpec` for the preview.
    static func nameVariants(for spec: PlaylistQuerySpec) -> [[SmartPlaylistPredicate]] {
        if !spec.genres.isEmpty {
            return spec.genres.prefix(maxVariants).map { [.metadata(.genre(equals: $0))] }
        }
        if !spec.seedArtists.isEmpty {
            return spec.seedArtists.prefix(maxVariants).map { [.metadata(.artistName(equals: $0))] }
        }
        return [[]]
    }

    static func featurePredicate(for tag: PlaylistMoodTag) -> SmartPlaylistAudioFeaturePredicate {
        switch tag {
        case .calm: .energy(range: SmartPlaylistRange(upper: 0.45))
        case .energetic: .energy(range: SmartPlaylistRange(lower: 0.55))
        case .dark: .brightness(range: SmartPlaylistRange(upper: 0.45))
        case .bright: .brightness(range: SmartPlaylistRange(lower: 0.55))
        }
    }

    /// `.freshlyAdded` is a LIBRARY-age window (`track.dateAdded`); the other two
    /// are PLAY-history windows (`playEvent`). They are different questions and map
    /// to different predicate families.
    static func recencyPredicate(
        for preference: PlaylistRecencyPreference,
        now: Date
    ) -> SmartPlaylistPredicate {
        switch preference {
        case .freshlyAdded:
            let cutoff = now.timeIntervalSince1970 - Double(freshlyAddedWindowDays) * 86400
            return .metadata(.dateAdded(range: SmartPlaylistRange(lower: cutoff)))
        case .recentlyPlayed:
            return .recency(.playedWithin(days: recentlyPlayedWindowDays))
        case .rediscovery:
            return .recency(.notPlayedWithin(days: rediscoveryWindowDays))
        }
    }
}
