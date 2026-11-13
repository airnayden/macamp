import Foundation
import Services
import Testing

/// The half of todo 16's localization contract that CANNOT be asserted in
/// PlayerCore.
///
/// PlayerCore ships no String Catalog, so inside its test bundle every
/// `assistant.*` key resolves to its English `defaultValue` in every locale —
/// `AssistantTemplateTests` therefore asserts which resource was CHOSEN, by key.
/// This target is hosted by `macampMac`, whose bundle carries
/// `macOS/Sources/Localizable.xcstrings`, so it is the only place the other half is
/// observable: that the keys actually reached the catalog, and that a non-English
/// locale renders differently.
///
/// Note what is being proven, and what is not. The TEMPLATE is localized chrome;
/// the genre, decade, artist and counts pushed into it are library DATA and appear
/// verbatim in every language. That mixed construction is the whole design, so
/// every case below asserts both halves.
@Suite("AssistantLocalizationTests", .serialized)
struct AssistantLocalizationTests {
    private static let english = Locale(identifier: "en")
    private static let bulgarian = Locale(identifier: "bg")
    private static let german = Locale(identifier: "de")

    /// Where `needle` starts, as a character offset — enough to assert word ORDER
    /// without freezing a translator's wording into an equality check.
    private func offset(of needle: String, in haystack: String) throws -> Int {
        let range = try #require(haystack.range(of: needle))
        return haystack.distance(from: haystack.startIndex, to: range.lowerBound)
    }

    @Test("A sampled assistant.* key renders non-English in bg and de, and reorders its arguments")
    func templateReordersItsArgumentsPerLocale() throws {
        let resource = AssistantStrings.nameGenreDecade(genre: "Rock", decade: "1990")
        let englishText = resource.resolved(in: Self.english)
        let bulgarianText = resource.resolved(in: Self.bulgarian)
        let germanText = resource.resolved(in: Self.german)

        // The keys reached the catalog: a missing key would render the identical
        // English `defaultValue` in all three, exactly as it does in PlayerCore.
        #expect(bulgarianText != englishText)
        #expect(germanText != englishText)

        // The DATA survives translation untouched — a genre is never localized.
        for rendered in [englishText, bulgarianText, germanText] {
            #expect(rendered.contains("Rock"))
            #expect(rendered.contains("1990"))
        }

        // And the reordering a positional template exists to allow really happens:
        // English leads with the decade ("1990s Rock"), both translations lead with
        // the genre ("Rock от 1990-те" / "Rock der 1990er").
        #expect(try offset(of: "1990", in: englishText) < offset(of: "Rock", in: englishText))
        #expect(try offset(of: "Rock", in: bulgarianText) < offset(of: "1990", in: bulgarianText))
        #expect(try offset(of: "Rock", in: germanText) < offset(of: "1990", in: germanText))
    }

    @Test("Every naming template and mood word is translated for bg and de")
    func everyNamingKeyIsTranslated() {
        var resources = [
            AssistantStrings.nameGenreDecade(genre: "Rock", decade: "1990"),
            AssistantStrings.nameMoodGenre(mood: "Calm", genre: "Rock"),
            AssistantStrings.nameGenre(genre: "Rock"),
            AssistantStrings.nameArtist(artist: "Muse"),
            AssistantStrings.nameDecade(decade: "1970"),
            AssistantStrings.nameMood(mood: "Calm"),
            AssistantStrings.nameGeneric,
            AssistantStrings.nameSummary(trackCount: 25, artistCount: 9),
        ]
        resources.append(contentsOf: PlaylistMoodTag.allCases.map(AssistantStrings.moodWord))

        for resource in resources {
            let englishText = resource.resolved(in: Self.english)
            #expect(!englishText.isEmpty)
            #expect(resource.resolved(in: Self.bulgarian) != englishText, "bg still English for \(resource.key)")
            #expect(resource.resolved(in: Self.german) != englishText, "de still English for \(resource.key)")
        }
    }

    @Test("Every narrative template is translated for bg and de")
    func everyNarrativeKeyIsTranslated() {
        var resources = ListeningWindowKind.allCases.map { AssistantStrings.narrativeWindow($0, plays: 47) }
        resources.append(contentsOf: [
            AssistantStrings.narrativeEmpty,
            AssistantStrings.narrativeTopArtist(artist: "Radiohead", plays: 21),
            AssistantStrings.narrativeTopGenre(genre: "Rock"),
            AssistantStrings.narrativePeakHour(hour: "21:00"),
            AssistantStrings.narrativeHours(hours: 3),
            AssistantStrings.narrativeMinutes(minutes: 15),
        ])

        for resource in resources {
            let englishText = resource.resolved(in: Self.english)
            #expect(!englishText.isEmpty)
            #expect(resource.resolved(in: Self.bulgarian) != englishText, "bg still English for \(resource.key)")
            #expect(resource.resolved(in: Self.german) != englishText, "de still English for \(resource.key)")
        }
    }

    @Test("An assembled fallback name is localized end to end, and keeps the draft's data")
    func assembledNameIsLocalizedEndToEnd() {
        let context = PlaylistNamingContext(
            trackCount: 25,
            topGenres: [AssistantNameCount(name: "Rock", count: 15)],
            topArtists: [AssistantNameCount(name: "Radiohead", count: 6)],
            distinctArtistCount: 9,
            dominantDecade: 1990
        )
        let englishText = AssistantNamingTemplates.fallbackName(for: context, locale: Self.english)
        let bulgarianText = AssistantNamingTemplates.fallbackName(for: context, locale: Self.bulgarian)

        #expect(bulgarianText.name != englishText.name)
        #expect(bulgarianText.description != englishText.description)
        #expect(bulgarianText.name.contains("Rock"))
        #expect(bulgarianText.description?.contains("25") == true)
        #expect(bulgarianText.description?.contains("9") == true)
        // Still bounded — the seam's limit is a property of the result type, not of
        // the language it was written in.
        #expect(bulgarianText.name.count <= PlaylistNamingResult.maxNameLength)
    }

    @Test("An assembled narrative is localized end to end, and states the window's own numbers")
    func assembledNarrativeIsLocalizedEndToEnd() {
        let context = InsightNarrationContext(
            window: .last7Days,
            totalPlays: 47,
            totalListenedSeconds: 11400,
            topArtists: [AssistantNameCount(name: "Radiohead", count: 21)],
            topGenres: [AssistantNameCount(name: "Rock", count: 30)],
            peakLocalHour: 21
        )
        let englishText = AssistantNarrationTemplates.fallbackNarrative(for: context, locale: Self.english)
        let bulgarianText = AssistantNarrationTemplates.fallbackNarrative(for: context, locale: Self.bulgarian)
        let germanText = AssistantNarrationTemplates.fallbackNarrative(for: context, locale: Self.german)

        #expect(bulgarianText.narrative != englishText.narrative)
        #expect(germanText.narrative != englishText.narrative)
        for narrative in [englishText.narrative, bulgarianText.narrative, germanText.narrative] {
            // The aggregate numbers are DATA and must survive every translation.
            #expect(narrative.contains("47"))
            #expect(narrative.contains("21"))
            #expect(narrative.contains("Radiohead"))
            #expect(narrative.contains("Rock"))
        }
    }
}
