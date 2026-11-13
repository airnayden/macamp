import AIConnectorBridge
import AIConnectorKit
import Foundation
import Services
import Testing

/// The connector tier of `PlaylistNaming`.
@Suite("ConnectorNamingBridgeTests")
struct ConnectorNamerTests {
    private static let context = PlaylistNamingContext(
        trackCount: 24,
        topGenres: [AssistantNameCount(name: "Rock", count: 12)],
        topArtists: [AssistantNameCount(name: "Radiohead", count: 6)],
        distinctArtistCount: 9,
        dominantDecade: 1990,
        moodTags: [.energetic]
    )

    private static func namer(
        _ answer: FakeConnectorAnswer,
        log: ConnectorCallLog = ConnectorCallLog(),
        model: String? = "fake-model",
        deadlineSeconds: TimeInterval = 5
    ) -> ConnectorNamer {
        ConnectorNamer(
            connector: FakeProviderConnector(answer, log: log),
            model: { model },
            deadlineSeconds: deadlineSeconds
        )
    }

    // MARK: The shape

    @Test("The first line is the name and everything after it is the description")
    func theFirstLineIsTheNameAndTheRestIsTheDescription() async throws {
        let namer = Self.namer(.text("  Neon Rain\n\nNineties guitars for a late drive.\nAll killer.  "))

        let result = try await namer.suggestName(for: Self.context, locale: ConnectorConformerFixture.locale)

        #expect(result.name == "Neon Rain")
        #expect(result.description == "Nineties guitars for a late drive. All killer.")
    }

    @Test("A one-line answer carries no description rather than an empty one")
    func aNameOnlyAnswerHasNoDescription() async throws {
        let namer = Self.namer(.text("Neon Rain"))

        let result = try await namer.suggestName(for: Self.context, locale: ConnectorConformerFixture.locale)

        #expect(result.name == "Neon Rain")
        #expect(result.description == nil)
    }

    // MARK: The cap

    @Test("An overlong name is trimmed to the FoundationModels tier's own cap")
    func anOverlongNameIsTrimmedToTheFMCap() async throws {
        let namer = Self.namer(.text(String(repeating: "n", count: 200)))

        let result = try await namer.suggestName(for: Self.context, locale: ConnectorConformerFixture.locale)

        // `PlaylistNamingResult.maxNameLength` == 60, inherited through
        // `FMNameFields.result` — the exact expression `FMPlaylistNaming` returns.
        #expect(result.name.count == PlaylistNamingResult.maxNameLength)
        #expect(PlaylistNamingResult.maxNameLength == 60)
    }

    // MARK: Failure routes

    @Test("A blank answer is malformed rather than a playlist named nothing")
    func aBlankAnswerIsMalformedRatherThanAnEmptyName() async {
        for payload in ["", "   ", "\n\n  \n"] {
            let namer = Self.namer(.text(payload))
            await #expect(throws: ConnectorFailure.malformedResponse) {
                _ = try await namer.suggestName(for: Self.context, locale: ConnectorConformerFixture.locale)
            }
        }
    }

    @Test("Connector failures propagate, and a cancelled call reads as cancellation")
    func connectorFailuresPropagateAndCancellationIsCancellation() async {
        let failing = Self.namer(.failure(.httpStatus(503, body: "busy", providerMessage: nil)))
        await #expect(throws: ConnectorFailure.httpStatus(503, body: "busy", providerMessage: nil)) {
            _ = try await failing.suggestName(for: Self.context, locale: ConnectorConformerFixture.locale)
        }
        let cancelled = Self.namer(.failure(.cancelled))
        await #expect(throws: CancellationError.self) {
            _ = try await cancelled.suggestName(for: Self.context, locale: ConnectorConformerFixture.locale)
        }
    }

    @Test("An unchosen model is unconfigured, and costs the provider nothing")
    func anUnchosenModelIsUnconfiguredWithNoProviderCall() async {
        let log = ConnectorCallLog()
        let namer = Self.namer(.text("Neon Rain"), log: log, model: nil)
        await #expect(throws: ConnectorFailure.unconfigured) {
            _ = try await namer.suggestName(for: Self.context, locale: ConnectorConformerFixture.locale)
        }
        let count = await log.callCount
        #expect(count == 0)
    }

    @Test("The deadline bounds the whole body, credential resolution included")
    func theDeadlineBoundsTheWholeBody() async {
        let slow = Self.namer(.slow, deadlineSeconds: ConnectorConformerFixture.shortDeadline)
        await #expect(throws: ConnectorFailure.timeout) {
            _ = try await slow.suggestName(for: Self.context, locale: ConnectorConformerFixture.locale)
        }

        let log = ConnectorCallLog()
        let stalledCredential = ConnectorNamer(
            connector: FakeProviderConnector(.text("Neon Rain"), log: log),
            model: ConnectorConformerFixture.slowModel,
            deadlineSeconds: ConnectorConformerFixture.shortDeadline
        )
        await #expect(throws: ConnectorFailure.timeout) {
            _ = try await stalledCredential.suggestName(
                for: Self.context,
                locale: ConnectorConformerFixture.locale
            )
        }
        let count = await log.callCount
        #expect(count == 0)
    }

    // MARK: What actually leaves

    @Test("Both tiers send the same facts; only the response-shape line is added")
    func bothTiersSendTheSameFactsPlusTheResponseShapeLine() async throws {
        let log = ConnectorCallLog()
        let namer = Self.namer(.text("Neon Rain\nA drive."), log: log)

        _ = try await namer.suggestName(for: Self.context, locale: ConnectorConformerFixture.locale)

        let call = try #require(await log.first)
        let shared = AssistantNamingPrompt.instructionsText(locale: ConnectorConformerFixture.locale)
        #expect(call.instructions == shared + "\n" + ConnectorNamer.responseShapeInstruction)
        #expect(call.prompt == AssistantNamingPrompt.promptText(for: Self.context))
        #expect(call.model == "fake-model")
    }
}

/// The connector tier of `InsightNarrating`.
@Suite("ConnectorNarrationBridgeTests")
struct ConnectorNarratorTests {
    private static let context = InsightNarrationContext(
        window: .last30Days,
        totalPlays: 412,
        totalListenedSeconds: 61200,
        topArtists: [AssistantNameCount(name: "Radiohead", count: 44)],
        topGenres: [AssistantNameCount(name: "Rock", count: 120)],
        topTracks: [InsightNarrationTrack(title: "Idioteque", artistName: "Radiohead", plays: 12)],
        peakLocalHour: 21
    )

    private static func narrator(
        _ answer: FakeConnectorAnswer,
        log: ConnectorCallLog = ConnectorCallLog(),
        model: String? = "fake-model",
        deadlineSeconds: TimeInterval = 5
    ) -> ConnectorNarrator {
        ConnectorNarrator(
            connector: FakeProviderConnector(answer, log: log),
            model: { model },
            deadlineSeconds: deadlineSeconds
        )
    }

    @Test("A narrative is trimmed and returned verbatim")
    func aNarrativeIsTrimmedAndReturnedVerbatim() async throws {
        let narrator = Self.narrator(.text("  You listened a lot. Mostly Rock.  "))

        let result = try await narrator.narrate(Self.context, locale: ConnectorConformerFixture.locale)

        #expect(result.narrative == "You listened a lot. Mostly Rock.")
    }

    @Test("An overlong narrative is clipped to the FoundationModels tier's own cap")
    func anOverlongNarrativeIsClippedToTheFMCap() async throws {
        let narrator = Self.narrator(.text(String(repeating: "x", count: 900)))

        let result = try await narrator.narrate(Self.context, locale: ConnectorConformerFixture.locale)

        // `FMNarrativeFields.maxLength` == 500, inherited through
        // `FMNarrativeFields.result` — the exact expression `FMInsightNarrator` returns.
        #expect(result.narrative.count == FMNarrativeFields.maxLength)
        #expect(FMNarrativeFields.maxLength == 500)
    }

    @Test("A blank answer is malformed rather than a blank stats card")
    func aBlankAnswerIsMalformedRatherThanABlankCard() async {
        for payload in ["", "   ", "\n\n"] {
            let narrator = Self.narrator(.text(payload))
            await #expect(throws: ConnectorFailure.malformedResponse) {
                _ = try await narrator.narrate(Self.context, locale: ConnectorConformerFixture.locale)
            }
        }
    }

    @Test("Connector failures propagate, and a cancelled call reads as cancellation")
    func connectorFailuresPropagateAndCancellationIsCancellation() async {
        let failing = Self.narrator(.failure(.authExpired))
        await #expect(throws: ConnectorFailure.authExpired) {
            _ = try await failing.narrate(Self.context, locale: ConnectorConformerFixture.locale)
        }
        let cancelled = Self.narrator(.failure(.cancelled))
        await #expect(throws: CancellationError.self) {
            _ = try await cancelled.narrate(Self.context, locale: ConnectorConformerFixture.locale)
        }
    }

    @Test("An unchosen model is unconfigured, and costs the provider nothing")
    func anUnchosenModelIsUnconfiguredWithNoProviderCall() async {
        let log = ConnectorCallLog()
        let narrator = Self.narrator(.text("Anything."), log: log, model: "  ")
        await #expect(throws: ConnectorFailure.unconfigured) {
            _ = try await narrator.narrate(Self.context, locale: ConnectorConformerFixture.locale)
        }
        let count = await log.callCount
        #expect(count == 0)
    }

    @Test("The deadline bounds the whole body, credential resolution included")
    func theDeadlineBoundsTheWholeBody() async {
        let slow = Self.narrator(.slow, deadlineSeconds: ConnectorConformerFixture.shortDeadline)
        await #expect(throws: ConnectorFailure.timeout) {
            _ = try await slow.narrate(Self.context, locale: ConnectorConformerFixture.locale)
        }

        let log = ConnectorCallLog()
        let stalledCredential = ConnectorNarrator(
            connector: FakeProviderConnector(.text("Anything."), log: log),
            model: ConnectorConformerFixture.slowModel,
            deadlineSeconds: ConnectorConformerFixture.shortDeadline
        )
        await #expect(throws: ConnectorFailure.timeout) {
            _ = try await stalledCredential.narrate(Self.context, locale: ConnectorConformerFixture.locale)
        }
        let count = await log.callCount
        #expect(count == 0)
    }

    @Test("Both tiers send byte-identical narration text")
    func bothTiersSendByteIdenticalText() async throws {
        let log = ConnectorCallLog()
        let narrator = Self.narrator(.text("You listened a lot."), log: log)

        _ = try await narrator.narrate(Self.context, locale: ConnectorConformerFixture.locale)

        let call = try #require(await log.first)
        #expect(
            call.instructions
                == AssistantNarrationPrompt.instructionsText(locale: ConnectorConformerFixture.locale)
        )
        #expect(call.prompt == AssistantNarrationPrompt.promptText(for: Self.context))
    }
}
