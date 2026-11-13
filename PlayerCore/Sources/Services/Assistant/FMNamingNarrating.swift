// FMNamingNarrating — the FoundationModels tiers of ``PlaylistNaming`` and
// ``InsightNarrating``.
//
// Both are single-shot and NO TOOLS, exactly like ``FMSessionQueryResponder``: one
// `LanguageModelSession` per request, bounded instructions, one `@Generable` shape
// filled in. Nothing here reaches the library — the aggregates arrive already
// reduced (``PlaylistNamingContext`` / ``InsightNarrationContext``), which is the
// whole point of those two types.
//
// ── ERROR GROUND TRUTH ────────────────────────────────────────────────────────
//
// `LanguageModelError` DOES NOT EXIST in FoundationModels 1.5.2 (macOS 26.5 SDK).
// `LanguageModelSession.GenerationError` is the shipped, NON-deprecated surface,
// and ``AssistantFailure/mapping(_:)`` (FMAssistantBackend.swift) already groups
// its nine cases by what a caller can do about them. This file REUSES that mapper
// rather than inventing a second one; see that file's header for the command that
// re-enumerates the cases against a newer SDK.
//
// ── WHY THESE ARE `struct`s, NOT `actor`s WITH A BUSY LATCH ───────────────────
//
// ``FMAssistantBackend`` is an actor that REJECTS a second in-flight request,
// because a listener types query after query and wants to learn immediately that
// the second one was not accepted. Naming and narration are the opposite shape: a
// name is requested once per draft, a narrative once per window load, neither is
// interactive, and neither carries state across calls. Rejecting one with
// ``AssistantFailure/busy`` would hand the caller a template answer for no reason —
// strictly worse than letting the two calls overlap. So there is no shared mutable
// state here, and therefore nothing to isolate.
//
// Deliberately three separate conforming types across two files (parser here vs.
// FMAssistantBackend) so a naming refusal can never take the parser down with it.
//
// ── THE LAYERING (mirrors FMAssistantBackend.swift) ──────────────────────────
//
// | Symbol                                     | Availability | Touches FM? |
// |--------------------------------------------|--------------|-------------|
// | ``FMNameFields`` / ``FMNarrativeFields``    | floor        | no          |
// | `AssistantPrompts.swift` (the sent text)    | floor        | no          |
// | ``AssistantNameResponding`` / ...Narrative  | floor        | no          |
// | ``FMSessionNameResponder`` / ...Narrative   | 26+, gated   | YES         |
// | ``FMPlaylistNaming`` / ``FMInsightNarrator``| 26+, gated   | no (via ↑)  |
//
// Isolating the round-trip behind a floor-available protocol is what lets the
// prompt shape, the field projection and the caller's fallback all be tested with
// no model, no Apple Intelligence and no network.
import Foundation

// MARK: - Raw fields (floor-available)

/// The unvalidated name a language model produced.
public struct FMNameFields: Sendable, Equatable, Hashable {
    public var name: String
    public var description: String?

    public init(name: String, description: String? = nil) {
        self.name = name
        self.description = description
    }

    /// Projects onto the seam's result type.
    ///
    /// No length policy lives here: ``PlaylistNamingResult`` already trims, drops an
    /// empty description and TRUNCATES to ``PlaylistNamingResult/maxNameLength``, so
    /// the "non-empty, at most 60 characters" contract holds by construction rather
    /// than by a second check that could disagree with the first.
    public var result: PlaylistNamingResult {
        PlaylistNamingResult(name: name, description: description)
    }
}

/// The unvalidated narrative a language model produced.
public struct FMNarrativeFields: Sendable, Equatable, Hashable {
    /// Longest narrative carried out of the model tier.
    ///
    /// A stats card is a fixed-size surface and a model asked for "two or three
    /// sentences" occasionally writes ten. Clipping is the same trade
    /// ``PlaylistNamingResult`` makes for a name: a slightly cut narrative beats an
    /// unbounded one. The TEMPLATE tier needs no such cap — it is bounded by
    /// construction.
    public static let maxLength = 500

    public var narrative: String

    public init(narrative: String) {
        self.narrative = narrative
    }

    /// Projects onto the seam's result type, clipped to ``maxLength``.
    public var result: InsightNarrationResult {
        InsightNarrationResult(narrative: String(narrative.prefix(Self.maxLength)))
    }
}

// MARK: - The model round-trip seams (floor-available)

/// The single model exchange ``FMPlaylistNaming`` performs.
///
/// A conformer MUST throw ``AssistantFailure`` for model failures and MUST let
/// `CancellationError` propagate unchanged.
public protocol AssistantNameResponding: Sendable {
    func respondToNaming(instructions: String, prompt: String) async throws -> FMNameFields
}

/// The single model exchange ``FMInsightNarrator`` performs.
public protocol AssistantNarrativeResponding: Sendable {
    func respondToNarration(instructions: String, prompt: String) async throws -> FMNarrativeFields
}

#if canImport(FoundationModels)
    import FoundationModels

    // MARK: - The generable wire shapes (26+)

    /// The structured shape a naming session is asked to fill in.
    ///
    /// `description` is non-optional and may come back empty: a model fills a
    /// required field far more reliably than it decides to omit an optional one,
    /// and ``PlaylistNamingResult`` already treats an empty description as absent.
    @available(macOS 26, iOS 26, *)
    @Generable(description: "A name and a one-line description for a music playlist")
    public struct FMNameDTO {
        @Guide(description: "A short evocative playlist name, at most six words, no quotation marks.")
        public var name: String

        @Guide(description: "One short sentence describing the playlist. Empty if nothing to add.")
        public var description: String
    }

    @available(macOS 26, iOS 26, *)
    public extension FMNameDTO {
        /// Projects the generated shape onto the floor-available raw bag.
        var fields: FMNameFields {
            FMNameFields(name: name, description: description)
        }
    }

    /// The structured shape a narration session is asked to fill in.
    @available(macOS 26, iOS 26, *)
    @Generable(description: "A short prose summary of how someone has been listening to music")
    public struct FMNarrativeDTO {
        @Guide(description: "Two or three short sentences about the listening figures. No lists.")
        public var narrative: String
    }

    @available(macOS 26, iOS 26, *)
    public extension FMNarrativeDTO {
        /// Projects the generated shape onto the floor-available raw bag.
        var fields: FMNarrativeFields {
            FMNarrativeFields(narrative: narrative)
        }
    }

    // MARK: - The production responders (26+)

    /// Builds and runs one `LanguageModelSession` per naming request.
    ///
    /// Sampling is `.greedy` so the same draft always earns the same name — a
    /// playlist that renames itself on every refresh reads as a bug, not as variety.
    @available(macOS 26, iOS 26, *)
    public struct FMSessionNameResponder: AssistantNameResponding {
        public init() {}

        public func respondToNaming(instructions: String, prompt: String) async throws -> FMNameFields {
            do {
                let session = LanguageModelSession(model: .default, tools: []) { instructions }
                let response = try await session.respond(
                    to: prompt,
                    generating: FMNameDTO.self,
                    options: GenerationOptions(sampling: .greedy)
                )
                return response.content.fields
            } catch let error as LanguageModelSession.GenerationError {
                throw AssistantFailure.mapping(error)
            } catch let error as CancellationError {
                throw error
            } catch {
                throw AssistantFailure.mapping(unbridged: error)
            }
        }
    }

    /// Builds and runs one `LanguageModelSession` per narration request.
    @available(macOS 26, iOS 26, *)
    public struct FMSessionNarrativeResponder: AssistantNarrativeResponding {
        public init() {}

        public func respondToNarration(instructions: String, prompt: String) async throws -> FMNarrativeFields {
            do {
                let session = LanguageModelSession(model: .default, tools: []) { instructions }
                let response = try await session.respond(
                    to: prompt,
                    generating: FMNarrativeDTO.self,
                    options: GenerationOptions(sampling: .greedy)
                )
                return response.content.fields
            } catch let error as LanguageModelSession.GenerationError {
                throw AssistantFailure.mapping(error)
            } catch let error as CancellationError {
                throw error
            } catch {
                throw AssistantFailure.mapping(unbridged: error)
            }
        }
    }

    // MARK: - The seams (26+)

    /// The FoundationModels ``PlaylistNaming`` tier.
    ///
    /// Throws on any model failure; ``FallbackPlaylistNaming`` is what turns that
    /// into a template name, so this type never has to know a fallback exists.
    @available(macOS 26, iOS 26, *)
    public struct FMPlaylistNaming: PlaylistNaming {
        private let responder: any AssistantNameResponding

        /// The production initializer: a real session per request.
        public init() {
            self.init(responder: FMSessionNameResponder())
        }

        /// The injecting initializer used by tests.
        public init(responder: any AssistantNameResponding) {
            self.responder = responder
        }

        public func suggestName(
            for context: PlaylistNamingContext,
            locale: Locale
        ) async throws -> PlaylistNamingResult {
            let fields = try await responder.respondToNaming(
                instructions: AssistantNamingPrompt.instructionsText(locale: locale),
                prompt: AssistantNamingPrompt.promptText(for: context)
            )
            return fields.result
        }
    }

    /// The FoundationModels ``InsightNarrating`` tier. See ``FMPlaylistNaming``.
    @available(macOS 26, iOS 26, *)
    public struct FMInsightNarrator: InsightNarrating {
        private let responder: any AssistantNarrativeResponding

        public init() {
            self.init(responder: FMSessionNarrativeResponder())
        }

        public init(responder: any AssistantNarrativeResponding) {
            self.responder = responder
        }

        public func narrate(
            _ context: InsightNarrationContext,
            locale: Locale
        ) async throws -> InsightNarrationResult {
            let fields = try await responder.respondToNarration(
                instructions: AssistantNarrationPrompt.instructionsText(locale: locale),
                prompt: AssistantNarrationPrompt.promptText(for: context)
            )
            return fields.result
        }
    }
#endif
