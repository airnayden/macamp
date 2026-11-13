// FMNamingNarratingTests — the naming/narration model tiers and the ladders that
// make them optional.
//
// Everything below runs with NO model, NO Apple Intelligence and NO network: the
// round-trip is injected through ``AssistantNameResponding`` /
// ``AssistantNarrativeResponding``, which is the whole reason those seams are
// floor-available. The one test that genuinely needs the framework builds Apple's
// OWN `GenerationError` values, so the refusal path is pinned against the SDK
// rather than against a copy of it.
import Foundation
import PlayerCoreTestSupport
@testable import Services
import Testing

// MARK: - Scripted round-trips

/// Returns a canned name, or throws a canned failure.
private struct ScriptedNameResponder: AssistantNameResponding {
    var fields = FMNameFields(name: "Neon Drive", description: "Late-night synths.")
    var failure: (any Error)?
    let observed = ObservedPrompt()

    func respondToNaming(instructions: String, prompt: String) async throws -> FMNameFields {
        observed.instructions = instructions
        observed.prompt = prompt
        if let failure { throw failure }
        return fields
    }
}

/// Returns a canned narrative, or throws a canned failure.
private struct ScriptedNarrativeResponder: AssistantNarrativeResponding {
    var fields = FMNarrativeFields(narrative: "You listened a lot.")
    var failure: (any Error)?
    let observed = ObservedPrompt()

    func respondToNarration(instructions: String, prompt: String) async throws -> FMNarrativeFields {
        observed.instructions = instructions
        observed.prompt = prompt
        if let failure { throw failure }
        return fields
    }
}

/// What the responder was handed, for prompt-shape assertions.
private final class ObservedPrompt: @unchecked Sendable {
    var instructions = ""
    var prompt = ""
}

// MARK: - Fixtures

private enum Fixtures {
    static let locale = Locale(identifier: "en")

    static func draft() -> PlaylistNamingContext {
        PlaylistNamingContext(
            trackCount: 25,
            topGenres: [AssistantNameCount(name: "Rock", count: 15)],
            topArtists: [AssistantNameCount(name: "Radiohead", count: 6)],
            distinctArtistCount: 9,
            dominantDecade: 1990
        )
    }

    static func window() -> InsightNarrationContext {
        InsightNarrationContext(
            window: .last7Days,
            totalPlays: 47,
            totalListenedSeconds: 11400,
            topArtists: [AssistantNameCount(name: "Radiohead", count: 21)],
            topGenres: [AssistantNameCount(name: "Rock", count: 30)],
            topTracks: [InsightNarrationTrack(title: "Idioteque", artistName: "Radiohead", plays: 9)],
            peakLocalHour: 21
        )
    }
}

// MARK: - Prompt shape (floor-available)

@Suite("AssistantPromptShape")
struct AssistantPromptShapeTests {
    @Test("A naming prompt carries aggregates only — never a track list")
    func namingPromptCarriesAggregatesOnly() {
        let prompt = AssistantNamingPrompt.promptText(for: Fixtures.draft())

        #expect(prompt.contains("Tracks: 25"))
        #expect(prompt.contains("Rock (15)"))
        #expect(prompt.contains("Decade: 1990s"))
        // The draft's own tracks are never named — that is the token-budget contract
        // ``PlaylistNamingContext`` exists to enforce, restated at the prompt.
        #expect(!prompt.contains("Idioteque"))
    }

    @Test("Ranked lists are capped and over-long names are dropped, not truncated")
    func promptIsBoundedByConstruction() {
        let long = String(repeating: "x", count: AssistantNamingPrompt.maxNameLength + 1)
        let many = (0 ..< 12).map { AssistantNameCount(name: "Genre\($0)", count: 12 - $0) }
        let context = PlaylistNamingContext(
            trackCount: 100,
            topGenres: [AssistantNameCount(name: long, count: 99)] + many
        )

        let line = try? #require(AssistantPromptFormatting.rankedLine(context.topGenres))
        // The over-long name is GONE rather than clipped: a clipped name would name
        // something the library does not hold (`AssistantLibraryContext`'s policy).
        #expect(line?.contains("x") == false)
        #expect(line?.components(separatedBy: ", ").count == AssistantNamingPrompt.maxRankedNames)
    }

    @Test("A narration prompt states the period, the numbers and the busiest hour")
    func narrationPromptStatesTheFigures() {
        let prompt = AssistantNarrationPrompt.promptText(for: Fixtures.window())

        #expect(prompt.contains("Period: the last 7 days"))
        #expect(prompt.contains("Plays: 47"))
        #expect(prompt.contains("Minutes listened: 190"))
        #expect(prompt.contains("Idioteque by Radiohead (9)"))
        #expect(prompt.contains("Busiest local hour: 21:00"))
    }

    @Test("Both instruction blocks name the requested output language")
    func instructionsNameTheLocale() {
        let locale = Locale(identifier: "bg")
        #expect(AssistantNamingPrompt.instructionsText(locale: locale).contains("bg"))
        #expect(AssistantNarrationPrompt.instructionsText(locale: locale).contains("bg"))
    }
}

// MARK: - Field projection (floor-available)

@Suite("AssistantFieldProjection")
struct AssistantFieldProjectionTests {
    @Test("A model name is trimmed and truncated by the seam's own result type")
    func nameIsBoundedByTheResultType() {
        let fields = FMNameFields(name: "  \(String(repeating: "A", count: 200))  ", description: "   ")

        #expect(fields.result.name.count == PlaylistNamingResult.maxNameLength)
        #expect(fields.result.description == nil)
    }

    @Test("A rambling narrative is clipped to the model tier's ceiling")
    func narrativeIsClipped() {
        let fields = FMNarrativeFields(narrative: String(repeating: "b", count: FMNarrativeFields.maxLength + 50))

        #expect(fields.result.narrative.count == FMNarrativeFields.maxLength)
    }
}

// MARK: - The ladders

@Suite("AssistantFallbackLadders")
struct AssistantFallbackLadderTests {
    private static let locale = Fixtures.locale

    @Test("With no model tier at all, naming and narration answer from templates")
    func nilPrimaryUsesTemplates() async throws {
        let context = Fixtures.draft()
        let name = try await FallbackPlaylistNaming(primary: nil).suggestName(for: context, locale: Self.locale)
        let expected = AssistantNamingTemplates.fallbackName(for: context, locale: Self.locale)
        #expect(name == expected)

        let window = Fixtures.window()
        let narrative = try await FallbackInsightNarrating(primary: nil).narrate(window, locale: Self.locale)
        #expect(narrative == AssistantNarrationTemplates.fallbackNarrative(for: window, locale: Self.locale))
    }

    @Test("A model answer wins when there is one")
    func modelAnswerWins() async throws {
        let namer = FakeAssistantNamer(result: PlaylistNamingResult(name: "Rainy Sunday"))
        let ladder = FallbackPlaylistNaming(primary: namer)

        let result = try await ladder.suggestName(for: Fixtures.draft(), locale: Self.locale)
        #expect(result.name == "Rainy Sunday")
        #expect(namer.recording.requests.count == 1)
    }

    @Test("Any failure becomes the template answer, silently")
    func failureFallsBackSilently() async throws {
        let namer = FakeAssistantNamer()
        namer.setFailure(AssistantFailure.refused)
        let narrator = FakeAssistantNarrator()
        narrator.setFailure(AssistantFailure.throttled)
        let context = Fixtures.draft()
        let window = Fixtures.window()

        let name = try await FallbackPlaylistNaming(primary: namer).suggestName(for: context, locale: Self.locale)
        #expect(name == AssistantNamingTemplates.fallbackName(for: context, locale: Self.locale))

        let narrative = try await FallbackInsightNarrating(primary: narrator).narrate(window, locale: Self.locale)
        #expect(narrative == AssistantNarrationTemplates.fallbackNarrative(for: window, locale: Self.locale))
    }

    @Test("Every mapped failure falls back — none of them escapes to the caller")
    func everyFailureFallsBack() async throws {
        let context = Fixtures.draft()
        let expected = AssistantNamingTemplates.fallbackName(for: context, locale: Self.locale)

        for failure in AssistantFailure.allCases {
            let namer = FakeAssistantNamer()
            namer.setFailure(failure)
            let result = try await FallbackPlaylistNaming(primary: namer).suggestName(
                for: context,
                locale: Self.locale
            )
            #expect(result == expected)
        }
    }

    @Test("An empty model answer is treated as no answer")
    func emptyModelAnswerFallsBack() async throws {
        let namer = FakeAssistantNamer(result: PlaylistNamingResult(name: "   "))
        let narrator = FakeAssistantNarrator(result: InsightNarrationResult(narrative: " \n "))
        let context = Fixtures.draft()
        let window = Fixtures.window()

        let name = try await FallbackPlaylistNaming(primary: namer).suggestName(for: context, locale: Self.locale)
        #expect(name == AssistantNamingTemplates.fallbackName(for: context, locale: Self.locale))

        let narrative = try await FallbackInsightNarrating(primary: narrator).narrate(window, locale: Self.locale)
        #expect(narrative == AssistantNarrationTemplates.fallbackNarrative(for: window, locale: Self.locale))
    }

    @Test("Cancellation propagates — a cancelled request is not a failed one")
    func cancellationIsNotAFailure() async {
        let namer = FakeAssistantNamer()
        namer.setFailure(CancellationError())

        await #expect(throws: CancellationError.self) {
            try await FallbackPlaylistNaming(primary: namer).suggestName(
                for: Fixtures.draft(),
                locale: Self.locale
            )
        }
    }
}

#if canImport(FoundationModels)
    import FoundationModels

    @Suite("FMNamingNarrating")
    struct FMNamingNarratingIslandTests {
        private static let locale = Fixtures.locale

        @Test("The FoundationModels island is compiled in, not silently skipped")
        func islandIsCompiledIn() {
            // Same technique as `FMAssistantBackendPolicyTests.islandIsCompiledIn`:
            // this file fails to COMPILE if the gated types stop existing.
            guard #available(macOS 26, iOS 26, *) else { return }
            #expect(FMSessionNameResponder() is any AssistantNameResponding)
            #expect(FMSessionNarrativeResponder() is any AssistantNarrativeResponding)
            #expect(FMNameDTO.generationSchema.debugDescription.contains("name"))
            #expect(FMNarrativeDTO.generationSchema.debugDescription.contains("narrative"))
        }

        @Test("The FM tier returns a non-empty name within the seam's limit")
        func fmTierProducesABoundedName() async throws {
            guard #available(macOS 26, iOS 26, *) else { return }
            let responder = ScriptedNameResponder(
                fields: FMNameFields(name: String(repeating: "Nightdrive ", count: 20), description: "  ")
            )
            let result = try await FMPlaylistNaming(responder: responder)
                .suggestName(for: Fixtures.draft(), locale: Self.locale)

            #expect(!result.name.isEmpty)
            #expect(result.name.count <= PlaylistNamingResult.maxNameLength)
            #expect(result.description == nil)
            // The prompt the tier actually sent is the floor-available one, so the
            // budget tested above is the budget shipped.
            #expect(responder.observed.prompt == AssistantNamingPrompt.promptText(for: Fixtures.draft()))
        }

        @Test("The FM narrator returns the model's prose, clipped")
        func fmTierReturnsNarrative() async throws {
            guard #available(macOS 26, iOS 26, *) else { return }
            let responder = ScriptedNarrativeResponder(
                fields: FMNarrativeFields(narrative: "A busy week of guitars.")
            )
            let result = try await FMInsightNarrator(responder: responder)
                .narrate(Fixtures.window(), locale: Self.locale)

            #expect(result.narrative == "A busy week of guitars.")
            #expect(responder.observed.instructions.contains("en"))
        }

        @Test("A real GenerationError refusal ends as the template name, with nothing surfaced")
        func refusalAppliesTheTemplateSilently() async throws {
            guard #available(macOS 26, iOS 26, *) else { return }
            // Apple's OWN error value, mapped by the SHARED mapper todo 14 shipped —
            // no second error-mapping scheme lives in this file.
            let refusal = LanguageModelSession.GenerationError.refusal(
                LanguageModelSession.GenerationError.Refusal(transcriptEntries: []),
                LanguageModelSession.GenerationError.Context(debugDescription: "test")
            )
            #expect(AssistantFailure.mapping(refusal) == .refused)

            let responder = ScriptedNameResponder(failure: AssistantFailure.mapping(refusal))
            let context = Fixtures.draft()
            let ladder = FallbackPlaylistNaming(primary: FMPlaylistNaming(responder: responder))

            let result = try await ladder.suggestName(for: context, locale: Self.locale)
            #expect(result == AssistantNamingTemplates.fallbackName(for: context, locale: Self.locale))
            #expect(
                AssistantNamingTemplates.nameResource(for: context, locale: Self.locale).key
                    == "assistant.naming.template.genreDecade"
            )
        }

        /// Runs against the REAL on-device model when this host has one.
        ///
        /// Returns early — reported as passing, never as failing — when Apple
        /// Intelligence is ineligible, disabled or still downloading, exactly like
        /// todo 14's tokenizer test. The value is confirmation on a provisioned dev
        /// Mac, not coverage that CI can rely on.
        @Test("A real on-device naming round-trip produces a usable name, when available")
        func realModelNamingRoundTrip() async throws {
            guard #available(macOS 26, iOS 26, *) else { return }
            guard AssistantAvailabilityProbe.current(intelligenceEnabled: true) == .available else { return }

            let result = try await FMPlaylistNaming().suggestName(for: Fixtures.draft(), locale: Self.locale)
            #expect(!result.name.isEmpty)
            #expect(result.name.count <= PlaylistNamingResult.maxNameLength)
        }
    }
#endif
