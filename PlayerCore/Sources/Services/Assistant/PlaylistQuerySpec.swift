// PlaylistQuerySpec — the seam currency shared by every natural-language tier.
//
// A resolved "what should this playlist contain" request, expressed in terms the
// rest of PlayerCore already understands. It is produced by ALL THREE tiers of the
// NL ladder — the FoundationModels backend, the heuristic NLTagger parser, and the
// deterministic default — and consumed by exactly one resolver, which turns it into
// a `SmartPlaylistRules` predicate set and/or a `MixSpec`.
//
// ── WHY THIS TYPE CARRIES NO `@Generable` ──────────────────────────────────────
//
// `@Generable` forces `macOS 26, iOS 26` availability onto whatever it decorates.
// Putting it here would make the seam currency itself unreachable on the macOS 14 /
// iOS 17 floor — that is, unreachable to the two fallback tiers that exist PRECISELY
// for machines where FoundationModels is absent or unavailable. The generable mirror
// is a SEPARATE 26+-gated type (`FMQuerySpecDTO`) living inside the availability
// island, with a pure `FMQuerySpecDTO -> PlaylistQuerySpec` mapping. This type stays
// plain, floor-available, `Codable` and `Sendable`.
//
// ── FIELD PROVENANCE ───────────────────────────────────────────────────────────
//
// Every field maps onto something that already exists, so a resolver is a
// translation and never an invention:
//
//   genres      -> `SmartPlaylistMetadataPredicate.genre(equals:)`, one per genre,
//                  `.any`-composed. MUST be validated against
//                  `TrackRepository.distinctGenres` by the producer — a genre the
//                  library does not contain silently empties the result.
//   yearRange   -> `SmartPlaylistMetadataPredicate.year(range:)`
//   moodTags    -> `SmartPlaylistAudioFeaturePredicate.energy/.brightness` buckets
//   tempoRange  -> `SmartPlaylistAudioFeaturePredicate.bpm(range:)`
//   recency     -> `SmartPlaylistRecencyPredicate` / `SmartPlaylistMetadataPredicate.dateAdded`
//   seedArtists -> `SmartPlaylistMetadataPredicate.artistName(equals:)`, or a
//                  `MixCandidateSource.similaritySeed(trackId:)` once resolved
//   targetCount -> `MixSpec.targetCount` (same clamp, same constants)
//
// The bounds types are `SmartPlaylistRange` rather than `ClosedRange` on purpose:
// an NL request is routinely half-open ("anything over 120 BPM", "before 2000"),
// which a `ClosedRange` cannot express, and reusing the rule engine's own range
// type means the resolver has nothing to convert.
import Foundation
import Persistence

/// A resolved natural-language playlist request.
///
/// Floor-available (macOS 14 / iOS 17) by contract — see the file header. Every
/// field is optional-or-empty by default, and an all-default spec means "no
/// constraint at all", which widens the result rather than emptying it (the same
/// choice `SmartPlaylistRules` makes for an empty predicate list).
public struct PlaylistQuerySpec: Codable, Sendable, Equatable, Hashable {
    /// Genre names, exactly as they appear in the library.
    ///
    /// Order-preserving and duplicate-free by construction. The PRODUCER is
    /// responsible for validating these against `TrackRepository.distinctGenres`
    /// before constructing a spec; this type cannot reach the database.
    public var genres: [String]

    /// Release-year window, or `nil` for no year constraint. A decade request
    /// ("90s") becomes `lower: 1990, upper: 1999`.
    public var yearRange: SmartPlaylistRange<Int>?

    /// Requested moods, translated downstream into audio-feature buckets.
    /// Order-preserving and duplicate-free by construction.
    public var moodTags: [PlaylistMoodTag]

    /// Tempo window in beats per minute, or `nil` for no tempo constraint.
    ///
    /// Note that a track with no analysed tempo is NOT excluded by the rule engine
    /// (`bpm IS NULL OR bpm BETWEEN ?, ?`), so a tempo request over an unanalysed
    /// library widens rather than empties. Surface `requiresAnalysis` for that.
    public var tempoRange: SmartPlaylistRange<Double>?

    /// How the request treats listening history, or `nil` when it says nothing.
    public var recency: PlaylistRecencyPreference?

    /// Artist names the request named explicitly ("more like Radiohead").
    /// Order-preserving and duplicate-free by construction.
    public var seedArtists: [String]

    /// How many tracks the resulting playlist should hold, clamped to
    /// `1 ... MixSpec.maxTargetCount` so a spec can never ask for an unbounded scan.
    public var targetCount: Int

    /// `true` when the spec was NOT derived from understood input — the tier-3
    /// deterministic default, produced when no tier could parse the request.
    ///
    /// The spec is still valid and still executes; the flag exists so the UI can say
    /// "here's a starting point" rather than presenting a guess as an answer.
    public var lowConfidence: Bool

    public init(
        genres: [String] = [],
        yearRange: SmartPlaylistRange<Int>? = nil,
        moodTags: [PlaylistMoodTag] = [],
        tempoRange: SmartPlaylistRange<Double>? = nil,
        recency: PlaylistRecencyPreference? = nil,
        seedArtists: [String] = [],
        targetCount: Int = MixSpec.defaultTargetCount,
        lowConfidence: Bool = false
    ) {
        self.genres = Self.normalizedNames(genres)
        self.yearRange = yearRange
        self.moodTags = Self.deduplicated(moodTags)
        self.tempoRange = tempoRange
        self.recency = recency
        self.seedArtists = Self.normalizedNames(seedArtists)
        self.targetCount = min(max(1, targetCount), MixSpec.maxTargetCount)
        self.lowConfidence = lowConfidence
    }

    /// `true` when the spec carries no constraint whatsoever — the resolver should
    /// treat it as "the whole visible library", not as an error.
    public var isUnconstrained: Bool {
        genres.isEmpty
            && yearRange == nil
            && moodTags.isEmpty
            && tempoRange == nil
            && recency == nil
            && seedArtists.isEmpty
    }

    // MARK: Private

    /// Trims, drops empties, and de-duplicates while PRESERVING ORDER.
    ///
    /// Order matters: a generated spec's first genre is its most confident one, and
    /// `Set` iteration order is nondeterministic, so a `Set`-based de-duplication
    /// would make an otherwise deterministic pipeline vary run to run.
    private static func normalizedNames(_ names: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for name in names {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }

    private static func deduplicated(_ tags: [PlaylistMoodTag]) -> [PlaylistMoodTag] {
        var seen = Set<PlaylistMoodTag>()
        var result: [PlaylistMoodTag] = []
        for tag in tags where seen.insert(tag).inserted {
            result.append(tag)
        }
        return result
    }
}

/// A mood the listener asked for, in terms the shipped analyser can actually serve.
///
/// DELIBERATELY NOT a valence vocabulary. `AudioFeatureResult` measures exactly
/// three things — `bpm`, `energy`, `brightness` — and nothing in this app estimates
/// happy-versus-sad. A `.happy` tag would therefore be undeliverable: it could only
/// ever be resolved as "energetic", which is a different claim. Each case below
/// names the ONE feature dimension it is a bucket of, so a parser that maps
/// "upbeat" onto `.energetic` is making an honest translation rather than promising
/// an analysis the pipeline does not perform.
///
/// The concrete bucket RANGES are a tuning decision and live with the parser, not
/// here — this type only fixes the closed vocabulary the tiers agree on.
public enum PlaylistMoodTag: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    /// Low `energy` — "chill", "mellow", "relaxed", "quiet".
    case calm
    /// High `energy` — "upbeat", "hype", "workout", "intense".
    case energetic
    /// Low `brightness` — "dark", "heavy", "moody", "bass-heavy".
    case dark
    /// High `brightness` — "bright", "airy", "shimmering", "crisp".
    case bright
}

/// How a request wants listening history weighed.
///
/// Three cases, each a direct translation of an existing predicate — nothing here
/// needs a new query shape.
public enum PlaylistRecencyPreference: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    /// Favour recent library additions — `SmartPlaylistMetadataPredicate.dateAdded(range:)`.
    case freshlyAdded
    /// Favour tracks played lately — `SmartPlaylistRecencyPredicate.playedWithin(days:)`.
    case recentlyPlayed
    /// Favour tracks NOT played lately — `…notPlayedWithin(days:)`. Note this can
    /// only see roughly 24 months of history: `PlayEventCompactor` deletes raw
    /// events past that horizon and `playEventRollup` keeps no `trackId`.
    case rediscovery
}
