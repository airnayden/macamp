// FMQuerySpecMappingTests — the pure validation layer of the FM tier.
//
// Every test here runs with NO FoundationModels, NO session and NO Apple
// Intelligence: `FMQuerySpecFields.resolve(validGenres:)` is floor-available by
// design, so the decisions that can actually be wrong — is this a real genre, is
// this a servable mood, is 19 a plausible year — are table-testable on any host.
// That is the same split `AssistantAvailability.resolve(raw:intelligenceEnabled:)`
// makes, and the reason this file carries no `@available` attribute.
import Foundation
import Persistence
import PlayerCoreTestSupport
import Services
import Testing

@Suite("FMQuerySpecGenreValidation")
struct FMQuerySpecGenreValidationTests {
    private let library = ["Rock", "Progressive Metal", "Jazz"]

    @Test("A genre the library holds survives, rewritten to the library's spelling")
    func genreIsCanonicalized() {
        let fields = FMQuerySpecFields(genres: ["rock", "PROGRESSIVE METAL"])
        let spec = fields.resolve(validGenres: library)
        #expect(spec.genres == ["Rock", "Progressive Metal"])
    }

    @Test("A genre the library does not hold is dropped, not passed through")
    func unknownGenreIsDropped() {
        let fields = FMQuerySpecFields(genres: ["Rock", "Vaporwave", "Jazz"])
        let spec = fields.resolve(validGenres: library)
        #expect(spec.genres == ["Rock", "Jazz"])
    }

    @Test("Surrounding whitespace does not stop a genre from matching")
    func genreMatchIgnoresWhitespace() {
        let spec = FMQuerySpecFields(genres: ["  Jazz "]).resolve(validGenres: library)
        #expect(spec.genres == ["Jazz"])
    }

    @Test("An empty vocabulary passes genres through rather than dropping them all")
    func emptyVocabularyPassesThrough() {
        // Dropping every genre would silently turn "90s rock" into "90s anything",
        // which misstates the request more badly than an empty result does.
        let spec = FMQuerySpecFields(genres: ["Rock", "Vaporwave"]).resolve(validGenres: [])
        #expect(spec.genres == ["Rock", "Vaporwave"])
    }

    @Test("Genre order is preserved and duplicates collapse to the first spelling")
    func genreOrderSurvivesDeduplication() {
        let fields = FMQuerySpecFields(genres: ["Jazz", "rock", "ROCK"])
        let spec = fields.resolve(validGenres: library)
        #expect(spec.genres == ["Jazz", "Rock"])
    }

    @Test("A library holding two spellings resolves deterministically to the first")
    func duplicateLibrarySpellingsAreDeterministic() {
        let spec = FMQuerySpecFields(genres: ["ROCK"]).resolve(validGenres: ["Rock", "rock"])
        #expect(spec.genres == ["Rock"])
    }
}

@Suite("FMQuerySpecVocabulary")
struct FMQuerySpecVocabularyTests {
    @Test("The mood vocabulary is derived from PlaylistMoodTag and cannot drift")
    func moodVocabularyTracksTheEnum() {
        #expect(FMQuerySpecFields.moodVocabulary == PlaylistMoodTag.allCases.map(\.rawValue))
        // The `@Guide(.element(.anyOf(...)))` literal in `FMQuerySpecDTO` cannot be
        // read back (a macro argument is not a stored value), so it is pinned here
        // instead: adding a `PlaylistMoodTag` case fails this assertion, which is
        // the prompt to update the guide literal alongside it.
        #expect(FMQuerySpecFields.moodVocabulary == ["calm", "energetic", "dark", "bright"])
    }

    @Test("The recency vocabulary is the enum plus the explicit no-preference sentinel")
    func recencyVocabularyTracksTheEnum() {
        let expected = ["none"] + PlaylistRecencyPreference.allCases.map(\.rawValue)
        #expect(FMQuerySpecFields.recencyVocabulary == expected)
        #expect(FMQuerySpecFields.recencyVocabulary == ["none", "freshlyAdded", "recentlyPlayed", "rediscovery"])
    }

    @Test("A servable mood maps, case-insensitively; an unservable one is dropped")
    func moodsMapOrDrop() {
        let fields = FMQuerySpecFields(moodTags: ["ENERGETIC", "euphoric", "dark"])
        let spec = fields.resolve(validGenres: [])
        // "euphoric" is a valence word and nothing in this app measures valence,
        // so it is dropped rather than silently rendered as "energetic".
        #expect(spec.moodTags == [.energetic, .dark])
    }

    @Test("Every recency word maps, and none/unknown/empty all mean no preference")
    func recencyMapsOrClears() {
        for preference in PlaylistRecencyPreference.allCases {
            let spec = FMQuerySpecFields(recency: preference.rawValue).resolve(validGenres: [])
            #expect(spec.recency == preference)
        }
        for absent in ["none", "", "  ", "whenever"] {
            let spec = FMQuerySpecFields(recency: absent).resolve(validGenres: [])
            #expect(spec.recency == nil)
        }
        #expect(FMQuerySpecFields(recency: nil).resolve(validGenres: []).recency == nil)
    }
}

@Suite("FMQuerySpecRanges")
struct FMQuerySpecRangeTests {
    @Test("Two plausible year bounds become a closed range")
    func yearRangeIsAssembled() {
        let fields = FMQuerySpecFields(yearLowerBound: 1990, yearUpperBound: 1999)
        let spec = fields.resolve(validGenres: [])
        #expect(spec.yearRange == SmartPlaylistRange(lower: 1990, upper: 1999))
    }

    @Test("One bound is enough; the other stays unbounded")
    func halfOpenYearRangeSurvives() {
        let spec = FMQuerySpecFields(yearUpperBound: 2000).resolve(validGenres: [])
        #expect(spec.yearRange == SmartPlaylistRange(lower: nil, upper: 2000))
    }

    @Test("An implausible year bound is DROPPED, never clamped to the nearest legal one")
    func implausibleYearIsDropped() {
        // Clamping `19` to 1860 would state a constraint the listener never asked
        // for; dropping leaves it unbounded, which SmartPlaylistRange documents as
        // "no constraint" and which widens rather than falsifies.
        let fields = FMQuerySpecFields(yearLowerBound: 19, yearUpperBound: 1999)
        let spec = fields.resolve(validGenres: [])
        #expect(spec.yearRange == SmartPlaylistRange(lower: nil, upper: 1999))
    }

    @Test("A range with no surviving bound collapses to nil rather than to an empty window")
    func fullyImplausibleRangeCollapses() {
        let spec = FMQuerySpecFields(yearLowerBound: 12, yearUpperBound: 99999).resolve(validGenres: [])
        #expect(spec.yearRange == nil)
    }

    @Test("An inverted pair is swapped, because the request was clear and the ordering slipped")
    func invertedRangeIsSwapped() {
        let fields = FMQuerySpecFields(yearLowerBound: 2000, yearUpperBound: 1990)
        let spec = fields.resolve(validGenres: [])
        #expect(spec.yearRange == SmartPlaylistRange(lower: 1990, upper: 2000))
    }

    @Test("Tempo bounds follow the same plausibility and inversion rules")
    func tempoRangeFollowsTheSameRules() {
        let assembled = FMQuerySpecFields(tempoLowerBPM: 120, tempoUpperBPM: 140)
            .resolve(validGenres: []).tempoRange
        #expect(assembled == SmartPlaylistRange(lower: 120.0, upper: 140.0))

        let dropped = FMQuerySpecFields(tempoLowerBPM: 0, tempoUpperBPM: 140)
            .resolve(validGenres: []).tempoRange
        #expect(dropped == SmartPlaylistRange(lower: nil, upper: 140.0))

        let swapped = FMQuerySpecFields(tempoLowerBPM: 180, tempoUpperBPM: 90)
            .resolve(validGenres: []).tempoRange
        #expect(swapped == SmartPlaylistRange(lower: 90.0, upper: 180.0))
    }

    @Test("The plausibility windows are inclusive at both edges")
    func plausibilityWindowsAreInclusive() {
        let years = FMQuerySpecFields(yearLowerBound: 1860, yearUpperBound: 2999)
            .resolve(validGenres: []).yearRange
        #expect(years == SmartPlaylistRange(lower: 1860, upper: 2999))

        let tempi = FMQuerySpecFields(tempoLowerBPM: 20, tempoUpperBPM: 400)
            .resolve(validGenres: []).tempoRange
        #expect(tempi == SmartPlaylistRange(lower: 20.0, upper: 400.0))
    }
}

@Suite("FMQuerySpecConfidence")
struct FMQuerySpecConfidenceTests {
    @Test("A spec that constrains nothing is marked low-confidence")
    func unconstrainedIsLowConfidence() {
        let spec = FMQuerySpecFields().resolve(validGenres: [])
        #expect(spec.isUnconstrained)
        #expect(spec.lowConfidence)
    }

    @Test("A spec whose every value was dropped is low-confidence, not a confident empty read")
    func everythingDroppedIsLowConfidence() {
        let fields = FMQuerySpecFields(
            genres: ["Vaporwave"],
            yearLowerBound: 5,
            moodTags: ["euphoric"],
            recency: "whenever"
        )
        let spec = fields.resolve(validGenres: ["Rock"])
        #expect(spec.isUnconstrained)
        #expect(spec.lowConfidence)
    }

    @Test("One surviving constraint is enough to be a confident read")
    func anySurvivingConstraintIsConfident() {
        let spec = FMQuerySpecFields(moodTags: ["calm"]).resolve(validGenres: [])
        #expect(!spec.isUnconstrained)
        #expect(!spec.lowConfidence)
    }

    @Test("An omitted target count falls back to the mix default and is clamped")
    func targetCountDefaultsAndClamps() {
        #expect(FMQuerySpecFields().resolve(validGenres: []).targetCount == MixSpec.defaultTargetCount)
        #expect(FMQuerySpecFields(targetCount: 0).resolve(validGenres: []).targetCount == 1)
        #expect(
            FMQuerySpecFields(targetCount: 10000).resolve(validGenres: []).targetCount
                == MixSpec.maxTargetCount
        )
    }

    @Test("A realistic request resolves end to end")
    func upbeatNinetiesRockResolves() {
        let fields = FMQuerySpecFields(
            genres: ["rock"],
            yearLowerBound: 1990,
            yearUpperBound: 1999,
            moodTags: ["energetic"],
            recency: "none",
            targetCount: 30
        )
        let spec = fields.resolve(validGenres: ["Rock", "Jazz"])
        #expect(spec.genres == ["Rock"])
        #expect(spec.yearRange == SmartPlaylistRange(lower: 1990, upper: 1999))
        #expect(spec.moodTags == [.energetic])
        #expect(spec.recency == nil)
        #expect(spec.targetCount == 30)
        #expect(!spec.lowConfidence)
    }
}

@Suite("AssistantLibraryContextBounds")
struct AssistantLibraryContextTests {
    private func oversized() -> AssistantLibraryContext {
        AssistantLibraryContext(
            genres: (0 ..< 500).map { "Genre \($0)" },
            artists: (0 ..< 500).map { "Artist \($0)" },
            summary: String(repeating: "x", count: 10000)
        )
    }

    @Test("The caps are enforced in init, so a worst-case prompt is bounded by construction")
    func initEnforcesCaps() {
        let context = oversized()
        #expect(context.genres.count == AssistantLibraryContext.maxGenres)
        #expect(context.artists.count == AssistantLibraryContext.maxArtists)
        #expect(context.summary.count == AssistantLibraryContext.maxSummaryLength)
    }

    @Test("Halving reduces every axis, and repeated halving terminates at empty")
    func halvingShrinksAndTerminates() {
        var context = oversized()
        let firstHalf = context.halved()
        #expect(firstHalf.genres.count == AssistantLibraryContext.maxGenres / 2)
        #expect(firstHalf.artists.count == AssistantLibraryContext.maxArtists / 2)
        #expect(firstHalf.summary.count == AssistantLibraryContext.maxSummaryLength / 2)

        for _ in 0 ..< 64 {
            context = context.halved()
        }
        #expect(context.genres.isEmpty)
        #expect(context.artists.isEmpty)
        #expect(context.summary.isEmpty)
    }

    @Test("Instructions name the locale and constrain genres to the library's own list")
    func instructionsCarryTheVocabulary() {
        let context = AssistantLibraryContext(genres: ["Rock", "Jazz"], artists: ["Radiohead"])
        let text = context.instructionsText(locale: Locale(identifier: "en_US"))
        #expect(text.contains("en_US"))
        #expect(text.contains("Rock, Jazz"))
        #expect(text.contains("Radiohead"))
    }

    @Test("An empty context still produces usable instructions with no dangling list")
    func emptyContextInstructionsAreClean() {
        let text = AssistantLibraryContext().instructionsText(locale: Locale(identifier: "de_DE"))
        #expect(text.contains("de_DE"))
        #expect(!text.contains("library's genres"))
        #expect(!text.isEmpty)
    }

    @Test("A halved context yields strictly shorter instructions")
    func halvedInstructionsAreShorter() {
        let context = AssistantLibraryContext(genres: ["Rock", "Jazz", "Pop", "Metal"])
        let locale = Locale(identifier: "en_US")
        let full = context.instructionsText(locale: locale)
        let half = context.halved().instructionsText(locale: locale)
        #expect(half.count < full.count)
    }
}
