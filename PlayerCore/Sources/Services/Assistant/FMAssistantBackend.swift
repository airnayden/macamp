// FMAssistantBackend — the FoundationModels tier of the natural-language ladder.
//
// Single-shot, NO TOOLS. One `LanguageModelSession` is built per request, handed
// bounded instructions and the listener's text, and asked to fill in one
// ``FMQuerySpecDTO``. There is no tool loop and no multi-turn transcript: this tier
// answers "what did they ask for", and the existing insight engine and smart-playlist
// rule compiler EXECUTE the resulting ``PlaylistQuerySpec``. A tool would let the
// model reach the library directly, which is both a token-budget hazard and a second
// unreviewed path to the database.
//
// ── ERROR GROUND TRUTH (verified against the local SDK, not documentation) ─────
//
// `LanguageModelError` DOES NOT EXIST in FoundationModels 1.5.2 (macOS 26.5 SDK).
// The shipped error surface is `LanguageModelSession.GenerationError`, it carries
// NO deprecation attribute (the whole 1501-line `.swiftinterface` contains zero
// occurrences of "deprecated"), and its nine cases are the ones mapped below. The
// context case is spelled `exceededContextWindowSize` — not `contextSizeExceeded`.
// Enumerated with:
//
//   IFACE="$(xcrun --sdk macosx --show-sdk-path)/System/Library/Frameworks/\
//   FoundationModels.framework/Versions/A/Modules/FoundationModels.swiftmodule/\
//   arm64e-apple-macos.swiftinterface"
//   awk '/enum GenerationError/,/^  }/' "$IFACE" | grep '    case '
//
// Re-run that before trusting this mapping against a newer SDK.
//
// ── THE LAYERING (mirrors AssistantAvailability.swift) ────────────────────────
//
// | Symbol                        | Availability | Touches FM? | Purpose                    |
// |-------------------------------|--------------|-------------|----------------------------|
// | ``AssistantFailure``          | floor        | no          | the app's own failure enum |
// | ``AssistantLibraryContext``   | floor        | no          | bounded prompt context     |
// | ``AssistantQueryResponding``  | floor        | no          | the one model round-trip   |
// | ``FMSessionQueryResponder``   | 26+, gated   | YES         | builds + runs the session  |
// | ``FMAssistantBackend``        | 26+, gated   | no (via ↑)  | busy + retry policy        |
//
// Isolating the round-trip behind a protocol is what makes the retry-once and
// busy-rejection policies testable with no model, no Apple Intelligence and no
// network: a test injects a scripted responder and asserts the exact call count.
import Foundation
import Persistence

// MARK: - Failures

/// Why an assistant request could not be served.
///
/// This is the APP's enum, not Apple's, so it is floor-available and every switch
/// over it must be exhaustive with no `default:` — a new case has to break the
/// build. Callers are expected to fall back to the heuristic tier on ANY of these
/// rather than surface them; the distinctions exist for diagnostics and for the one
/// policy decision that depends on them (``contextExceeded`` is the only case a
/// smaller prompt can fix).
public enum AssistantFailure: Error, Sendable, Equatable, Hashable, CaseIterable {
    /// A request was already in flight. The backend serves one at a time and
    /// rejects rather than queues, so a caller learns immediately instead of
    /// waiting an unbounded time behind someone else's request.
    case busy
    /// `GenerationError.exceededContextWindowSize` — the prompt did not fit.
    /// Retried ONCE with a halved context before it reaches a caller.
    case contextExceeded
    /// `GenerationError.rateLimited` / `.concurrentRequests` — the system is busy.
    /// Transient, and not fixable by changing the prompt.
    case throttled
    /// `GenerationError.guardrailViolation` / `.refusal` — the model declined.
    case refused
    /// `GenerationError.assetsUnavailable` — model assets are not on the device.
    /// Normally pre-empted by ``AssistantAvailabilityProbe``; reaching it here
    /// means availability changed between the gate and the request.
    case modelUnavailable
    /// `GenerationError.unsupportedLanguageOrLocale` — the model does not serve
    /// the requested language. The heuristic tier is locale-aware and does.
    case unsupportedLocale
    /// `GenerationError.unsupportedGuide` / `.decodingFailure` — the request or
    /// the response did not match the schema this build asked for.
    case malformedExchange
    /// An error outside the mapped surface: a future `GenerationError` case
    /// (`@unknown default:`) or any non-`GenerationError` throw (the terminal
    /// `catch`). Both are real, reachable paths, not defensive padding.
    case unknown
}

// MARK: - Prompt context

/// The bounded library facts a request is allowed to be interpreted against.
///
/// Aggregates and caps ONLY. The caps are enforced in `init`, so the worst-case
/// prompt is bounded BY CONSTRUCTION rather than by a caller remembering to trim —
/// which is what lets the token-budget test assert a ceiling instead of sampling
/// one library's luck.
public struct AssistantLibraryContext: Sendable, Equatable, Hashable {
    /// Genres offered to the model. `TrackRepository.distinctGenres` on a real
    /// library can run to hundreds; the model only needs enough to recognise the
    /// request's vocabulary.
    public static let maxGenres = 40
    /// Artists offered to the model, for "more like ..." requests.
    public static let maxArtists = 20
    /// Longest genre or artist name carried into the prompt.
    ///
    /// A name longer than this is DROPPED, never truncated. Truncating would put a
    /// string in the vocabulary that does not exist in the library, and the same
    /// list is what ``FMQuerySpecFields/resolve(validGenres:)`` validates against —
    /// so a truncated name would validate and then match nothing. Dropping keeps
    /// every surviving name verbatim, which is what makes the count caps enough to
    /// bound the prompt: without a length cap a single corrupt 5000-character tag
    /// would blow the budget on its own.
    public static let maxNameLength = 40
    /// Characters of free-text summary. Roughly 100 tokens.
    public static let maxSummaryLength = 400

    /// The library's genres, capped at ``maxGenres``.
    public var genres: [String]
    /// The library's most-played artists, capped at ``maxArtists``.
    public var artists: [String]
    /// A short free-text digest, capped at ``maxSummaryLength``. May be empty.
    public var summary: String

    public init(genres: [String] = [], artists: [String] = [], summary: String = "") {
        self.genres = Self.bounded(genres, limit: Self.maxGenres)
        self.artists = Self.bounded(artists, limit: Self.maxArtists)
        self.summary = String(summary.prefix(Self.maxSummaryLength))
    }

    private static func bounded(_ names: [String], limit: Int) -> [String] {
        Array(names.filter { $0.count <= maxNameLength }.prefix(limit))
    }

    /// Half this context, used for the single retry after a context overflow.
    ///
    /// Halves every axis rather than dropping one: a prompt that overflowed may
    /// have done so through any of them, and halving all three needs no guess about
    /// which. Idempotently reaches an empty context, so the retry always terminates
    /// even though the policy only ever invokes it once.
    public func halved() -> AssistantLibraryContext {
        AssistantLibraryContext(
            genres: Array(genres.prefix(genres.count / 2)),
            artists: Array(artists.prefix(artists.count / 2)),
            summary: String(summary.prefix(summary.count / 2))
        )
    }

    /// The system instructions for one request.
    ///
    /// Pure and floor-available on purpose: the token-budget test measures the
    /// EXACT string production sends, without needing to build a session.
    ///
    /// - Parameter locale: The language the request is written in. Named for the
    ///   model rather than inferred from the text, matching
    ///   ``NaturalLanguageQueryParsing/parse(text:locale:)``.
    public func instructionsText(locale: Locale) -> String {
        var lines = [
            "You turn a music listener's request into playlist filters.",
            "Fill in every field of the requested structure. Use null or an empty list for anything the request does not mention — never guess.",
            "The request is written in \(locale.identifier).",
        ]
        if !genres.isEmpty {
            lines.append("Choose genres ONLY from this library's genres: \(genres.joined(separator: ", ")).")
            lines.append("If the request names a genre that is not in that list, leave genres empty.")
        }
        if !artists.isEmpty {
            lines.append("Artists in this library include: \(artists.joined(separator: ", ")).")
        }
        if !summary.isEmpty {
            lines.append(summary)
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - The model round-trip seam

/// The single model exchange ``FMAssistantBackend`` performs.
///
/// Floor-available because it trades only in floor types: the FoundationModels
/// session, the `@Generable` DTO and Apple's error enum all stay inside the one
/// gated conformer. A conformer MUST throw ``AssistantFailure`` for model failures,
/// and MUST let `CancellationError` propagate unchanged — a cancelled request is
/// not a failed one.
public protocol AssistantQueryResponding: Sendable {
    /// - Parameters:
    ///   - instructions: ``AssistantLibraryContext/instructionsText(locale:)``.
    ///   - prompt: The listener's request, verbatim.
    func respondToQuery(instructions: String, prompt: String) async throws -> FMQuerySpecFields
}

#if canImport(FoundationModels)
    import FoundationModels

    // MARK: - Error mapping (26+)

    @available(macOS 26, iOS 26, *)
    public extension AssistantFailure {
        /// Maps Apple's resilient error enum onto this one.
        ///
        /// `@unknown default:` is the sanctioned carve-out from this repo's
        /// no-`default:` rule: `GenerationError` is a RESILIENT SYSTEM enum that may
        /// gain a case in any OS update, so it must degrade rather than fail to
        /// compile. Cases are grouped by what a caller can DO about them, which is
        /// also what keeps the switch inside SwiftLint's complexity ceiling.
        static func mapping(_ error: LanguageModelSession.GenerationError) -> AssistantFailure {
            switch error {
            case .exceededContextWindowSize:
                .contextExceeded
            case .rateLimited, .concurrentRequests:
                .throttled
            case .guardrailViolation, .refusal:
                .refused
            case .assetsUnavailable:
                .modelUnavailable
            case .unsupportedLanguageOrLocale:
                .unsupportedLocale
            case .unsupportedGuide, .decodingFailure:
                .malformedExchange
            @unknown default:
                .unknown
            }
        }
    }

    // MARK: - The production responder (26+)

    /// Builds and runs one `LanguageModelSession` per request.
    ///
    /// The ONLY type in the app that constructs a session. `tools:` is explicitly
    /// empty — see the file header — and sampling is `.greedy` so a structured
    /// extraction of the same text against the same library is reproducible.
    @available(macOS 26, iOS 26, *)
    public struct FMSessionQueryResponder: AssistantQueryResponding {
        public init() {}

        public func respondToQuery(
            instructions: String,
            prompt: String
        ) async throws -> FMQuerySpecFields {
            do {
                let session = LanguageModelSession(model: .default, tools: []) { instructions }
                let response = try await session.respond(
                    to: prompt,
                    generating: FMQuerySpecDTO.self,
                    options: GenerationOptions(sampling: .greedy)
                )
                return response.content.fields
            } catch let error as LanguageModelSession.GenerationError {
                throw AssistantFailure.mapping(error)
            } catch let error as CancellationError {
                // A cancelled request is not a failed one, and must never be
                // reported as a model failure or trigger a fallback tier.
                throw error
            } catch {
                // The terminal catch. Reachable for anything outside the mapped
                // surface — an XPC drop, a `ToolCallError` from a future tools
                // build, a Foundation error from the framework's own plumbing, and
                // the one shape the daemon boxes without bridging (see
                // `AssistantFailureUnbridged.swift`). Everything it does not
                // recognise still lands on `.unknown`.
                throw AssistantFailure.mapping(unbridged: error)
            }
        }
    }

    // MARK: - The backend (26+)

    /// The FoundationModels ``NaturalLanguageQueryParsing`` tier.
    ///
    /// An `actor` for the same reason ``CoreMLSeparator`` is one: the expensive,
    /// memory-hungry work must not run concurrently with itself. Where the
    /// separator lets the actor queue callers, this backend REJECTS them — a
    /// listener typing a second request wants to know it was not accepted, not to
    /// wait an unbounded time behind the first.
    ///
    /// This type conforms to ``NaturalLanguageQueryParsing`` and NOTHING else. The
    /// ``PlaylistNaming`` and ``InsightNarrating`` FoundationModels conformers are
    /// separate types, so a naming failure can never take the parser down with it.
    @available(macOS 26, iOS 26, *)
    public actor FMAssistantBackend: NaturalLanguageQueryParsing {
        /// Longest listener request carried into a prompt.
        ///
        /// The retry halves the CONTEXT, which cannot rescue an overflow caused by
        /// the request itself, so the request needs its own bound or the worst-case
        /// prompt is unbounded. 600 characters is far beyond any real playlist
        /// request; anything longer is truncated rather than rejected, because a
        /// clipped request still parses while a refused one helps nobody.
        public nonisolated static let maxRequestLength = 600

        private let responder: any AssistantQueryResponding
        private let contextProvider: @Sendable () async -> AssistantLibraryContext
        private var isBusy = false

        /// The production initializer: a real session per request.
        ///
        /// - Parameter contextProvider: Supplies the bounded library facts. `async`
        ///   because a real one reads `TrackRepository.distinctGenres` off-main.
        public init(contextProvider: @escaping @Sendable () async -> AssistantLibraryContext) {
            self.init(responder: FMSessionQueryResponder(), contextProvider: contextProvider)
        }

        /// The injecting initializer used by tests.
        public init(
            responder: any AssistantQueryResponding,
            contextProvider: @escaping @Sendable () async -> AssistantLibraryContext
        ) {
            self.responder = responder
            self.contextProvider = contextProvider
        }

        /// Parses one request, rejecting a second while the first is in flight.
        ///
        /// The busy latch is race-free by construction: there is NO suspension
        /// point between reading `isBusy` and setting it, so the actor cannot
        /// interleave another call in between. Actor isolation alone would only
        /// SERIALIZE the second caller — the latch is what turns that into an
        /// immediate ``AssistantFailure/busy`` instead of an unbounded wait.
        ///
        /// - Throws: ``AssistantFailure`` for any model failure; `CancellationError`
        ///   unchanged when the caller cancelled.
        public func parse(text: String, locale: Locale) async throws -> PlaylistQuerySpec {
            guard !isBusy else { throw AssistantFailure.busy }
            isBusy = true
            defer { isBusy = false }

            let context = await contextProvider()
            let request = String(text.prefix(Self.maxRequestLength))
            do {
                return try await attempt(text: request, locale: locale, context: context, library: context.genres)
            } catch AssistantFailure.contextExceeded {
                // EXACTLY one retry, guaranteed by shape rather than by a counter:
                // the retry calls `attempt` directly, which does not catch, so a
                // second overflow propagates to the caller and the fallback tier.
                // Validation still uses the FULL genre list — halving the PROMPT
                // must not narrow what counts as a real genre.
                return try await attempt(
                    text: request,
                    locale: locale,
                    context: context.halved(),
                    library: context.genres
                )
            }
        }

        // MARK: Private

        private func attempt(
            text: String,
            locale: Locale,
            context: AssistantLibraryContext,
            library: [String]
        ) async throws -> PlaylistQuerySpec {
            let fields = try await responder.respondToQuery(
                instructions: context.instructionsText(locale: locale),
                prompt: text
            )
            return fields.resolve(validGenres: library)
        }
    }
#endif
