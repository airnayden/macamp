// HeuristicQueryParser — tiers 2 and 3 of the natural-language ladder.
//
// Tier 1 is the FoundationModels backend. It does not exist on the macOS 14 /
// iOS 17 floor, it is off whenever Apple Intelligence is unavailable, and it can
// refuse or time out. This file is what runs the other 100% of the time, so its
// governing property is that it ALWAYS PRODUCES A SPEC: `parse` is `throws` only
// to satisfy ``NaturalLanguageQueryParsing``, and nothing inside it throws. A
// failing genre lookup degrades to "no genre matched", never to an error — a
// fallback that can fail is not a fallback.
//
// ── TIER 2: TOKENS × A LOCALIZED TABLE ────────────────────────────────────────
//
// `NLTagger` supplies language-aware word tokenization; ``AssistantVocabulary``
// supplies the words to look for. The two are unioned with a plain
// whitespace split, because NLTagger tokenizes a hyphenated decade apart:
// `"енергична музика от 90-те"` yields `["енергична", "музика", "от", "90", "те"]`
// and loses `90-те` entirely, while the whitespace pass keeps it. Measured, not
// assumed — see the todo-15 evidence file. Both passes feed one deduplicated,
// order-preserving token list.
//
// ── TIER 2½: THE EMBEDDING BOOST IS OPTIONAL, AND USUALLY ABSENT ──────────────
//
// `NLEmbedding` returns `nil` for `bg` and `ru` — 2 of the 7 shipped locales —
// even on a fully provisioned macOS 26 host, so it may only ENHANCE the table
// above. Every access is guarded and the lookup itself is an injected seam, so
// the nil path is exercised deterministically by tests rather than depending on
// which model assets the test machine happens to carry. There is no `!` anywhere
// in this file.
//
// The boost runs ONLY when direct matching found neither a mood nor a tempo, and
// it feeds only the mood and tempo tables. A neighbour of a genre name is a
// DIFFERENT genre and a neighbour of a decade is noise; proposing either would be
// an invention rather than a translation of what the listener asked for.
//
// ── TIER 3: THE DETERMINISTIC DEFAULT ─────────────────────────────────────────
//
// See ``HeuristicQueryParser/deterministicDefault``.
//
// ── DELIBERATELY NOT PARSED ───────────────────────────────────────────────────
//
// * `targetCount` — a bare integer is ambiguous with a decade ("90"), and reading
//   "the 90s" as "90 tracks" is a worse failure than not supporting counts. The
//   spec keeps `MixSpec.defaultTargetCount`; a UI stepper is the honest surface.
// * `seedArtists` — matching artist names needs the library's artist list and a
//   multi-word matcher that does not fire on ordinary words. Tier 1 does this
//   properly; guessing here would put a wrong artist in a proposal.
import Foundation
import NaturalLanguage
import Persistence

/// Turns free text into a ``PlaylistQuerySpec`` with no model of any kind.
public struct HeuristicQueryParser: NaturalLanguageQueryParsing {
    /// Supplies the genre names the library actually contains.
    ///
    /// Injected rather than read from `TrackRepository` directly so the parser
    /// stays testable with no database, and so a caller can scope the list to the
    /// active profile without this type knowing profiles exist. A genre the
    /// library does not contain would silently empty the result, which is why
    /// matching is done against a live list rather than a shipped genre table.
    public typealias KnownGenresProvider = @Sendable () async throws -> [String]

    /// Looks up semantically similar words for one token.
    ///
    /// Returns `nil` when no embedding exists for the language — the normal case
    /// for `bg` and `ru`. An empty array means "an embedding exists but knows no
    /// neighbours", which is also normal: a sentence embedding answers
    /// `neighbors(for:)` with `[]`.
    public typealias EmbeddingNeighbourLookup = @Sendable (String, Locale) -> [String]?

    /// An entry shorter than this matches a token only by equality; at or above
    /// it, a token that STARTS WITH the entry matches too. Four is the shortest
    /// length at which prefix matching buys inflection coverage (`темн` →
    /// тёмная/тёмные) without swallowing unrelated words.
    public static let stemMinimumLength = 4

    /// How many neighbours one embedding lookup may contribute.
    public static let neighbourLimit = 5

    /// Upper bound on genres a single request may name.
    public static let maxMatchedGenres = 6

    /// Tier 3: what an unparseable request becomes.
    ///
    /// The plan calls for a "favourites + recency mix". ``PlaylistQuerySpec`` has
    /// no favourites field — there is nothing to set — so this expresses the half
    /// that IS expressible, `.recentlyPlayed`, and flags ``lowConfidence`` so the
    /// downstream resolver can layer the favourites half on top and the UI can say
    /// "here is a starting point" instead of presenting a guess as an answer.
    /// Returning a fully unconstrained spec was the alternative and is worse: the
    /// whole library in seeded-shuffle order is not a useful answer to a request
    /// nobody understood.
    public static let deterministicDefault = PlaylistQuerySpec(
        recency: .recentlyPlayed,
        lowConfidence: true
    )

    private let knownGenres: KnownGenresProvider
    private let embeddingNeighbours: EmbeddingNeighbourLookup

    /// - Parameters:
    ///   - knownGenres: The library's genre names. Defaults to none, which
    ///     disables genre matching rather than inventing genres.
    ///   - embeddingNeighbours: The similarity seam. Defaults to the system
    ///     `NLEmbedding`; tests inject a closure returning `nil` to pin the
    ///     no-embedding path regardless of the host's model assets.
    public init(
        knownGenres: @escaping KnownGenresProvider = { [] },
        embeddingNeighbours: @escaping EmbeddingNeighbourLookup = HeuristicQueryParser.systemNeighbours
    ) {
        self.knownGenres = knownGenres
        self.embeddingNeighbours = embeddingNeighbours
    }

    public func parse(text: String, locale: Locale) async throws -> PlaylistQuerySpec {
        let vocabulary = AssistantVocabulary.vocabulary(for: locale)
        let tokens = Self.normalizedTokens(in: text, locale: locale)
        var moods = Self.moods(in: tokens, vocabulary: vocabulary)
        var tempo = Self.tempo(in: tokens, vocabulary: vocabulary)
        if moods.isEmpty, tempo == nil {
            let boosted = boostedTokens(from: tokens, locale: locale)
            moods = Self.moods(in: boosted, vocabulary: vocabulary)
            tempo = Self.tempo(in: boosted, vocabulary: vocabulary)
        }
        let spec = await PlaylistQuerySpec(
            genres: matchedGenres(tokens: tokens, text: text),
            yearRange: Self.yearRange(in: tokens, vocabulary: vocabulary),
            moodTags: moods,
            tempoRange: tempo,
            recency: Self.recency(in: tokens, vocabulary: vocabulary)
        )
        // `isUnconstrained` ignores targetCount and lowConfidence, so it is exactly
        // the question "did anything at all match?" — reuse it rather than tracking
        // a parallel flag that could disagree with the spec it describes.
        return spec.isUnconstrained ? Self.deterministicDefault : spec
    }

    /// The default ``EmbeddingNeighbourLookup``: the system word embedding, or the
    /// sentence embedding, or nothing at all.
    ///
    /// Both factories are optional and both are `guard let`-ed. `bg` and `ru`
    /// return `nil` from BOTH on a fully provisioned host, which is the entire
    /// reason this seam may never be load-bearing.
    public static func systemNeighbours(for token: String, locale: Locale) -> [String]? {
        guard let code = locale.language.languageCode?.identifier, !code.isEmpty else { return nil }
        let language = NLLanguage(code)
        let embedding = NLEmbedding.wordEmbedding(for: language)
            ?? NLEmbedding.sentenceEmbedding(for: language)
        guard let embedding else { return nil }
        return embedding.neighbors(for: token, maximumCount: neighbourLimit).map(\.0)
    }
}

// MARK: - Tokenization

private extension HeuristicQueryParser {
    /// Case-, diacritic- and width-folded, punctuation-trimmed.
    ///
    /// Folded against a fixed `en_US_POSIX` locale — the same choice `SortKey`
    /// makes — so the result never depends on the user's region settings.
    static func normalized(_ raw: String) -> String {
        raw
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: posixLocale)
            .trimmingCharacters(in: trimmable)
    }

    static let posixLocale = Locale(identifier: "en_US_POSIX")
    static let trimmable = CharacterSet.punctuationCharacters
        .union(.whitespacesAndNewlines)
        .union(.symbols)

    /// NLTagger's word tokens unioned with a whitespace split, normalized and
    /// deduplicated in first-occurrence order.
    static func normalizedTokens(in text: String, locale: Locale) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in taggerTokens(in: text, locale: locale) + whitespaceTokens(in: text) {
            let token = normalized(raw)
            guard !token.isEmpty, seen.insert(token).inserted else { continue }
            result.append(token)
        }
        return result
    }

    static func taggerTokens(in text: String, locale: Locale) -> [String] {
        guard !text.isEmpty else { return [] }
        let range = text.startIndex ..< text.endIndex
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text
        tagger.setLanguage(NLLanguage(AssistantVocabulary.languageCode(for: locale)), range: range)
        var result: [String] = []
        tagger.enumerateTags(
            in: range,
            unit: .word,
            scheme: .lexicalClass,
            options: [.omitPunctuation, .omitWhitespace]
        ) { _, tokenRange in
            result.append(String(text[tokenRange]))
            return true
        }
        return result
    }

    static func whitespaceTokens(in text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// A token matches an entry when it equals it, or when the entry is a stem of
    /// at least ``stemMinimumLength`` characters that the token starts with.
    static func matches(_ token: String, entry: String) -> Bool {
        let stem = normalized(entry)
        guard !stem.isEmpty else { return false }
        if token == stem { return true }
        return stem.count >= stemMinimumLength && token.hasPrefix(stem)
    }

    static func contains(_ tokens: [String], anyOf entries: Set<String>) -> Bool {
        entries.contains { entry in tokens.contains { matches($0, entry: entry) } }
    }
}

// MARK: - Table matching

//
// Every reader below iterates a `CaseIterable` enum rather than the vocabulary's
// dictionaries, so the OUTPUT order is fixed by the enum's declaration order and
// never by `Dictionary`'s nondeterministic iteration. Two runs over the same text
// produce byte-identical specs.

private extension HeuristicQueryParser {
    static func moods(in tokens: [String], vocabulary: LocaleVocabulary) -> [PlaylistMoodTag] {
        PlaylistMoodTag.allCases.filter { tag in
            contains(tokens, anyOf: vocabulary.moodKeywords[tag] ?? [])
        }
    }

    /// The first tempo bucket, in ``TempoHint`` declaration order, that any token
    /// names. A request naming both buckets keeps the earlier one rather than
    /// composing an empty range.
    static func tempo(in tokens: [String], vocabulary: LocaleVocabulary) -> SmartPlaylistRange<Double>? {
        let matched = TempoHint.allCases.first { candidate in
            let words = Set(vocabulary.tempoKeywords.filter { $0.value == candidate }.keys)
            return contains(tokens, anyOf: words)
        }
        return matched?.range
    }

    static func recency(in tokens: [String], vocabulary: LocaleVocabulary) -> PlaylistRecencyPreference? {
        PlaylistRecencyPreference.allCases.first { preference in
            contains(tokens, anyOf: vocabulary.recencyKeywords[preference] ?? [])
        }
    }

    /// The span of every decade the request named: "80s and 90s" is 1980…1989 ∪
    /// 1990…1999, which as one window is 1980…1999.
    static func yearRange(in tokens: [String], vocabulary: LocaleVocabulary) -> SmartPlaylistRange<Int>? {
        var decades: [Int] = []
        for (entry, decade) in vocabulary.decadeTokens
            where tokens.contains(where: { matches($0, entry: entry) })
        {
            decades.append(decade)
        }
        guard let earliest = decades.min(), let latest = decades.max() else { return nil }
        return SmartPlaylistRange(lower: earliest, upper: latest + 9)
    }
}

// MARK: - Genres and the embedding boost

private extension HeuristicQueryParser {
    /// Genres are matched against the LIVE library list, never a shipped table, and
    /// are returned in the provider's own order with their original spelling.
    ///
    /// A single-word genre must match a whole token, because prefix matching would
    /// make "rock" match "rocket". A multi-word genre ("drum and bass") is matched
    /// as a substring of the folded request instead, since its own tokens are
    /// ordinary words that would fire far too often on their own.
    func matchedGenres(tokens: [String], text: String) async -> [String] {
        let available: [String]
        do {
            available = try await knownGenres()
        } catch {
            return []
        }
        let haystack = Self.normalized(text)
        let tokenSet = Set(tokens)
        var result: [String] = []
        for genre in available {
            let needle = Self.normalized(genre)
            guard !needle.isEmpty else { continue }
            let hit = needle.contains(" ") ? haystack.contains(needle) : tokenSet.contains(needle)
            guard hit else { continue }
            result.append(genre)
            if result.count == Self.maxMatchedGenres { break }
        }
        return result
    }

    /// Neighbours of every token long enough to be a real word, or the tokens
    /// themselves when no embedding exists for the language.
    func boostedTokens(from tokens: [String], locale: Locale) -> [String] {
        var result = tokens
        for token in tokens where token.count >= Self.stemMinimumLength {
            guard let neighbours = embeddingNeighbours(token, locale) else { continue }
            result.append(contentsOf: neighbours.map { Self.normalized($0) })
        }
        return result
    }
}
