// AssistantTemplateTests — the tier that always answers, and the ladders into it.
//
// ── HOW THESE ASSERT, AND WHY ────────────────────────────────────────────────
//
// PlayerCore ships NO String Catalog, so inside this test bundle every
// `LocalizedStringResource` resolves to its English `defaultValue` in EVERY locale.
// Comparing rendered text against a hand-written English literal would therefore
// prove nothing about localization — it would only re-state the `defaultValue` a
// second time, and would keep passing if the key were misspelled.
//
// So these tests assert two things instead:
//
//   1. WHICH RESOURCE was chosen, by its catalog `key`. That is the branch under
//      test, and a typo in the key is a failure here rather than a silent
//      English-forever bug in the shipped app.
//   2. That the assembled string equals the SAME resource resolved through the same
//      `resolved(in:)` call the production code uses — so the interpolation is
//      pinned without a literal ever being copied.
//
// Proving that a non-English locale actually renders differently needs a bundle
// that HOLDS the catalog, which only a shell test target has. That assertion lives
// in `macOS/Tests/AssistantLocalizationTests.swift`.
import Foundation
@testable import Services
import Testing

// MARK: - Fixtures

private enum NamingFixtures {
    static let locale = Locale(identifier: "en")

    /// The plan's happy-path draft: dominated by Rock, dominated by the 1990s.
    static func rockNineties() -> PlaylistNamingContext {
        PlaylistNamingContext(
            trackCount: 25,
            topGenres: [AssistantNameCount(name: "Rock", count: 15), AssistantNameCount(name: "Jazz", count: 10)],
            topArtists: [AssistantNameCount(name: "Radiohead", count: 6)],
            distinctArtistCount: 9,
            dominantDecade: 1990
        )
    }
}

// MARK: - Naming ladder

@Suite("AssistantNamingTemplates")
struct AssistantNamingTemplateTests {
    private static let locale = NamingFixtures.locale

    @Test("A genre-and-decade draft earns the most specific template, with both values interpolated")
    func genreAndDecadeChooseTheMostSpecificTemplate() {
        let context = NamingFixtures.rockNineties()
        let resource = AssistantNamingTemplates.nameResource(for: context, locale: Self.locale)

        #expect(resource.key == "assistant.naming.template.genreDecade")
        // Built from the SAME constant + the same interpolation the production path
        // uses, never from a copied English literal.
        let expected = AssistantStrings.nameGenreDecade(genre: "Rock", decade: "1990").resolved(in: Self.locale)
        #expect(AssistantNamingTemplates.fallbackName(for: context, locale: Self.locale).name == expected)
        // …and the DATA is present verbatim: a genre is library data, never translated.
        #expect(expected.contains("Rock"))
        #expect(expected.contains("1990"))
    }

    @Test("The ladder degrades one rung at a time as aggregates drop away")
    func ladderDegradesOneRungAtATime() {
        let rock = [AssistantNameCount(name: "Rock", count: 15)]
        let artist = [AssistantNameCount(name: "Radiohead", count: 12)]
        let cases: [(PlaylistNamingContext, String)] = [
            (
                PlaylistNamingContext(trackCount: 15, topGenres: rock, dominantDecade: 1980),
                "assistant.naming.template.genreDecade"
            ),
            (
                PlaylistNamingContext(trackCount: 15, topGenres: rock, moodTags: [.energetic]),
                "assistant.naming.template.moodGenre"
            ),
            (
                PlaylistNamingContext(trackCount: 15, topGenres: rock),
                "assistant.naming.template.genre"
            ),
            (
                PlaylistNamingContext(trackCount: 12, topArtists: artist, distinctArtistCount: 1),
                "assistant.naming.template.artist"
            ),
            (
                PlaylistNamingContext(trackCount: 20, dominantDecade: 1970),
                "assistant.naming.template.decade"
            ),
            (
                PlaylistNamingContext(trackCount: 20, moodTags: [.calm]),
                "assistant.naming.template.mood"
            ),
            (
                PlaylistNamingContext(trackCount: 20),
                "assistant.naming.template.generic"
            ),
        ]

        for (context, expectedKey) in cases {
            let resource = AssistantNamingTemplates.nameResource(for: context, locale: Self.locale)
            #expect(resource.key == expectedKey)
        }
    }

    @Test("A top artist covering half the draft names it even with other artists present")
    func dominantArtistQualifiesWithoutBeingTheOnlyOne() {
        let context = PlaylistNamingContext(
            trackCount: 10,
            topArtists: [AssistantNameCount(name: "Muse", count: 5), AssistantNameCount(name: "Keane", count: 2)],
            distinctArtistCount: 4
        )

        let resource = AssistantNamingTemplates.nameResource(for: context, locale: Self.locale)
        #expect(resource.key == "assistant.naming.template.artist")
        let expected = AssistantStrings.nameArtist(artist: "Muse").resolved(in: Self.locale)
        #expect(AssistantNamingTemplates.fallbackName(for: context, locale: Self.locale).name == expected)
    }

    @Test("A minority top artist does not name the draft")
    func minorityArtistFallsThrough() {
        let context = PlaylistNamingContext(
            trackCount: 20,
            topArtists: [AssistantNameCount(name: "Muse", count: 3)],
            distinctArtistCount: 12,
            dominantDecade: 2000
        )

        #expect(
            AssistantNamingTemplates.nameResource(for: context, locale: Self.locale).key
                == "assistant.naming.template.decade"
        )
    }

    @Test("An unknown-name bucket never names a playlist")
    func unknownNameBucketsAreSkipped() {
        // `AssistantNameCount.name` is documented as "" when the value was unknown —
        // the untagged-genre bucket ranks like any other and must not win.
        let context = PlaylistNamingContext(
            trackCount: 30,
            topGenres: [AssistantNameCount(name: "  ", count: 20), AssistantNameCount(name: "Jazz", count: 10)]
        )

        let expected = AssistantStrings.nameGenre(genre: "Jazz").resolved(in: Self.locale)
        #expect(AssistantNamingTemplates.fallbackName(for: context, locale: Self.locale).name == expected)
    }

    @Test("A name is non-empty and never longer than the seam's limit")
    func nameIsNonEmptyAndBounded() {
        let long = String(repeating: "Progressive ", count: 30)
        let context = PlaylistNamingContext(
            trackCount: 4,
            topGenres: [AssistantNameCount(name: long, count: 4)]
        )

        let result = AssistantNamingTemplates.fallbackName(for: context, locale: Self.locale)
        #expect(!result.name.isEmpty)
        // Truncation is `PlaylistNamingResult.init`'s job, not the template's — the
        // contract holds by construction for the model tier and this one alike.
        #expect(result.name.count == PlaylistNamingResult.maxNameLength)
    }

    @Test("The description carries the draft's own counts, and an empty draft has none")
    func descriptionCarriesAggregateCounts() {
        let context = NamingFixtures.rockNineties()
        let expected = AssistantStrings
            .nameSummary(trackCount: 25, artistCount: 9)
            .resolved(in: Self.locale)

        #expect(AssistantNamingTemplates.fallbackName(for: context, locale: Self.locale).description == expected)
        #expect(expected.contains("25"))
        #expect(expected.contains("9"))
        #expect(
            AssistantNamingTemplates
                .fallbackName(for: PlaylistNamingContext(trackCount: 0), locale: Self.locale).description == nil
        )
    }

    @Test("Every mood has its own catalog key")
    func everyMoodHasAKey() {
        let keys = PlaylistMoodTag.allCases.map { AssistantStrings.moodWord($0).key }
        #expect(keys == [
            "assistant.naming.mood.calm",
            "assistant.naming.mood.energetic",
            "assistant.naming.mood.dark",
            "assistant.naming.mood.bright",
        ])
    }
}

// MARK: - Narration

@Suite("AssistantNarrationTemplates")
struct AssistantNarrationTemplateTests {
    private static let locale = NamingFixtures.locale

    /// A window digest with the numbers the narrative has to report back exactly.
    private static func digest(plays: Int, seconds: Double, peakHour: Int?) -> ListeningWindowDigest {
        var hours = [Int](repeating: 0, count: 24)
        if let peakHour { hours[peakHour] = plays }
        return ListeningWindowDigest(
            window: .last7Days,
            totalPlays: plays,
            totalListenedSeconds: seconds,
            topTracks: [
                ListeningTrackStat(
                    track: ListeningTrackIdentity(artistName: "Radiohead", title: "Idioteque", albumTitle: "Kid A"),
                    plays: 9
                ),
            ],
            topArtists: [ListeningNameStat(name: "Radiohead", plays: 21)],
            topGenres: [ListeningNameStat(name: "Rock", plays: 30)],
            hourHistogram: hours
        )
    }

    @Test("The narrative reports the window's own aggregate numbers")
    func narrativeReportsTheWindowsOwnNumbers() {
        let context = InsightNarrationContext.projecting(Self.digest(plays: 47, seconds: 11400, peakHour: 21))
        let result = AssistantNarrationTemplates.fallbackNarrative(for: context, locale: Self.locale)

        // The plan's acceptance: the interpolated play count IS the fixture's.
        #expect(context.totalPlays == 47)
        #expect(result.narrative.contains("47"))
        #expect(result.narrative.contains("Radiohead"))
        #expect(result.narrative.contains("21"))
        #expect(result.narrative.contains("Rock"))

        let sentences = AssistantNarrationTemplates.sentences(for: context, locale: Self.locale)
        #expect(sentences.count == 5)
        #expect(sentences[0] == AssistantStrings.narrativeWindow(.last7Days, plays: 47).resolved(in: Self.locale))
        #expect(
            sentences[1] == AssistantStrings
                .narrativeTopArtist(artist: "Radiohead", plays: 21)
                .resolved(in: Self.locale)
        )
        #expect(sentences[2] == AssistantStrings.narrativeTopGenre(genre: "Rock").resolved(in: Self.locale))
        #expect(sentences[3] == AssistantStrings.narrativePeakHour(hour: "21:00").resolved(in: Self.locale))
        #expect(sentences[4] == AssistantStrings.narrativeHours(hours: 3).resolved(in: Self.locale))
    }

    @Test("Each window has its own opening sentence rather than a substituted noun")
    func everyWindowHasItsOwnKey() {
        let keys = ListeningWindowKind.allCases.map { AssistantStrings.narrativeWindow($0, plays: 1).key }
        #expect(keys == [
            "assistant.narrative.template.window7Days",
            "assistant.narrative.template.window30Days",
            "assistant.narrative.template.window12Months",
            "assistant.narrative.template.windowAllTime",
        ])
    }

    @Test("An empty window says so, and says nothing else")
    func emptyWindowNarratesNothingPlayed() {
        let context = InsightNarrationContext(window: .last30Days)
        let sentences = AssistantNarrationTemplates.sentences(for: context, locale: Self.locale)

        #expect(sentences == [AssistantStrings.narrativeEmpty.resolved(in: Self.locale)])
    }

    @Test("Duration switches to minutes under an hour and is omitted under a minute")
    func durationPicksItsUnit() {
        let underAnHour = InsightNarrationContext.projecting(Self.digest(plays: 3, seconds: 900, peakHour: nil))
        let underAMinute = InsightNarrationContext.projecting(Self.digest(plays: 1, seconds: 30, peakHour: nil))

        let minutes = AssistantNarrationTemplates.sentences(for: underAnHour, locale: Self.locale)
        #expect(minutes.last == AssistantStrings.narrativeMinutes(minutes: 15).resolved(in: Self.locale))

        let none = AssistantNarrationTemplates.sentences(for: underAMinute, locale: Self.locale)
        #expect(none.last == AssistantStrings.narrativeTopGenre(genre: "Rock").resolved(in: Self.locale))
    }

    @Test("The peak hour renders as a zero-padded 24-hour token")
    func peakHourIsALocaleNeutralToken() {
        #expect(AssistantNarrationTemplates.hourToken(0) == "00:00")
        #expect(AssistantNarrationTemplates.hourToken(9) == "09:00")
        #expect(AssistantNarrationTemplates.hourToken(21) == "21:00")
    }
}
