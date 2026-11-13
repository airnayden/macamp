// ConnectorPromptBuilder — the one place a request's size is decided.
//
// Everything the FoundationModels tier sends stays on the device, so its context
// caps (``AssistantLibraryContext``: 40 genres, 20 artists) are a TOKEN budget. A
// connector sends the same material to somebody else's server, which makes the caps
// a PRIVACY PROMISE — the consent sheet quotes these exact numbers before the first
// request leaves, so they must have one definition and one enforcement point.
// ``ConnectorPayloadBudget`` is that definition; this builder is that enforcement.
//
// The seam that feeds it is uncapped: `TrackRepository.distinctGenres` returns every
// genre in the library (`AppEnvironment+AI.swift:146,173-175`), which on a real
// library is hundreds and on a pathological one is thousands. Nothing upstream will
// bound it, so this type must.
//
// ── TRUNCATE, NEVER REFUSE ───────────────────────────────────────────────────
//
// There is deliberately NO `PromptBudgetError`. An over-budget context is a
// perfectly serviceable request attached to an oversized library — refusing it would
// punish the listener for owning music. Every path here returns a ``ConnectorPrompt``;
// what was dropped is reported in ``ConnectorPromptTruncation`` for diagnostics, never
// thrown. The only genuine failure in this file's neighbourhood is a provider ANSWER
// that is not JSON, and that is ``PlaylistQuerySchema/decodeFields(from:)``'s
// `ConnectorFailure.malformedResponse` — a different direction and a different concern.
//
// ── THE ORDERING RULE, IN ONE SENTENCE ───────────────────────────────────────
//
// Entries are kept MOST FREQUENT FIRST, ties broken by the caller's own order, and
// the surplus is dropped from the tail. Callers with no frequency signal (the
// `distinctGenres` seam has none) pass equal counts, which collapses the rule to
// "keep the first N in the order given" — still total, still deterministic, and the
// same 64 genres on every run for the same library.
import AIConnectorKit
import Foundation
import Services

// MARK: - The numbers

/// The payload caps a connector may never exceed, and the ONLY place they are
/// written down.
///
/// The consent sheet, the preferences copy and this builder all read from here.
/// A literal `64` or `600` anywhere else is a bug: two copies of a privacy promise
/// drift, and the copy the user read is the one that matters.
public enum ConnectorPayloadBudget {
    /// Longest listener request that may leave the device.
    ///
    /// Mirrors `FMAssistantBackend.maxRequestLength`, which cannot be referenced
    /// directly — it lives behind `@available(macOS 26, iOS 26, *)` inside a
    /// `canImport(FoundationModels)` island, and this target must compile on
    /// macOS 14. The number is the contract; the citation is the reason it is 600.
    public static let maxRequestCharacters = 600

    /// Genres offered to the provider as the answer vocabulary.
    ///
    /// Larger than the on-device tier's 40 because a remote model has a far wider
    /// context window and a truncated vocabulary costs recall — but bounded, because
    /// the whole list is disclosed in the consent sheet as "what may leave".
    public static let maxGenres = 64

    /// Most-played artists offered as "more like ..." hints.
    public static let maxArtists = 50

    /// Ceiling on one serialized request body.
    ///
    /// A backstop, not the primary control: the count caps plus ``maxNameLength``
    /// already bound the worst case well under this. It exists so a future schema or
    /// instruction change cannot quietly grow the payload past what was disclosed.
    public static let maxSerializedBodyBytes = 16 * 1024

    /// Longest genre or artist name carried into a prompt. A longer one is DROPPED,
    /// never truncated.
    ///
    /// Deliberately the SAME constant the on-device tier enforces, not a copy of its
    /// value: truncating a name would put a string in the vocabulary that does not
    /// exist in the library, and `GenreVocabularyMatcher` validates the answer
    /// against the real library — so a truncated name would validate and then match
    /// nothing. Dropping keeps every surviving name verbatim, which is what makes the
    /// count caps sufficient to bound the payload.
    public static let maxNameLength = AssistantLibraryContext.maxNameLength

    /// Characters of the free-text taste summary. Same cap, same reason.
    public static let maxSummaryCharacters = AssistantLibraryContext.maxSummaryLength

    /// Bytes a provider's own envelope adds around instructions, prompt and schema:
    /// the JSON keys, the model id, and per-provider extras (`max_tokens`,
    /// `tool_choice`, `stream: false`).
    ///
    /// Deliberately generous. The budget is a promise about what leaves the device,
    /// so an estimate that reads LOW is the one failure mode that matters.
    public static let envelopeOverheadBytes = 512
}

// MARK: - Input

/// The library facts and listener text one connector request is built from.
///
/// Uncapped by construction, unlike ``AssistantLibraryContext``: the caps belong to
/// ``ConnectorPromptBuilder`` so the amount that was dropped can be REPORTED rather
/// than silently absorbed by an initializer.
public struct ConnectorPromptContext: Sendable, Equatable {
    /// The listener's request, verbatim and unbounded.
    public var requestText: String
    /// The library's genres with whatever frequency signal the caller has.
    public var genres: [AssistantNameCount]
    /// The profile's most-played artists, likewise.
    public var artists: [AssistantNameCount]
    /// A short factual sentence about what this listener plays. May be empty.
    public var summary: String

    public init(
        requestText: String,
        genres: [AssistantNameCount] = [],
        artists: [AssistantNameCount] = [],
        summary: String = ""
    ) {
        self.requestText = requestText
        self.genres = genres
        self.artists = artists
        self.summary = summary
    }

    /// A context from bare name lists — the shape the `distinctGenres` seam returns.
    ///
    /// Every entry gets count `0`, so the ranking degenerates to the caller's own
    /// order. That is the correct reading: a caller with no frequency signal has
    /// already expressed its preference by the order it fetched them in, and SQL
    /// ordering is deterministic, so the same library yields the same selection.
    public init(
        requestText: String,
        genreNames: [String],
        artistNames: [String] = [],
        summary: String = ""
    ) {
        self.init(
            requestText: requestText,
            genres: genreNames.map { AssistantNameCount(name: $0, count: 0) },
            artists: artistNames.map { AssistantNameCount(name: $0, count: 0) },
            summary: summary
        )
    }

    /// A context from the on-device tier's already-bounded context.
    ///
    /// Its caps (40/20) are tighter than this budget's (64/50), so nothing here can
    /// truncate — which is the point: routing the SAME context through either tier
    /// sends the same facts, and only the transport differs.
    public init(requestText: String, library: AssistantLibraryContext) {
        self.init(
            requestText: requestText,
            genreNames: library.genres,
            artistNames: library.artists,
            summary: library.summary
        )
    }
}

// MARK: - Output

/// What the budget removed from one request. Diagnostics only — never an error.
public struct ConnectorPromptTruncation: Sendable, Equatable {
    /// Characters cut from the end of the listener's request.
    public var droppedRequestCharacters: Int
    /// Genres that did not reach the prompt: over the count cap, over
    /// ``ConnectorPayloadBudget/maxNameLength``, or blank.
    public var droppedGenres: Int
    /// Artists that did not reach the prompt, for the same three reasons.
    public var droppedArtists: Int
    /// Characters cut from the taste summary, including the whole of it when the
    /// byte backstop had to drop it.
    public var droppedSummaryCharacters: Int
    /// `true` when the body is still over ``ConnectorPayloadBudget/maxSerializedBodyBytes``
    /// with every droppable part already gone.
    ///
    /// Unreachable with the shipped schema — the irreducible floor is the schema plus
    /// four fixed instruction lines plus a 600-character request. It is surfaced
    /// rather than asserted so a future schema that DOES blow the budget is visible
    /// in a log instead of silently over-sending.
    public var isOverBudget: Bool

    public init(
        droppedRequestCharacters: Int = 0,
        droppedGenres: Int = 0,
        droppedArtists: Int = 0,
        droppedSummaryCharacters: Int = 0,
        isOverBudget: Bool = false
    ) {
        self.droppedRequestCharacters = droppedRequestCharacters
        self.droppedGenres = droppedGenres
        self.droppedArtists = droppedArtists
        self.droppedSummaryCharacters = droppedSummaryCharacters
        self.isOverBudget = isOverBudget
    }

    /// `true` when anything at all was removed.
    public var didTruncate: Bool {
        droppedRequestCharacters > 0
            || droppedGenres > 0
            || droppedArtists > 0
            || droppedSummaryCharacters > 0
    }
}

/// One budgeted request, ready for ``AIProviderConnector/structuredCompletion(schema:instructions:prompt:model:)``.
public struct ConnectorPrompt: Sendable, Equatable {
    /// The system instructions, carrying the bounded vocabulary.
    public var instructions: String
    /// The listener's request, capped at ``ConnectorPayloadBudget/maxRequestCharacters``.
    public var prompt: String
    /// The genres that survived, in the order they appear in ``instructions``.
    public var genres: [String]
    /// The artists that survived, likewise.
    public var artists: [String]
    /// The measured size of the body this prompt will produce.
    public var serializedByteCount: Int
    /// What the budget removed.
    public var truncation: ConnectorPromptTruncation
}

// MARK: - The builder

/// Assembles a budgeted ``ConnectorPrompt`` from a context. Pure and synchronous:
/// no clock, no I/O, no randomness, so the same context always builds the same bytes.
public enum ConnectorPromptBuilder {
    /// Builds one request.
    ///
    /// - Parameters:
    ///   - context: The uncapped library facts and listener text.
    ///   - locale: The language the request is written in, named for the provider
    ///     rather than inferred — matching `NaturalLanguageQueryParsing.parse(text:locale:)`.
    ///   - schemaByteCount: Fixed cost of the schema in the body. Injectable so a test
    ///     can drive the byte backstop, which the shipped schema never reaches.
    public static func build(
        _ context: ConnectorPromptContext,
        locale: Locale,
        schemaByteCount: Int = PlaylistQuerySchema.canonicalByteCount
    ) -> ConnectorPrompt {
        let prompt = String(context.requestText.prefix(ConnectorPayloadBudget.maxRequestCharacters))
        var genres = ranked(context.genres, limit: ConnectorPayloadBudget.maxGenres)
        var artists = ranked(context.artists, limit: ConnectorPayloadBudget.maxArtists)
        var summary = String(context.summary.prefix(ConnectorPayloadBudget.maxSummaryCharacters))

        var instructions = instructionsText(genres: genres, artists: artists, summary: summary, locale: locale)
        var bytes = serializedByteCount(instructions: instructions, prompt: prompt, schemaByteCount: schemaByteCount)
        var isOverBudget = false
        while bytes > ConnectorPayloadBudget.maxSerializedBodyBytes {
            guard shrink(genres: &genres, artists: &artists, summary: &summary) else {
                isOverBudget = true
                break
            }
            instructions = instructionsText(genres: genres, artists: artists, summary: summary, locale: locale)
            bytes = serializedByteCount(instructions: instructions, prompt: prompt, schemaByteCount: schemaByteCount)
        }

        return ConnectorPrompt(
            instructions: instructions,
            prompt: prompt,
            genres: genres,
            artists: artists,
            serializedByteCount: bytes,
            truncation: ConnectorPromptTruncation(
                droppedRequestCharacters: context.requestText.count - prompt.count,
                droppedGenres: context.genres.count - genres.count,
                droppedArtists: context.artists.count - artists.count,
                droppedSummaryCharacters: context.summary.count - summary.count,
                isOverBudget: isOverBudget
            )
        )
    }

    /// Size of the body `instructions` + `prompt` + a schema will serialize to.
    ///
    /// Measured, not estimated: each string is JSON-encoded so escaping and multi-byte
    /// characters are counted exactly, which matters for a library whose genres are
    /// CJK or carry quotes.
    public static func serializedByteCount(instructions: String, prompt: String, schemaByteCount: Int) -> Int {
        schemaByteCount
            + jsonByteCount(instructions)
            + jsonByteCount(prompt)
            + ConnectorPayloadBudget.envelopeOverheadBytes
    }

    /// The system instructions for one request.
    ///
    /// Deliberately the on-device tier's wording (`AssistantLibraryContext.instructionsText`)
    /// plus one line: a connector answers as raw JSON, and while all three providers
    /// enforce that structurally — Ollama's `format`, Anthropic's forced tool, OpenAI's
    /// `response_format` — saying so costs nine words and rescues a model that wraps
    /// its answer in a code fence anyway.
    ///
    /// English is correct here. Nothing in this string reaches a screen; the language
    /// the REQUEST is written in is named from `locale`, and everything a listener
    /// actually reads goes through the String Catalogs.
    public static func instructionsText(
        genres: [String],
        artists: [String],
        summary: String,
        locale: Locale
    ) -> String {
        var lines = [
            "You turn a music listener's request into playlist filters.",
            "Answer with JSON only — no prose, no markdown, no code fences.",
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

// MARK: - Ranking and shrinking

private extension ConnectorPromptBuilder {
    /// One candidate name plus the two keys that order it.
    struct RankedEntry {
        let name: String
        let count: Int
        let position: Int
    }

    /// The kept names: most frequent first, ties in the caller's own order.
    ///
    /// DROP FIRST, cap second — the same order `AssistantPromptFormatting.rankedLine`
    /// uses, and for the same reason: capping first would let one corrupt
    /// 5000-character tag SPEND a slot it is then dropped from, so the prompt would
    /// carry 63 genres where it advertises 64.
    ///
    /// The `position` tiebreak is what makes the sort total. Swift's `sort` is not
    /// stable, so equal counts without it would be free to permute between runs, and
    /// "deterministically selected" would be a claim rather than a property.
    static func ranked(_ entries: [AssistantNameCount], limit: Int) -> [String] {
        entries
            .enumerated()
            .compactMap { position, entry -> RankedEntry? in
                let trimmed = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, trimmed.count <= ConnectorPayloadBudget.maxNameLength else { return nil }
                return RankedEntry(name: trimmed, count: entry.count, position: position)
            }
            .sorted { lhs, rhs in
                lhs.count == rhs.count ? lhs.position < rhs.position : lhs.count > rhs.count
            }
            .prefix(limit)
            .map(\.name)
    }

    /// Removes the single least valuable remaining part, or reports that nothing is
    /// left to remove.
    ///
    /// Order — genre tail, then artist tail, then the summary entirely:
    ///
    /// 1. The genre line is the largest variable component (64 names at up to 40
    ///    characters), so it frees the most bytes per drop.
    /// 2. A shortened genre vocabulary still parses correctly: the ANSWER is validated
    ///    client-side by `GenreVocabularyMatcher` against the FULL library list, not
    ///    against the list the prompt happened to carry.
    /// 3. Artists are only ever a "more like ..." hint, but they are the one signal
    ///    such a request has, so they outlive the genre surplus.
    /// 4. The summary is a single sentence — cheap to lose, and cheapest to lose last.
    ///
    /// The listener's own request is NEVER shortened below its character cap. Every
    /// other part can be reconstructed from the library; their words cannot.
    static func shrink(genres: inout [String], artists: inout [String], summary: inout String) -> Bool {
        if !genres.isEmpty {
            genres.removeLast()
        } else if !artists.isEmpty {
            artists.removeLast()
        } else if !summary.isEmpty {
            summary = ""
        } else {
            return false
        }
        return true
    }

    /// Bytes `text` occupies as a JSON string value, escaping included.
    ///
    /// Encodes a one-element array and subtracts the two brackets, because a bare
    /// `String` is a top-level JSON fragment and not every `JSONEncoder` accepts one.
    /// The fallback is the unescaped length plus two quotes — an under-count only for
    /// text that needed escaping, which is why it is a fallback and not the method.
    static func jsonByteCount(_ text: String) -> Int {
        guard let data = try? PlaylistQuerySchema.canonicalEncoder().encode([text]) else {
            return text.utf8.count + 2
        }
        return data.count - 2
    }
}
