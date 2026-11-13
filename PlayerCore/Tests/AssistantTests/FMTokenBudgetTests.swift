// FMTokenBudgetTests — the token gate for the single-shot FM prompt.
//
// Split out of `FMAssistantBackendTests` because the budget is a different claim
// from the busy/retry policy, and because the combined file crossed SwiftLint's
// 400-line `file_length` ceiling — the same split the v15 author made for
// `StatsSchemaTests`.
//
// The gate is asserted TWICE, deliberately:
//
//   1. STRUCTURALLY, on any host with the SDK. `GenerationSchema` is `Codable`, so
//      the schema's size is measurable with no model at all, and
//      `AssistantLibraryContext.init` caps every other axis — so the worst case is
//      computable rather than sampled.
//   2. With the REAL tokenizer, only where the model is actually available.
//
// The second alone would be worthless here: `SystemLanguageModel.tokenCount(for:)`
// THROWS (`ModelManagerError 1026`) when Apple Intelligence is not enabled, which
// is the state of this dev host and of every CI runner. A gate that silently skips
// everywhere it runs is not a gate.
import Foundation
import Persistence
import PlayerCoreTestSupport
import Services
import Testing

#if canImport(FoundationModels)
    import FoundationModels

    @Suite("FMAssistantBackendTokenBudget")
    struct FMAssistantBackendTokenBudgetTests {
        /// The ceiling the worst-case prompt must stay under, leaving room inside
        /// `SystemLanguageModel.contextSize` (4096) for the model's own response.
        static let tokenCeiling = 3000

        /// A conservative characters-per-token divisor. Real English averages about
        /// four characters per token, so dividing by three OVER-estimates the token
        /// count — the structural gate is therefore a genuine upper bound, not an
        /// optimistic one.
        static let charactersPerToken = 3.0

        /// The worst case the backend can ever send: every cap saturated. It is a
        /// real worst case rather than one library's sample precisely because
        /// `AssistantLibraryContext.init` enforces the caps.
        /// Character counts of the three parts of a worst-case prompt.
        struct Budget {
            var instructions: Int
            var request: Int
            var schema: Int

            var total: Int {
                instructions + request + schema
            }
        }

        @available(macOS 26, iOS 26, *)
        static func worstCaseCharacters() throws -> Budget {
            let filler = String(repeating: "G", count: AssistantLibraryContext.maxNameLength)
            let context = AssistantLibraryContext(
                genres: (0 ..< 500).map { "\(filler)\($0)".suffix(AssistantLibraryContext.maxNameLength).description },
                artists: (0 ..< 500).map { "\(filler)\($0)".suffix(AssistantLibraryContext.maxNameLength).description },
                summary: String(repeating: "listening summary text ", count: 500)
            )
            let instructions = context.instructionsText(locale: Locale(identifier: "en_US"))
            let schema = try JSONEncoder().encode(FMQuerySpecDTO.generationSchema).count
            return Budget(
                instructions: instructions.count,
                request: FMAssistantBackend.maxRequestLength,
                schema: schema
            )
        }

        @Test("The worst-case prompt is bounded by construction and fits the token budget")
        func worstCasePromptIsStructurallyBounded() throws {
            guard #available(macOS 26, iOS 26, *) else { return }
            // Runs on ANY host with the SDK: `GenerationSchema` is `Codable`, so the
            // schema's size is measurable without Apple Intelligence being enabled.
            // That matters because the real tokenizer THROWS when the model is
            // unavailable, which would otherwise leave this budget unverified on
            // every machine that has not opted in.
            let budget = try Self.worstCaseCharacters()
            let estimate = Int((Double(budget.total) / Self.charactersPerToken).rounded(.up))

            #expect(
                estimate < Self.tokenCeiling,
                """
                worst-case characters: instructions=\(budget.instructions) \
                request=\(budget.request) schema=\(budget.schema) total=\(budget.total) \
                estimatedTokens=\(estimate) ceiling=\(Self.tokenCeiling)
                """
            )
        }

        @Test("The real tokenizer confirms the structural bound")
        func realTokenizerConfirmsTheBudget() async throws {
            // `tokenCount(for:)` landed in macOS 26.4, later than the island's own
            // 26.0 floor, AND throws outright when the model is unavailable — so it
            // needs both guards. The structural test above is what holds the line on
            // a machine that has not enabled Apple Intelligence.
            guard #available(macOS 26.4, iOS 26.4, *) else { return }
            let model = SystemLanguageModel.default
            guard model.isAvailable else { return }

            let filler = String(repeating: "G", count: AssistantLibraryContext.maxNameLength)
            let context = AssistantLibraryContext(
                genres: (0 ..< 500).map { "\(filler)\($0)".suffix(AssistantLibraryContext.maxNameLength).description },
                artists: (0 ..< 500).map { "\(filler)\($0)".suffix(AssistantLibraryContext.maxNameLength).description },
                summary: String(repeating: "listening summary text ", count: 500)
            )
            let instructions = context.instructionsText(locale: Locale(identifier: "en_US"))
            let request = String(repeating: "upbeat 90s rock ", count: 100)
                .prefix(FMAssistantBackend.maxRequestLength).description

            let instructionTokens = try await model.tokenCount(for: Instructions(instructions))
            let requestTokens = try await model.tokenCount(for: request)
            let schemaTokens = try await model.tokenCount(for: FMQuerySpecDTO.generationSchema)
            let total = instructionTokens + requestTokens + schemaTokens

            #expect(
                total < Self.tokenCeiling,
                """
                measured tokens: instructions=\(instructionTokens) request=\(requestTokens) \
                schema=\(schemaTokens) total=\(total) ceiling=\(Self.tokenCeiling) \
                contextSize=\(model.contextSize)
                """
            )
            #expect(total < model.contextSize)
        }

        @Test("A live round-trip through the real model", .enabled(if: LiveAssistantQA.isEnabled))
        func liveRoundTripProducesAServableSpec() async throws {
            guard #available(macOS 26, iOS 26, *) else { return }
            // OPT-IN ONLY: needs Apple Intelligence eligible AND enabled, takes
            // seconds, and is nondeterministic. Run with
            // `MACAMP_FM_LIVE=1 swift test --filter FMAssistantBackendTokenBudget`.
            let library = ["Rock", "Jazz", "Pop", "Metal", "Electronic", "Hip-Hop"]
            let backend = FMAssistantBackend {
                AssistantLibraryContext(genres: library, artists: ["Nirvana", "Pearl Jam"])
            }
            let spec = try await backend.parse(text: "upbeat 90s rock", locale: Locale(identifier: "en_US"))

            #expect(spec.genres == ["Rock"])
            #expect(spec.yearRange?.lower == 1990)
            #expect(spec.moodTags.contains(.energetic))
            #expect(!spec.lowConfidence)
        }
    }

    /// Gate for the opt-in live round-trip.
    enum LiveAssistantQA {
        static var isEnabled: Bool {
            ProcessInfo.processInfo.environment["MACAMP_FM_LIVE"] != nil
                && AssistantAvailabilityProbe.current(intelligenceEnabled: true).isAvailable
        }
    }
#endif
