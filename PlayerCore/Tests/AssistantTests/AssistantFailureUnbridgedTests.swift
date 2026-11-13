// AssistantFailureUnbridgedTests — the NSError the FM daemon does not bridge.
//
// Every error shape below is written with LITERAL domain strings rather than with
// `AssistantFailure`'s own constants, on purpose: the point is to pin the mapping
// against the RECORD (the live capture transcribed in `AssistantFailureUnbridged.swift`),
// not against a copy of the implementation. Renaming a constant must fail here.
//
// The floor suite needs no FoundationModels, no Apple Intelligence and no model
// assets — the recognition is over strings, so a CI runner exercises it fully. The
// second suite constructs Apple's OWN error values and is what makes the
// "no regression for a genuine GenerationError" claim an SDK measurement rather
// than an assertion about a copy of the SDK.
import Foundation
import Persistence
@testable import Services
import Testing

// MARK: - The recorded shape

/// The live capture, verbatim:
///
///     NSError domain=FoundationModels.LanguageModelSession.GenerationError Code=-1
///       NSMultipleUnderlyingErrorsKey=( com.apple.tokengeneration Code=10 )
private enum UnbridgedFixtures {
    static let generationDomain = "FoundationModels.LanguageModelSession.GenerationError"
    static let tokenDomain = "com.apple.tokengeneration"

    static func tokenGenerationFailure(code: Int = -1) -> NSError {
        NSError(
            domain: generationDomain,
            code: code,
            userInfo: [NSMultipleUnderlyingErrorsKey: [NSError(domain: tokenDomain, code: 10, userInfo: nil)]]
        )
    }

    /// The same constellation boxed with Foundation's single-cause key.
    static func singleCauseFailure() -> NSError {
        NSError(
            domain: generationDomain,
            code: -1,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: tokenDomain, code: 10, userInfo: nil)]
        )
    }
}

private struct OpaqueAssistantFailure: Error {}

@Suite("AssistantFailureUnbridged")
struct AssistantFailureUnbridgedTests {
    @Test("The recorded token-generation box surfaces a typed failure instead of .unknown")
    func recordedShapeMapsToATypedFailure() {
        let recorded = UnbridgedFixtures.tokenGenerationFailure()
        // The premise of the whole fix: this value carries the SDK's domain and
        // still is not the SDK's type, which is why the typed catch above the
        // terminal one misses it.
        #expect(AssistantFailure.mapping(unbridged: recorded) == .throttled)
        #expect(AssistantFailure.mapping(unbridged: recorded) != .unknown)
    }

    @Test("Both of Foundation's underlying-error spellings are recognised")
    func bothUnderlyingKeysAreRecognised() {
        #expect(AssistantFailure.mapping(unbridged: UnbridgedFixtures.singleCauseFailure()) == .throttled)
        #expect(AssistantFailure.mapping(unbridged: UnbridgedFixtures.tokenGenerationFailure()) == .throttled)
    }

    @Test("The sentinel code is not part of the predicate — a resilient enum may renumber")
    func theCodeIsNotPartOfThePredicate() {
        // `-1` is what was captured; `-2` stands in for the same box with a
        // different undocumented sentinel. Both are the same failure, so both map.
        #expect(AssistantFailure.mapping(unbridged: UnbridgedFixtures.tokenGenerationFailure(code: -1)) == .throttled)
        #expect(AssistantFailure.mapping(unbridged: UnbridgedFixtures.tokenGenerationFailure(code: -2)) == .throttled)
    }

    @Test("An unrelated error is still .unknown — the terminal catch keeps its old floor")
    func unrelatedErrorsAreStillUnknown() {
        let wrongOuterDomain = NSError(
            domain: "com.apple.somethingelse",
            code: -1,
            userInfo: [NSMultipleUnderlyingErrorsKey: [
                NSError(domain: UnbridgedFixtures.tokenDomain, code: 10, userInfo: nil),
            ]]
        )
        let wrongInnerDomain = NSError(
            domain: UnbridgedFixtures.generationDomain,
            code: -1,
            userInfo: [NSMultipleUnderlyingErrorsKey: [
                NSError(domain: "com.apple.someotherservice", code: 10, userInfo: nil),
            ]]
        )
        let noCauseAtAll = NSError(domain: UnbridgedFixtures.generationDomain, code: -1, userInfo: nil)

        #expect(AssistantFailure.mapping(unbridged: wrongOuterDomain) == .unknown)
        #expect(AssistantFailure.mapping(unbridged: wrongInnerDomain) == .unknown)
        #expect(AssistantFailure.mapping(unbridged: noCauseAtAll) == .unknown)
        #expect(AssistantFailure.mapping(unbridged: OpaqueAssistantFailure()) == .unknown)
        #expect(AssistantFailure.mapping(unbridged: URLError(.timedOut)) == .unknown)
        #expect(AssistantFailure.mapping(unbridged: CocoaError(.fileNoSuchFile)) == .unknown)
    }
}

#if canImport(FoundationModels)
    import FoundationModels

    @Suite("AssistantFailureUnbridgedSDK")
    struct AssistantFailureUnbridgedSDKTests {
        /// All nine shipped cases, paired with the mapping that shipped before this
        /// file existed. Duplicated from `FMAssistantBackendTests` on purpose: that
        /// suite pins `mapping(_:)`, this one pins that `mapping(unbridged:)` did not
        /// take anything away from it.
        @available(macOS 26, iOS 26, *)
        private static func genuineCases() -> [(LanguageModelSession.GenerationError, AssistantFailure)] {
            let context = LanguageModelSession.GenerationError.Context(debugDescription: "test")
            let refusal = LanguageModelSession.GenerationError.Refusal(transcriptEntries: [])
            return [
                (.exceededContextWindowSize(context), .contextExceeded),
                (.assetsUnavailable(context), .modelUnavailable),
                (.guardrailViolation(context), .refused),
                (.unsupportedGuide(context), .malformedExchange),
                (.unsupportedLanguageOrLocale(context), .unsupportedLocale),
                (.decodingFailure(context), .malformedExchange),
                (.rateLimited(context), .throttled),
                (.concurrentRequests(context), .throttled),
                (.refusal(refusal, context), .refused),
            ]
        }

        @Test("A genuine GenerationError still bridges, still maps as before, and is never hijacked")
        func genuineErrorsAreUnaffected() {
            guard #available(macOS 26, iOS 26, *) else { return }
            for (index, pair) in Self.genuineCases().enumerated() {
                let (error, expected) = pair
                // 1. It bridges, so the TYPED catch takes it and the terminal catch
                //    — the only caller of `mapping(unbridged:)` — is never reached.
                #expect((error as any Error) is LanguageModelSession.GenerationError)
                // 2. Its mapping is byte-identical to what shipped before.
                #expect(AssistantFailure.mapping(error) == expected)
                // 3. The bridged NSError's code IS the case index. This is the
                //    measurement that justifies keying the new predicate on the two
                //    DOMAINS rather than on the recorded `-1`: a resilient enum may
                //    renumber, and the captured sentinel is outside 0...8 anyway.
                let boxed = error as NSError
                #expect(boxed.domain == "FoundationModels.LanguageModelSession.GenerationError")
                #expect(boxed.code == index)
                // 4. Fed to the new path anyway, it does NOT become `.throttled`
                //    by accident — it carries no token-generation cause.
                if expected != .throttled {
                    #expect(AssistantFailure.mapping(unbridged: error) == .unknown)
                }
            }
            #expect(Self.genuineCases().count == 9)
        }

        @Test("A ToolCallError wrapping the recorded box surfaces typed, and an opaque one still does not")
        func theProductionUnwrapSiteSurfacesTyped() throws {
            guard #available(macOS 26, iOS 26, *) else { return }
            let toolbox = try ToolboxFixtures.makeToolbox(ToolboxFixtures.makeLibrary())
            let tool = LibraryChatGenresTool(toolbox: toolbox, counts: LibraryChatToolCounts())

            let boxed = LanguageModelSession.ToolCallError(
                tool: tool,
                underlyingError: UnbridgedFixtures.tokenGenerationFailure()
            )
            #expect(LibraryChatSession.failure(unwrapping: boxed) as? AssistantFailure == .throttled)

            // The pre-existing floor is untouched: anything unrecognised is `.unknown`.
            let opaque = LanguageModelSession.ToolCallError(tool: tool, underlyingError: OpaqueAssistantFailure())
            #expect(LibraryChatSession.failure(unwrapping: opaque) as? AssistantFailure == .unknown)
        }
    }
#endif
