import Foundation
import Persistence
import Services
import Testing
@testable import ViewModels

/// The `PlaylistQuerySpec` → `SmartPlaylistRules` mapping is pure, so every clause
/// and every window boundary is assertable with no database and no clock.
struct AssistantQueryTranslationTests {
    private static let instant = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: Fan-out

    /// A flat rule set has ONE match mode, so `(g1 OR g2) AND rest` is only
    /// expressible as the union of two `.all` sets. Keeping one genre would
    /// silently answer half the request.
    @Test func severalGenresBecomeOneAllRuleSetEach() {
        let spec = PlaylistQuerySpec(
            genres: ["Rock", "Metal"],
            yearRange: SmartPlaylistRange(lower: 1990, upper: 1999)
        )

        let variants = AssistantQueryTranslation.ruleVariants(for: spec, now: Self.instant, limit: 100)

        #expect(variants.count == 2)
        #expect(variants.allSatisfy { $0.match == .all })
        #expect(variants.map { genreNames($0.predicates) } == [["Rock"], ["Metal"]])
        #expect(variants.allSatisfy {
            $0.predicates.contains(.metadata(.year(range: SmartPlaylistRange(lower: 1990, upper: 1999))))
        })
    }

    @Test func aSpecWithNoNamesStillProducesExactlyOneVariant() {
        let variants = AssistantQueryTranslation.ruleVariants(
            for: PlaylistQuerySpec(moodTags: [.calm]),
            now: Self.instant,
            limit: 100
        )

        #expect(variants.count == 1)
        #expect(genreNames(variants[0].predicates).isEmpty)
    }

    @Test func seedArtistsFanOutOnlyWhenNoGenreWasNamed() {
        let artistsOnly = AssistantQueryTranslation.ruleVariants(
            for: PlaylistQuerySpec(seedArtists: ["Radiohead", "Portishead"]),
            now: Self.instant,
            limit: 100
        )
        let genreWins = AssistantQueryTranslation.ruleVariants(
            for: PlaylistQuerySpec(genres: ["Rock"], seedArtists: ["Radiohead"]),
            now: Self.instant,
            limit: 100
        )

        #expect(artistsOnly.count == 2)
        #expect(artistNames(artistsOnly[0].predicates) == ["Radiohead"])
        #expect(genreWins.count == 1)
        #expect(genreNames(genreWins[0].predicates) == ["Rock"])
        #expect(artistNames(genreWins[0].predicates).isEmpty)
    }

    @Test func fanOutIsCappedSoOneRequestCannotIssueUnboundedQueries() {
        let genres = (1 ... 12).map { "Genre\($0)" }

        let variants = AssistantQueryTranslation.ruleVariants(
            for: PlaylistQuerySpec(genres: genres),
            now: Self.instant,
            limit: 100
        )

        #expect(variants.count == AssistantQueryTranslation.maxVariants)
    }

    // MARK: Shared predicates

    @Test func everyVariantExcludesUnplayableTracks() {
        let variants = AssistantQueryTranslation.ruleVariants(
            for: PlaylistQuerySpec(genres: ["Rock"]),
            now: Self.instant,
            limit: 100
        )

        #expect(variants[0].predicates.contains(.metadata(.availability(equals: .present))))
    }

    @Test func moodTagsBecomeFeatureBucketsAndTempoBecomesABPMRange() {
        let spec = PlaylistQuerySpec(
            moodTags: [.energetic, .dark],
            tempoRange: SmartPlaylistRange(lower: 120)
        )

        let predicates = AssistantQueryTranslation.ruleVariants(
            for: spec,
            now: Self.instant,
            limit: 100
        )[0].predicates

        #expect(predicates.contains(.audioFeature(.bpm(range: SmartPlaylistRange(lower: 120)))))
        #expect(predicates.contains { predicate in
            guard case let .audioFeature(feature) = predicate,
                  case let .energy(range: range) = feature
            else {
                return false
            }
            return range.lower != nil && range.upper == nil
        })
        #expect(predicates.contains { predicate in
            guard case let .audioFeature(feature) = predicate,
                  case let .brightness(range: range) = feature
            else {
                return false
            }
            return range.upper != nil && range.lower == nil
        })
    }

    /// `.freshlyAdded` is a LIBRARY-age question and `.recentlyPlayed` /
    /// `.rediscovery` are PLAY-history questions — different predicate families,
    /// not different parameters of one.
    @Test func eachRecencyPreferenceMapsToItsOwnPredicateFamily() {
        let cutoff = Self.instant.timeIntervalSince1970
            - Double(AssistantQueryTranslation.freshlyAddedWindowDays) * 86400

        #expect(predicates(for: .freshlyAdded).contains(
            .metadata(.dateAdded(range: SmartPlaylistRange(lower: cutoff)))
        ))
        #expect(predicates(for: .recentlyPlayed).contains(
            .recency(.playedWithin(days: AssistantQueryTranslation.recentlyPlayedWindowDays))
        ))
        #expect(predicates(for: .rediscovery).contains(
            .recency(.notPlayedWithin(days: AssistantQueryTranslation.rediscoveryWindowDays))
        ))
    }

    // MARK: Merge

    /// Round-robin rather than concatenation: the merged list is scored BY POSITION
    /// downstream, so concatenating would hand the whole mix to the first genre.
    @Test func mergingInterleavesVariantsAndDropsDuplicates() {
        let merged = AssistantQueryTranslation.mergedTrackIds([[1, 2, 3], [4, 1, 5]])

        #expect(merged == [1, 4, 2, 3, 5])
    }

    @Test func mergingHonoursTheCeilingAndSurvivesRaggedInput() {
        #expect(AssistantQueryTranslation.mergedTrackIds([[1, 2, 3], [4]], limit: 3) == [1, 4, 2])
        #expect(AssistantQueryTranslation.mergedTrackIds([[], [7], []]) == [7])
        #expect(AssistantQueryTranslation.mergedTrackIds([]).isEmpty)
        #expect(AssistantQueryTranslation.mergedTrackIds([[1, 2]], limit: 0).isEmpty)
    }

    // MARK: Helpers

    private func predicates(for recency: PlaylistRecencyPreference) -> [SmartPlaylistPredicate] {
        AssistantQueryTranslation.ruleVariants(
            for: PlaylistQuerySpec(recency: recency),
            now: Self.instant,
            limit: 100
        )[0].predicates
    }

    private func genreNames(_ predicates: [SmartPlaylistPredicate]) -> [String] {
        predicates.compactMap { predicate in
            guard case let .metadata(metadata) = predicate,
                  case let .genre(equals: name) = metadata
            else {
                return nil
            }
            return name
        }
    }

    private func artistNames(_ predicates: [SmartPlaylistPredicate]) -> [String] {
        predicates.compactMap { predicate in
            guard case let .metadata(metadata) = predicate,
                  case let .artistName(equals: name) = metadata
            else {
                return nil
            }
            return name
        }
    }
}
