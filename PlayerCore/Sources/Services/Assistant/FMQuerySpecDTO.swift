// FMQuerySpecDTO — the generable mirror of ``PlaylistQuerySpec``, and the pure
// validation that turns what a model SAID into what the library can actually serve.
//
// ── THE THREE-SYMBOL LAYERING (mirrors AssistantAvailability.swift) ────────────
//
// | Symbol                          | Availability | Touches FM? | Purpose                       |
// |---------------------------------|--------------|-------------|-------------------------------|
// | ``FMQuerySpecFields``           | floor        | no          | raw, UNVALIDATED model output |
// | ``FMQuerySpecFields/resolve``   | floor        | no          | the PURE validating mapper    |
// | ``FMQuerySpecDTO``              | 26+, gated   | YES         | `@Generable` wire shape       |
//
// The generable type carries NO logic beyond projecting itself into
// ``FMQuerySpecFields``. Every decision that can be wrong — is this a real genre,
// is this a mood we can serve, is 19 a plausible year — lives in the floor-available
// mapper, so it is table-testable on any host with no model, no session and no
// Apple Intelligence. That is the same split ``AssistantAvailability/resolve(raw:intelligenceEnabled:)``
// makes, and for the same reason.
//
// ── WHY THE FIELDS ARE STRINGS AND OPTIONALS, NOT ENUMS AND RANGES ────────────
//
// A model returns text. Typing ``FMQuerySpecFields/moodTags`` as `[PlaylistMoodTag]`
// would mean SOMETHING already decided what to do with `"euphoric"` before this
// type was reachable — and that decision is exactly what needs testing. So the raw
// bag holds `[String]`, and `resolve` is the single documented place where an
// unservable value is dropped.
//
// Ranges are carried as two independent optional bounds rather than a
// ``SmartPlaylistRange`` because `@Generable` cannot decorate a generic type from
// another module, and because a model routinely produces exactly one bound
// ("over 120 BPM"). `resolve` assembles the range and drops it entirely when
// neither bound survived.
//
// ── VALIDATION POLICY: DROP, NEVER INVENT ─────────────────────────────────────
//
// Every guard below DROPS an unservable value rather than clamping it to the
// nearest legal one. Clamping a hallucinated `year: 19` to `1860` would state a
// constraint the listener never asked for; dropping it leaves the bound `nil`,
// which ``SmartPlaylistRange`` documents as "no constraint" — widening the result
// instead of silently emptying or falsifying it. That is the same choice the rule
// engine already makes for an under-specified predicate.
import Foundation
import Persistence

// MARK: - Raw fields (floor-available)

/// The unvalidated field bag a language model produced for one request.
///
/// Floor-available and free of `@Generable` by contract — see the file header. It
/// is the input to the pure mapper, and the output of the 26+-gated
/// ``FMQuerySpecDTO``; nothing else should construct one outside of tests.
public struct FMQuerySpecFields: Sendable, Equatable, Hashable {
    /// Years a request may plausibly name. A recording predates 1860 only in
    /// fiction, and a future-dated request past 2999 is a hallucination, not a
    /// preference. Bounds outside this window are DROPPED, never clamped.
    public static let plausibleYears = 1860 ... 2999

    /// Tempi a request may plausibly name, in BPM. Wider than the analyser's own
    /// 60...200 detection window on purpose: a listener may ask for something the
    /// analyser will simply not match, which is a legitimate empty result rather
    /// than a malformed request.
    public static let plausibleTempi = 20.0 ... 400.0

    /// The closed mood vocabulary, as the strings a model is asked to choose from.
    /// Derived from ``PlaylistMoodTag`` so it cannot drift from the enum.
    public static var moodVocabulary: [String] {
        PlaylistMoodTag.allCases.map(\.rawValue)
    }

    /// The value a model returns for ``recency`` when the request expressed no
    /// preference. A sentinel rather than an omitted field: a closed choice list
    /// including "no preference" is a far easier target than an optional.
    public static let recencyNone = "none"

    /// The closed recency vocabulary, ``recencyNone`` first.
    public static var recencyVocabulary: [String] {
        [recencyNone] + PlaylistRecencyPreference.allCases.map(\.rawValue)
    }

    /// Genre names the model chose. Validated against the library's real genres.
    public var genres: [String]
    /// Earliest release year, or `nil` for unbounded below.
    public var yearLowerBound: Int?
    /// Latest release year, or `nil` for unbounded above.
    public var yearUpperBound: Int?
    /// Mood words the model chose, expected to come from ``moodVocabulary``.
    public var moodTags: [String]
    /// Slowest tempo in BPM, or `nil` for unbounded below.
    public var tempoLowerBPM: Double?
    /// Fastest tempo in BPM, or `nil` for unbounded above.
    public var tempoUpperBPM: Double?
    /// A ``recencyVocabulary`` member, or `nil` when the model omitted the field.
    public var recency: String?
    /// Artists the request named explicitly.
    public var seedArtists: [String]
    /// Requested length, or `nil` to use ``MixSpec/defaultTargetCount``.
    public var targetCount: Int?

    public init(
        genres: [String] = [],
        yearLowerBound: Int? = nil,
        yearUpperBound: Int? = nil,
        moodTags: [String] = [],
        tempoLowerBPM: Double? = nil,
        tempoUpperBPM: Double? = nil,
        recency: String? = nil,
        seedArtists: [String] = [],
        targetCount: Int? = nil
    ) {
        self.genres = genres
        self.yearLowerBound = yearLowerBound
        self.yearUpperBound = yearUpperBound
        self.moodTags = moodTags
        self.tempoLowerBPM = tempoLowerBPM
        self.tempoUpperBPM = tempoUpperBPM
        self.recency = recency
        self.seedArtists = seedArtists
        self.targetCount = targetCount
    }
}

// MARK: - The pure mapper

public extension FMQuerySpecFields {
    /// Validates this bag against the library and produces a servable spec.
    ///
    /// Pure: no I/O, no clock, no randomness, no FoundationModels reference. The
    /// same inputs always produce the same spec.
    ///
    /// - Parameter validGenres: The library's real genres, normally
    ///   `TrackRepository.distinctGenres`. Applied through
    ///   ``GenreVocabularyMatcher/validated(_:against:)``, which owns the match
    ///   rule — including why an EMPTY vocabulary passes every genre through — so
    ///   the connector tier applies the identical guard from one implementation.
    func resolve(validGenres: [String]) -> PlaylistQuerySpec {
        let spec = PlaylistQuerySpec(
            genres: GenreVocabularyMatcher.validated(genres, against: validGenres),
            yearRange: Self.range(lower: yearLowerBound, upper: yearUpperBound, within: Self.plausibleYears),
            moodTags: moodTags.compactMap(Self.mood(from:)),
            tempoRange: Self.range(lower: tempoLowerBPM, upper: tempoUpperBPM, within: Self.plausibleTempi),
            recency: Self.recencyPreference(from: recency),
            seedArtists: seedArtists,
            targetCount: targetCount ?? MixSpec.defaultTargetCount
        )
        // A spec that constrains nothing is not a confident reading of a request,
        // whether the model understood nothing or every value it offered was
        // unservable. The flag lets the UI offer it as a starting point rather
        // than present it as an answer; the spec itself still executes.
        return PlaylistQuerySpec(
            genres: spec.genres,
            yearRange: spec.yearRange,
            moodTags: spec.moodTags,
            tempoRange: spec.tempoRange,
            recency: spec.recency,
            seedArtists: spec.seedArtists,
            targetCount: spec.targetCount,
            lowConfidence: spec.isUnconstrained
        )
    }

    // MARK: Private

    /// Assembles a range from two bounds, dropping any bound outside `window` and
    /// the whole range when neither bound survives.
    ///
    /// An inverted pair is SWAPPED rather than dropped: "between 2000 and 1990" is
    /// an ordering slip in an otherwise clear request, and swapping honours it.
    private static func range<Bound: Comparable & Codable & Sendable & Hashable>(
        lower: Bound?,
        upper: Bound?,
        within window: ClosedRange<Bound>
    ) -> SmartPlaylistRange<Bound>? {
        let low = lower.flatMap { window.contains($0) ? $0 : nil }
        let high = upper.flatMap { window.contains($0) ? $0 : nil }
        guard low != nil || high != nil else { return nil }
        if let low, let high, low > high {
            return SmartPlaylistRange(lower: high, upper: low)
        }
        return SmartPlaylistRange(lower: low, upper: high)
    }

    /// Maps one model word onto the closed mood vocabulary, case-insensitively.
    /// An unrecognised word is dropped — see the file header's DROP policy.
    private static func mood(from raw: String) -> PlaylistMoodTag? {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return PlaylistMoodTag.allCases.first { $0.rawValue.lowercased() == key }
    }

    /// Maps the recency field, treating ``recencyNone``, an empty string and any
    /// unrecognised word alike as "no preference".
    private static func recencyPreference(from raw: String?) -> PlaylistRecencyPreference? {
        guard let raw else { return nil }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty, key != recencyNone else { return nil }
        return PlaylistRecencyPreference.allCases.first { $0.rawValue.lowercased() == key }
    }
}

#if canImport(FoundationModels)
    import FoundationModels

    // MARK: - The generable wire shape (26+)

    /// The structured shape a ``LanguageModelSession`` is asked to fill in.
    ///
    /// Guided generation constrains the model at DECODE time — a `.anyOf` guide
    /// makes an off-vocabulary mood literally unrepresentable rather than merely
    /// discouraged. ``FMQuerySpecFields/resolve(validGenres:)`` still validates
    /// everything afterwards: guides bind this SDK's decoder, and the contract must
    /// hold even if a future OS relaxes one.
    ///
    /// `genres` deliberately carries NO `.anyOf` guide. The legal genre list is the
    /// user's library, known only at runtime, and a macro argument is expanded at
    /// compile time — so the vocabulary is supplied in the session INSTRUCTIONS and
    /// enforced by ``FMQuerySpecFields/resolve(validGenres:)`` instead.
    @available(macOS 26, iOS 26, *)
    @Generable(description: "A listener's request for a playlist, broken into filters")
    public struct FMQuerySpecDTO {
        @Guide(
            description: "Genres named or implied, spelled exactly as in the library genre list above."
        )
        public var genres: [String]

        @Guide(
            description: "Earliest release year allowed, e.g. 1990 for 'the 90s'. Null if unmentioned."
        )
        public var yearLowerBound: Int?

        @Guide(
            description: "Latest release year allowed, e.g. 1999 for 'the 90s'. Null if unmentioned."
        )
        public var yearUpperBound: Int?

        @Guide(
            description: "Moods asked for. calm/energetic describe drive; dark/bright describe tone.",
            .element(.anyOf(["calm", "energetic", "dark", "bright"]))
        )
        public var moodTags: [String]

        @Guide(
            description: "Slowest tempo in BPM allowed. Null if the request says nothing about tempo."
        )
        public var tempoLowerBPM: Double?

        @Guide(
            description: "Fastest tempo in BPM allowed. Null if the request says nothing about tempo."
        )
        public var tempoUpperBPM: Double?

        @Guide(
            description: "How to weigh listening history. Use none if the request says nothing.",
            .anyOf(["none", "freshlyAdded", "recentlyPlayed", "rediscovery"])
        )
        public var recency: String

        @Guide(
            description: "Artists named explicitly, e.g. 'more like Radiohead'. Empty if none."
        )
        public var seedArtists: [String]

        @Guide(
            description: "How many tracks the listener asked for.",
            .range(1 ... 100)
        )
        public var targetCount: Int
    }

    @available(macOS 26, iOS 26, *)
    public extension FMQuerySpecDTO {
        /// Projects the generated shape onto the floor-available raw bag.
        ///
        /// A projection and nothing more: no validation happens here, so the whole
        /// of it stays in the one pure, host-independent place.
        var fields: FMQuerySpecFields {
            FMQuerySpecFields(
                genres: genres,
                yearLowerBound: yearLowerBound,
                yearUpperBound: yearUpperBound,
                moodTags: moodTags,
                tempoLowerBPM: tempoLowerBPM,
                tempoUpperBPM: tempoUpperBPM,
                recency: recency,
                seedArtists: seedArtists,
                targetCount: targetCount
            )
        }
    }
#endif
