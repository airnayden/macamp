// LibraryChatSession — the multi-turn, tool-calling on-device chat tier.
//
// A NEW, PARALLEL surface. The four-tier ladder in `AssistantViewModel+Ladder.swift`
// and its single-shot `submit` path are UNTOUCHED by this wave: that path answers
// "what did they ask for" and hands a `PlaylistQuerySpec` to the insight engine,
// which is a different question from "hold a conversation with me about my
// library". W4 composes this; nothing calls it from the ladder.
//
// ── ONE SESSION PER CONVERSATION, BECAUSE TOOLS ATTACH AT INIT ───────────────
//
// `LanguageModelSession(model:tools:instructions:)` is the ONLY place tools can be
// supplied — the SDK has no add/remove — and the session is stateful: every
// `respond` appends to `session.transcript` and the next turn is interpreted
// against all of it. So the session is a stored property with the lifetime of the
// conversation, where ``FMSessionQueryResponder`` builds a fresh one per request.
// That difference is the whole tier.
//
// The one time the stored session is REPLACED is condensation, which rebuilds it
// from a two-entry transcript. `tools` is re-supplied at that point, so the
// rebuilt session is as capable as the one it replaced.
//
// ── THE BUSY LATCH IS THE ASSISTANT'S, NOT A NEW POLICY ─────────────────────
//
// Identical in shape and rationale to ``FMAssistantBackend``'s: an `actor` whose
// `send` REJECTS a second caller rather than queueing it, with no suspension point
// between reading the latch and setting it, so actor isolation makes the check
// race-free by construction. `session.isResponding` is consulted alongside it
// because the SDK enforces the same rule and reporting ``AssistantFailure/busy``
// is friendlier than letting the framework throw.
//
// ── ERROR GROUND TRUTH (verified against the local SDK, not documentation) ────
//
// Enumerated against MacOSX26.5.sdk / FoundationModels 1.5.2 with:
//
//   IFACE="$(xcrun --sdk macosx --show-sdk-path)/System/Library/Frameworks/\
//   FoundationModels.framework/Versions/A/Modules/FoundationModels.swiftmodule/\
//   arm64e-apple-macos.swiftinterface"
//   grep -nE "contextSize|tokenCount|toolCallingMode|ContextOptions|DynamicProfile" "$IFACE"
//
// Four results that shape this file, all of which contradict something in
// circulation and must be re-checked before trusting a newer SDK:
//
//  1. `GenerationOptions` in this SDK has EXACTLY three members — `sampling`,
//     `temperature`, `maximumResponseTokens`. There is NO `toolCallingMode`, so
//     the documented `.required` infinite-loop foot-gun is not reachable from here
//     and there is nothing to opt out of. Tool calling is model-decided.
//  2. `SystemLanguageModel.contextSize` is `@available(macOS 26.0, *)` and
//     `@backDeployed(before: macOS 26.4)`, so it is readable at macOS 26.0 and
//     needs NO extra `#available` — it is a plain `Int`, neither `async` nor
//     `throws`, and the back-deployed body returns 4096.
//  3. `SystemLanguageModel.tokenCount(for:)` is `@available(macOS 26.4, *)` with
//     NO back-deployment, and returns `Int` — there is no `TokenUsage` type. It
//     therefore DOES need a nested `#available`, with the character estimate in
//     ``LibraryChatBudget`` as the floor.
//  4. `ContextOptions` and `DynamicProfile` do not appear in this SDK at all
//     (both are macOS 27 material). Nothing here may reference them.
//
// ``LanguageModelSession/ToolCallError`` DOES exist and wraps whatever a tool's
// `call` threw. These five wrappers never throw (see `LibraryChatTools.swift`), so
// it is off the live path — but it is unwrapped rather than swallowed, because a
// wrapper is not the only thing in a tool round-trip that can fail.
//
// This file imports Foundation only; it MUST NOT import AppKit, UIKit or
// `ViewModels` (PlayerCore portability + layering invariants).
import Foundation

#if canImport(FoundationModels)
    import FoundationModels

    /// One multi-turn conversation with the on-device model, over the library.
    @available(macOS 26, iOS 26, *)
    public actor LibraryChatSession {
        /// Longest listener message carried into a turn.
        ///
        /// Matches ``FMAssistantBackend/maxRequestLength`` for the same reason: the
        /// context recovery condenses the TRANSCRIPT, which cannot rescue an
        /// overflow caused by the incoming message itself, so the message needs its
        /// own bound. Truncated rather than refused — a clipped request still gets
        /// an answer.
        public nonisolated static let maxRequestLength = 600

        /// The wire names of the tools this session published, in publication
        /// order. `nonisolated` so a caller can assert the wiring without awaiting.
        ///
        /// Read off the wrappers this session actually attached rather than from
        /// ``LibraryToolbox/onDeviceToolNames``, because the set now depends on
        /// whether the composition root granted playback control. A session that
        /// reported a fixed list would claim capabilities it does not have.
        public nonisolated let toolNames: [String]

        private let tools: [any Tool]
        private let instructions: String
        private let contextSize: Int
        /// Where the five wrappers file each answer's result count, because the
        /// transcript has nowhere to carry one. See `LibraryChatToolCounts.swift`.
        private let counts: LibraryChatToolCounts
        private var session: LanguageModelSession
        private var isSending = false

        /// Builds a session, or explains why one cannot exist right now.
        ///
        /// The capability gate is ``AssistantAvailabilityProbe``'s, unchanged —
        /// `@available` is a compile/OS layer and is NEVER a capability proxy (see
        /// `AssistantAvailability.swift`'s header). A caller that reaches
        /// ``init(toolbox:locale:)`` directly has skipped the gate and will get a
        /// session whose first `respond` throws ``AssistantFailure/modelUnavailable``.
        public static func make(
            toolbox: LibraryToolbox,
            locale: Locale = .current,
            intelligenceEnabled: Bool
        ) -> Result<LibraryChatSession, AssistantChatUnavailable> {
            switch AssistantAvailabilityProbe.current(intelligenceEnabled: intelligenceEnabled) {
            case .available:
                .success(LibraryChatSession(toolbox: toolbox, locale: locale))
            case let .unavailable(reason):
                .failure(AssistantChatUnavailable(reason: reason))
            }
        }

        public init(toolbox: LibraryToolbox, locale: Locale = .current) {
            let counts = LibraryChatToolCounts()
            let tools = LibraryChatTools.onDevice(toolbox, counts: counts)
            let instructions = LibraryChatInstructions.text(
                locale: locale,
                profile: .onDevice,
                canControlPlayback: toolbox.context.playback != nil
            )
            self.counts = counts
            self.tools = tools
            self.instructions = instructions
            toolNames = tools.map(\.name)
            contextSize = SystemLanguageModel.default.contextSize
            session = LanguageModelSession(model: .default, tools: tools) { instructions }
        }

        /// Whether a turn is in flight. A ``send(_:)`` now would be rejected.
        public var isResponding: Bool {
            isSending || session.isResponding
        }

        /// The conversation so far, in floor-available form.
        ///
        /// Mirrored rather than exposed as a `Transcript` so a caller — a shell, a
        /// test, an evidence dump — does not have to be `@available(macOS 26, *)`
        /// to read it.
        public var transcript: [ChatTranscriptEntry] {
            LibraryChatTranscript.mirror(session.transcript)
        }

        /// Warms the model on a strong signal of intent — the listener starting to
        /// type, not the pane merely appearing.
        ///
        /// Cheap and idempotent, and deliberately NOT called from `init`: a session
        /// is constructed when the surface opens, which is far weaker evidence that
        /// a request is coming.
        public func prewarm() {
            session.prewarm()
        }

        /// Runs one turn, rejecting a second while the first is in flight.
        ///
        /// - Returns: the assistant's answer plus the ordered
        ///   ``AssistantChatEvent``s this turn produced.
        /// - Throws: ``AssistantFailure`` for any model failure; `CancellationError`
        ///   unchanged when the caller cancelled.
        public func send(_ text: String) async throws -> AssistantChatTurn {
            guard !isSending, !session.isResponding else { throw AssistantFailure.busy }
            isSending = true
            defer { isSending = false }

            let request = String(text.prefix(Self.maxRequestLength))
            await condenseIfNeeded()
            do {
                return try await attempt(request)
            } catch AssistantFailure.contextExceeded {
                // EXACTLY one retry, guaranteed by shape rather than by a counter —
                // the same construction `FMAssistantBackend.parse` uses. `attempt`
                // does not catch, so a second overflow reaches the caller.
                condense()
                return try await attempt(request)
            }
        }

        // MARK: Private

        private func attempt(_ request: String) async throws -> AssistantChatTurn {
            // Cleared per ATTEMPT, not per turn: the context retry runs `attempt`
            // a second time against a rebuilt session, and counts recorded by the
            // abandoned first pass describe answers that are no longer in the
            // transcript being mapped.
            await counts.reset()
            do {
                let response = try await session.respond(to: request)
                let recorded = await counts.snapshot()
                return AssistantChatEventMapping.turn(
                    from: LibraryChatTranscript.mirror(response.transcriptEntries),
                    fallbackText: response.content,
                    counts: recorded
                )
            } catch let error as LanguageModelSession.ToolCallError {
                throw Self.failure(unwrapping: error)
            } catch let error as LanguageModelSession.GenerationError {
                throw AssistantFailure.mapping(error)
            } catch let error as CancellationError {
                throw error
            } catch {
                throw AssistantFailure.mapping(unbridged: error)
            }
        }

        /// Unwraps a tool-call failure onto this module's enum.
        ///
        /// A `ToolCallError` is a WRAPPER: the interesting value is
        /// `underlyingError`, and reporting the wrapper as `.unknown` would discard
        /// a perfectly good `GenerationError` (a guardrail violation raised while
        /// the model was mid-round-trip, say) that a caller can act on.
        ///
        /// `public` for the same reason ``AssistantFailure/mapping(_:)`` is: it is
        /// part of this tier's error contract, and a test that pins it constructs
        /// Apple's OWN error values — which is what makes the mapping checked
        /// against the SDK rather than against a copy of it.
        public nonisolated static func failure(unwrapping error: LanguageModelSession.ToolCallError) -> any Error {
            if let generation = error.underlyingError as? LanguageModelSession.GenerationError {
                return AssistantFailure.mapping(generation)
            }
            if let cancellation = error.underlyingError as? CancellationError {
                return cancellation
            }
            return AssistantFailure.mapping(unbridged: error.underlyingError)
        }

        /// The proactive half of the context policy. See ``LibraryChatBudget``.
        private func condenseIfNeeded() async {
            let entries = Array(session.transcript)
            // Below three entries a condensation keeps everything it would drop, so
            // the measurement is not worth taking.
            guard entries.count > 2 else { return }
            guard await LibraryChatBudget.shouldCondense(
                usedTokens: usedTokens(entries),
                contextSize: contextSize
            ) else { return }
            condense()
        }

        /// Rebuilds the session from `[first, last]` and re-publishes the tools.
        ///
        /// `prewarm()` afterwards because the rebuilt session has a cold prefix that
        /// the very next `respond` would otherwise pay for.
        private func condense() {
            let entries = Array(session.transcript)
            let kept = LibraryChatBudget.condensationSelection(entryCount: entries.count).map { entries[$0] }
            guard kept.count < entries.count else { return }
            session = LanguageModelSession(model: .default, tools: tools, transcript: Transcript(entries: kept))
            session.prewarm()
        }

        /// The real token count where the SDK offers one, the estimate below it.
        ///
        /// `try?` rather than a thrown failure: an unmeasurable transcript must fall
        /// back to the estimate, not abort a turn the model could still answer.
        private func usedTokens(_ entries: [Transcript.Entry]) async -> Int {
            if #available(macOS 26.4, iOS 26.4, *) {
                if let measured = try? await SystemLanguageModel.default.tokenCount(for: entries) {
                    return measured
                }
            }
            return LibraryChatBudget.estimatedTokens(for: LibraryChatTranscript.mirror(entries))
        }
    }
#endif
