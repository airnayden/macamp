// FMAssistantBackendTests — the FM tier's busy, retry and error-mapping policy.
//
// The whole point of `AssistantQueryResponding` is visible here: every test below
// injects a scripted responder, so "retried EXACTLY once" is a call-count
// MEASUREMENT rather than an assumption, and none of it needs Apple Intelligence
// to be eligible, enabled or downloaded.
//
// Two things genuinely require the real framework and are marked as such:
// `mapsEveryGenerationErrorCase` constructs Apple's own error values (so it pins
// the mapping against the SDK rather than against a copy of it), and
// `worstCasePromptFitsTheTokenBudget` measures with the real tokenizer.
import Foundation
import Persistence
import PlayerCoreTestSupport
import Services
import Testing

// MARK: - Caller-side fallback harness

/// Stands in for todo 17's tier ladder: try the FM backend, fall back to a
/// deterministic spec on ANY ``AssistantFailure``.
///
/// Deliberately NOT the real `AssistantViewModel` (which does not exist yet). It
/// exists to prove the CONTRACT the FM tier owes its caller: every failure it can
/// produce is catchable as one type and leaves a usable proposal behind.
private struct ParserLadder {
    let primary: any NaturalLanguageQueryParsing
    let deterministic: PlaylistQuerySpec

    /// The failure the ladder actually caught, for assertions.
    final class Observed: @unchecked Sendable {
        var failure: AssistantFailure?
    }

    func parse(text: String, locale: Locale, observed: Observed) async -> PlaylistQuerySpec {
        do {
            return try await primary.parse(text: text, locale: locale)
        } catch let failure as AssistantFailure {
            observed.failure = failure
            return deterministic
        } catch {
            observed.failure = .unknown
            return deterministic
        }
    }
}

#if canImport(FoundationModels)
    import FoundationModels

    @Suite("FMAssistantBackendPolicy")
    struct FMAssistantBackendPolicyTests {
        private static let library = ["Rock", "Jazz", "Pop", "Metal"]

        private static func context() -> AssistantLibraryContext {
            AssistantLibraryContext(genres: library, artists: ["Radiohead"], summary: "A small library.")
        }

        @Test("The FoundationModels island is compiled in, not silently skipped")
        func islandIsCompiledIn() {
            // Same technique as `AssistantAvailabilityProbeTests.islandIsCompiledIn`:
            // the VALUE is secondary, the point is that this file fails to COMPILE if
            // the gated types stop existing — which is what a silently-skipped island
            // looks like from the outside.
            guard #available(macOS 26, iOS 26, *) else { return }
            let responder = FMSessionQueryResponder()
            #expect(responder is any AssistantQueryResponding)
            #expect(FMQuerySpecDTO.generationSchema.debugDescription.contains("genres"))
        }

        @Test("Every GenerationError case maps to a typed failure, grouped by what a caller can do")
        func mapsEveryGenerationErrorCase() {
            guard #available(macOS 26, iOS 26, *) else { return }
            // Constructed from Apple's OWN types, so this pins the mapping against
            // the SDK. `LanguageModelError` does not exist in FoundationModels
            // 1.5.2 — `LanguageModelSession.GenerationError` is the shipped,
            // non-deprecated surface and these are all nine of its cases.
            let context = LanguageModelSession.GenerationError.Context(debugDescription: "test")
            let refusal = LanguageModelSession.GenerationError.Refusal(transcriptEntries: [])
            let expected: [(LanguageModelSession.GenerationError, AssistantFailure)] = [
                (.exceededContextWindowSize(context), .contextExceeded),
                (.rateLimited(context), .throttled),
                (.concurrentRequests(context), .throttled),
                (.guardrailViolation(context), .refused),
                (.refusal(refusal, context), .refused),
                (.assetsUnavailable(context), .modelUnavailable),
                (.unsupportedLanguageOrLocale(context), .unsupportedLocale),
                (.unsupportedGuide(context), .malformedExchange),
                (.decodingFailure(context), .malformedExchange),
            ]
            for (error, failure) in expected {
                #expect(AssistantFailure.mapping(error) == failure)
            }
            #expect(expected.count == 9)
        }

        @Test("A second concurrent request is rejected as busy rather than queued behind the first")
        func busyRejectsOverlappingRequests() async throws {
            guard #available(macOS 26, iOS 26, *) else { return }
            let responder = FakeAssistantQueryResponder(
                fallback: .fields(FMQuerySpecFields(moodTags: ["calm"]))
            )
            responder.hold()
            let backend = FMAssistantBackend(responder: responder) { Self.context() }

            async let first = backend.parse(text: "calm music", locale: .current)
            #expect(await responder.waitForRequests(atLeast: 1))

            let rejected = await #expect(throws: AssistantFailure.self) {
                try await backend.parse(text: "something else", locale: .current)
            }
            #expect(rejected == .busy)
            // The rejection happened BEFORE the model was reached — a busy backend
            // must not spend a round-trip it is going to throw away.
            #expect(responder.requestCount == 1)

            responder.release()
            let spec = try await first
            #expect(spec.moodTags == [.calm])
        }

        @Test("The busy latch clears, so a later request succeeds normally")
        func busyLatchClearsAfterEachRequest() async throws {
            guard #available(macOS 26, iOS 26, *) else { return }
            let responder = FakeAssistantQueryResponder(
                script: [.failure(.refused)],
                fallback: .fields(FMQuerySpecFields(moodTags: ["dark"]))
            )
            let backend = FMAssistantBackend(responder: responder) { Self.context() }

            // Even a FAILED request must release the latch, which is what the
            // `defer` in `parse` guarantees.
            await #expect(throws: AssistantFailure.refused) {
                try await backend.parse(text: "first", locale: .current)
            }
            let spec = try await backend.parse(text: "second", locale: .current)
            #expect(spec.moodTags == [.dark])
            #expect(responder.requestCount == 2)
        }

        @Test("A context overflow is retried exactly once, with a halved prompt")
        func contextOverflowRetriesExactlyOnce() async throws {
            guard #available(macOS 26, iOS 26, *) else { return }
            let responder = FakeAssistantQueryResponder(script: [
                .failure(.contextExceeded),
                .fields(FMQuerySpecFields(genres: ["Rock"])),
            ])
            let backend = FMAssistantBackend(responder: responder) { Self.context() }

            let spec = try await backend.parse(text: "rock", locale: .current)
            #expect(spec.genres == ["Rock"])

            let requests = responder.recording.requests
            #expect(requests.count == 2)
            // The retry re-sent a strictly smaller prompt — otherwise it would just
            // overflow again and the retry would be theatre.
            let retried = try #require(requests.last)
            let original = try #require(requests.first)
            #expect(retried.instructions.count < original.instructions.count)
            #expect(retried.prompt == original.prompt)
        }

        @Test("A second overflow is NOT retried — exactly one retry, never a loop")
        func contextOverflowRetriesOnlyOnce() async {
            guard #available(macOS 26, iOS 26, *) else { return }
            let responder = FakeAssistantQueryResponder(script: [
                .failure(.contextExceeded),
                .failure(.contextExceeded),
            ])
            let backend = FMAssistantBackend(responder: responder) { Self.context() }

            await #expect(throws: AssistantFailure.contextExceeded) {
                try await backend.parse(text: "rock", locale: .current)
            }
            // Two, not three: the retry calls the attempt directly and does not
            // catch, so "exactly once" holds by shape rather than by a counter.
            #expect(responder.requestCount == 2)
        }

        @Test("Failures other than a context overflow are never retried")
        func otherFailuresAreNotRetried() async {
            guard #available(macOS 26, iOS 26, *) else { return }
            for failure in AssistantFailure.allCases where failure != .contextExceeded {
                let responder = FakeAssistantQueryResponder(script: [.failure(failure)])
                let backend = FMAssistantBackend(responder: responder) { Self.context() }
                await #expect(throws: failure) {
                    try await backend.parse(text: "rock", locale: .current)
                }
                #expect(responder.requestCount == 1)
            }
        }

        @Test("The retry validates against the FULL genre list, not the halved prompt")
        func retryValidatesAgainstTheFullLibrary() async throws {
            guard #available(macOS 26, iOS 26, *) else { return }
            // Halving drops "Pop"/"Metal" from what the model is SHOWN. A model that
            // still names "Metal" must have it honoured — halving the prompt must not
            // narrow what counts as a real genre.
            let responder = FakeAssistantQueryResponder(script: [
                .failure(.contextExceeded),
                .fields(FMQuerySpecFields(genres: ["Metal"])),
            ])
            let backend = FMAssistantBackend(responder: responder) { Self.context() }

            let spec = try await backend.parse(text: "heavy stuff", locale: .current)
            #expect(spec.genres == ["Metal"])

            let retried = try #require(responder.recording.requests.last)
            #expect(!retried.instructions.contains("Metal"))
        }

        @Test("The instructions carry the library vocabulary and the caller's locale")
        func instructionsReachTheModel() async throws {
            guard #available(macOS 26, iOS 26, *) else { return }
            let responder = FakeAssistantQueryResponder()
            let backend = FMAssistantBackend(responder: responder) { Self.context() }
            _ = try await backend.parse(text: "anything", locale: Locale(identifier: "fr_FR"))

            let sent = try #require(responder.recording.requests.first)
            #expect(sent.prompt == "anything")
            #expect(sent.instructions.contains("fr_FR"))
            #expect(sent.instructions.contains("Rock, Jazz, Pop, Metal"))
        }
    }

    // MARK: - The caller's fallback contract

    @Suite("FMAssistantBackendFallback")
    struct FMAssistantBackendFallbackTests {
        @Test("Every failure the backend can produce leaves a caller with a valid proposal")
        func everyFailureFallsBackToADeterministicSpec() async {
            guard #available(macOS 26, iOS 26, *) else { return }
            let deterministic = PlaylistQuerySpec(targetCount: 25, lowConfidence: true)

            for failure in AssistantFailure.allCases {
                // `.contextExceeded` reaches a caller only after the single retry
                // has been spent, so it needs TWO scripted failures; every other
                // case reaches the caller on the first attempt. Asserting the count
                // makes this sweep pin the retry policy per case, not just the
                // fallback — a case that silently became retryable would fail here.
                let attempts = failure == .contextExceeded ? 2 : 1
                let responder = FakeAssistantQueryResponder(
                    script: Array(repeating: .failure(failure), count: attempts)
                )
                let backend = FMAssistantBackend(responder: responder) { AssistantLibraryContext() }
                let ladder = ParserLadder(primary: backend, deterministic: deterministic)
                let observed = ParserLadder.Observed()

                let spec = await ladder.parse(text: "anything", locale: .current, observed: observed)
                #expect(spec == deterministic)
                #expect(spec.lowConfidence)
                #expect(observed.failure == failure)
                #expect(responder.requestCount == attempts)
            }
            // Pins the sweep: a new failure case must be added to the enum AND
            // proven to fall back, not merely compile.
            #expect(AssistantFailure.allCases.count == 8)
        }

        @Test("An UNKNOWN failure — the @unknown default and terminal catch outcome — also falls back")
        func unknownFailureFallsBack() async {
            guard #available(macOS 26, iOS 26, *) else { return }
            // Neither a future `GenerationError` case nor an arbitrary framework
            // throw can be CONSTRUCTED here, so this injects what both of them
            // produce: `AssistantFailure.unknown`. That is the reachable half of
            // those two branches; the unreachable half is the SDK's own.
            let responder = FakeAssistantQueryResponder(script: [.failure(.unknown)])
            let backend = FMAssistantBackend(responder: responder) { AssistantLibraryContext() }
            let deterministic = PlaylistQuerySpec(lowConfidence: true)
            let ladder = ParserLadder(primary: backend, deterministic: deterministic)
            let observed = ParserLadder.Observed()

            let spec = await ladder.parse(text: "anything", locale: .current, observed: observed)
            #expect(spec == deterministic)
            #expect(observed.failure == .unknown)
        }
    }

#endif
