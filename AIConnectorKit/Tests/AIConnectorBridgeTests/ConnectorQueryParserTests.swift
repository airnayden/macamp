import AIConnectorBridge
import AIConnectorKit
import Foundation
import Services
import Testing

/// The connector tier of `NaturalLanguageQueryParsing`, end to end over a fake
/// provider: prompt build, transport call, decode, validation.
@Suite("ConnectorQueryParserBridgeTests")
struct ConnectorQueryParserTests {
    // MARK: The happy path

    @Test("A valid structured answer becomes a validated spec")
    func validAnswerBecomesAValidatedSpec() async throws {
        let parser = ConnectorConformerFixture.parser(
            .data(
                ConnectorConformerFixture.answer(
                    genres: "[\"rock\",\"Jazz\"]",
                    yearLowerBound: "1990",
                    yearUpperBound: "1999",
                    moodTags: "[\"energetic\"]",
                    recency: "\"rediscovery\"",
                    seedArtists: "[\"Radiohead\"]",
                    targetCount: "25"
                )
            )
        )

        let spec = try await parser.parse(text: "energetic 90s rock", locale: ConnectorConformerFixture.locale)

        // Rewritten to the LIBRARY's spelling — `GenreVocabularyMatcher`'s rule,
        // inherited rather than re-implemented here.
        #expect(spec.genres == ["Rock", "Jazz"])
        #expect(spec.yearRange?.lower == 1990)
        #expect(spec.yearRange?.upper == 1999)
        #expect(spec.moodTags == [.energetic])
        #expect(spec.recency == .rediscovery)
        #expect(spec.seedArtists == ["Radiohead"])
        #expect(spec.targetCount == 25)
        #expect(spec.lowConfidence == false)
    }

    // MARK: The validator route

    @Test("A hallucinated genre is dropped and the spec is marked low confidence")
    func hallucinatedGenresAreDroppedAndMarkLowConfidence() async throws {
        let parser = ConnectorConformerFixture.parser(
            .data(ConnectorConformerFixture.answer(genres: "[\"Vaporwave\",\"Rockk\"]"))
        )

        let spec = try await parser.parse(text: "vaporwave please", locale: ConnectorConformerFixture.locale)

        // DROP, never correct: neither name is in the library, so neither survives.
        #expect(spec.genres.isEmpty)
        #expect(spec.isUnconstrained)
        // The second-pass rebuild in `FMQuerySpecFields.resolve` — an all-hallucinated
        // answer must not read as a confident one.
        #expect(spec.lowConfidence)
    }

    @Test("A partly hallucinated list keeps exactly what the library has")
    func aPartlyHallucinatedListKeepsWhatTheLibraryHas() async throws {
        let parser = ConnectorConformerFixture.parser(
            .data(ConnectorConformerFixture.answer(genres: "[\"Vaporwave\",\"rock\"]"))
        )

        let spec = try await parser.parse(text: "rock or vaporwave", locale: ConnectorConformerFixture.locale)

        #expect(spec.genres == ["Rock"])
        #expect(spec.isUnconstrained == false)
        #expect(spec.lowConfidence == false)
    }

    // MARK: Failure routes — every one of these is a throw the ladder swallows

    @Test("A garbage answer throws rather than degrading to a default spec")
    func garbageAnswerThrowsMalformedResponse() async {
        for payload in ["Sure! Here is your playlist:", "[1,2,3]", "{ not json", ""] {
            let parser = ConnectorConformerFixture.parser(.text(payload))
            await #expect(throws: ConnectorFailure.malformedResponse) {
                _ = try await parser.parse(text: "anything", locale: ConnectorConformerFixture.locale)
            }
        }
    }

    @Test("Every connector failure propagates unchanged for the ladder to swallow")
    func connectorFailuresPropagateForTheLadderToSwallow() async {
        let failures: [ConnectorFailure] = [
            .unconfigured,
            .unreachable(underlying: ConnectorFailure.DiagnosticToken.connectionRefused),
            .timeout,
            .httpStatus(500, body: "upstream exploded", providerMessage: nil),
            .authExpired,
            .rateLimited(retryAfter: 30),
            .malformedResponse,
        ]
        for failure in failures {
            let parser = ConnectorConformerFixture.parser(.failure(failure))
            await #expect(throws: failure) {
                _ = try await parser.parse(text: "anything", locale: ConnectorConformerFixture.locale)
            }
        }
    }

    @Test("A cancelled call surfaces as cancellation, not as a failure")
    func aCancelledCallSurfacesAsCancellation() async {
        let parser = ConnectorConformerFixture.parser(.failure(.cancelled))
        // PlayerCore's tiers spell "the caller stopped caring" `CancellationError`, and
        // cannot name `ConnectorFailure` at all — so the translation lives here.
        await #expect(throws: CancellationError.self) {
            _ = try await parser.parse(text: "anything", locale: ConnectorConformerFixture.locale)
        }
    }

    @Test("An unchosen model is unconfigured, and costs the provider nothing")
    func anUnchosenModelIsUnconfiguredWithNoProviderCall() async {
        for selection in [nil, "", "   "] {
            let log = ConnectorCallLog()
            let parser = ConnectorConformerFixture.parser(
                .data(ConnectorConformerFixture.answer()),
                log: log,
                model: selection
            )
            await #expect(throws: ConnectorFailure.unconfigured) {
                _ = try await parser.parse(text: "anything", locale: ConnectorConformerFixture.locale)
            }
            let count = await log.callCount
            #expect(count == 0, "credentials resolve before the transport call, always")
        }
    }

    // MARK: The deadline covers the WHOLE body

    @Test("A slow provider is bounded by the conformer's own deadline")
    func theDeadlineBoundsASlowProvider() async {
        let parser = ConnectorConformerFixture.parser(
            .slow,
            deadlineSeconds: ConnectorConformerFixture.shortDeadline
        )
        let started = Date()
        await #expect(throws: ConnectorFailure.timeout) {
            _ = try await parser.parse(text: "anything", locale: ConnectorConformerFixture.locale)
        }
        #expect(Date().timeIntervalSince(started) < FakeProviderConnector.slowSeconds)
    }

    @Test("The deadline covers credential resolution, not just the HTTP call")
    func theDeadlineCoversCredentialResolutionNotJustTheHTTPCall() async {
        // The whole point of wrapping the ENTIRE body: a settings read, a Keychain
        // read on a locked keychain or an OAuth refresh is an await no transport
        // timeout can see, and an abandoned unbounded await keeps working for free.
        let log = ConnectorCallLog()
        let parser = ConnectorQueryParser(
            connector: FakeProviderConnector(.data(ConnectorConformerFixture.answer()), log: log),
            model: ConnectorConformerFixture.slowModel,
            contextProvider: { ConnectorPromptContext(requestText: "", genreNames: []) },
            deadlineSeconds: ConnectorConformerFixture.shortDeadline
        )
        let started = Date()
        await #expect(throws: ConnectorFailure.timeout) {
            _ = try await parser.parse(text: "anything", locale: ConnectorConformerFixture.locale)
        }
        #expect(Date().timeIntervalSince(started) < FakeProviderConnector.slowSeconds)
        let count = await log.callCount
        #expect(count == 0)
    }

    // MARK: What actually leaves

    @Test("The request carries the canonical schema and the budgeted prompt")
    func theRequestCarriesTheCanonicalSchemaAndTheBudgetedPrompt() async throws {
        let log = ConnectorCallLog()
        let parser = ConnectorConformerFixture.parser(
            .data(ConnectorConformerFixture.answer(genres: "[\"Rock\"]")),
            log: log
        )

        _ = try await parser.parse(text: "some rock", locale: ConnectorConformerFixture.locale)

        let call = try #require(await log.first)
        let canonical = try PlaylistQuerySchema.canonicalEncoder().encode(PlaylistQuerySchema.canonical)
        #expect(call.schema == canonical)
        #expect(call.model == "fake-model")
        #expect(call.instructions.contains("Rock, Jazz, Ambient"))
        #expect(call.instructions.contains("Radiohead"))
        #expect(call.instructions.contains(ConnectorConformerFixture.locale.identifier))
    }

    @Test("The listener's own text replaces whatever the context provider carried")
    func theListenersTextReplacesTheContextProvidersPlaceholder() async throws {
        let log = ConnectorCallLog()
        let parser = ConnectorConformerFixture.parser(
            .data(ConnectorConformerFixture.answer()),
            log: log
        )

        _ = try await parser.parse(text: "something upbeat", locale: ConnectorConformerFixture.locale)

        let call = try #require(await log.first)
        #expect(call.prompt == "something upbeat")
    }

    @Test("An oversized request is truncated by the shared payload budget")
    func anOversizedRequestIsTruncatedByTheSharedBudget() async throws {
        let log = ConnectorCallLog()
        let parser = ConnectorConformerFixture.parser(
            .data(ConnectorConformerFixture.answer()),
            log: log
        )
        let request = String(repeating: "a", count: ConnectorPayloadBudget.maxRequestCharacters + 400)

        _ = try await parser.parse(text: request, locale: ConnectorConformerFixture.locale)

        let call = try #require(await log.first)
        #expect(call.prompt.count == ConnectorPayloadBudget.maxRequestCharacters)
    }
}
