// AssistantBackends — the three protocol seams every assistant tier is written to.
//
// Each seam is deliberately narrow and takes only AGGREGATES, never a track list:
// a FoundationModels conformer has a bounded token budget (Apple TN3193: ~4096 per
// session), so "the top five genres with counts" is a contract the FM tier can meet
// while "here are 8000 tracks" is not. Keeping the aggregate shape in the PROTOCOL
// rather than in the FM conformer is what stops a later tier from quietly widening
// the prompt.
//
// ── ISOLATION ──────────────────────────────────────────────────────────────────
//
// These are nonisolated `Sendable` protocols with `async` requirements, NOT
// `@MainActor` ones. That is the opposite choice from ``AISettingsProviding``, and
// for the same reason: the shape follows the conformers. `AISettingsProviding`'s
// conformers are `@MainActor @Observable` shell classes; these conformers are the
// FM backend (a Swift `actor`, single-in-flight, `CoreMLSeparator` precedent) and
// pure-value heuristic parsers. An actor satisfies an `async` requirement directly.
//
// ── ERRORS ─────────────────────────────────────────────────────────────────────
//
// Every seam is `throws` and deliberately does NOT name a concrete error type: the
// tiers fail for unrelated reasons and callers fall back rather than inspect. An
// FM-backed conformer maps the framework's error surface into ``AssistantFailure``.
//
// CORRECTION (todo 14, verified against the local SDK rather than documentation):
// this header previously stated that `LanguageModelSession.GenerationError` was
// deprecated in favour of a `LanguageModelError`. The opposite is true for the
// shipped SDK — `LanguageModelError` DOES NOT EXIST in FoundationModels 1.5.2
// (macOS 26.5), `GenerationError` carries no deprecation attribute, and its
// context case is spelled `exceededContextWindowSize`. See ``AssistantFailure``'s
// file header for the enumeration command; re-run it before trusting any mapping
// against a newer SDK.
import Foundation

// MARK: - Shared aggregate

/// A ranked name with the count that ranked it — the aggregate currency of the
/// naming and narration seams.
public struct AssistantNameCount: Sendable, Equatable, Hashable {
    /// The genre or artist name exactly as stored, or `""` when it was unknown.
    public var name: String
    /// Whatever was counted: tracks in a draft, or plays in a window.
    public var count: Int

    public init(name: String, count: Int) {
        self.name = name
        self.count = count
    }
}

// MARK: - Natural-language query parsing

/// Turns a listener's free text into a ``PlaylistQuerySpec``.
///
/// Conformed to by all three tiers of the NL ladder — the FoundationModels backend,
/// the heuristic NLTagger parser, and the deterministic default — which is exactly
/// why the return type is floor-available and carries no `@Generable`.
///
/// A conformer MUST always produce a spec or throw; it may never return a spec it
/// did not actually derive without setting ``PlaylistQuerySpec/lowConfidence``.
public protocol NaturalLanguageQueryParsing: Sendable {
    /// - Parameters:
    ///   - text: The listener's request, verbatim and untrimmed.
    ///   - locale: The locale the request was written in. Drives vocabulary
    ///     selection in the heuristic tier and prompt language in the FM tier; it
    ///     is NOT inferred from the text.
    func parse(text: String, locale: Locale) async throws -> PlaylistQuerySpec
}

// MARK: - Playlist naming

/// The aggregates a name is allowed to be derived from.
///
/// Aggregates ONLY — never the draft's tracks. A name is a summary, and handing a
/// generator the full track list would blow the token budget to produce a worse
/// answer than these seven numbers do.
public struct PlaylistNamingContext: Sendable, Equatable, Hashable {
    /// How many tracks the draft holds.
    public var trackCount: Int
    /// Genres present in the draft, ranked by track count, most common first.
    public var topGenres: [AssistantNameCount]
    /// Artists present in the draft, ranked by track count, most common first.
    public var topArtists: [AssistantNameCount]
    /// How many distinct artists the draft holds — the diversity signal that tells
    /// "an artist mix" apart from "a genre mix" with the same top artist.
    public var distinctArtistCount: Int
    /// The decade most of the draft comes from as a four-digit year (`1990`), or
    /// `nil` when no decade dominates or no track carries a year.
    public var dominantDecade: Int?
    /// The moods the request asked for, when it came from a ``PlaylistQuerySpec``.
    public var moodTags: [PlaylistMoodTag]

    public init(
        trackCount: Int,
        topGenres: [AssistantNameCount] = [],
        topArtists: [AssistantNameCount] = [],
        distinctArtistCount: Int = 0,
        dominantDecade: Int? = nil,
        moodTags: [PlaylistMoodTag] = []
    ) {
        self.trackCount = trackCount
        self.topGenres = topGenres
        self.topArtists = topArtists
        self.distinctArtistCount = distinctArtistCount
        self.dominantDecade = dominantDecade
        self.moodTags = moodTags
    }
}

/// A suggested playlist name, and optionally a one-line description.
///
/// GENERATED CONTENT IS DATA. Neither field passes through a String Catalog: they
/// are produced in the listener's language at generation time and PERSISTED into
/// `playlist.name`, so they do not re-localize when the app language changes.
/// Shells render them with `Text(verbatim:)`; all surrounding chrome stays
/// catalog-localized.
public struct PlaylistNamingResult: Sendable, Equatable, Hashable {
    /// The longest name this seam will carry. A sidebar row truncates well before
    /// this, and an unbounded generated string is a UI hazard, so the limit is
    /// enforced structurally rather than asserted downstream.
    public static let maxNameLength = 60

    /// The suggested name: trimmed, and never longer than ``maxNameLength``.
    ///
    /// A conformer that returns something longer has it TRUNCATED here rather than
    /// rejected — a slightly clipped name is a better outcome than no playlist.
    public var name: String
    /// An optional one-line description, trimmed. `nil` when the conformer offered
    /// none; never an empty string.
    public var description: String?

    public init(name: String, description: String? = nil) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = String(trimmedName.prefix(Self.maxNameLength))
        let trimmedDescription = description?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.description = (trimmedDescription?.isEmpty ?? true) ? nil : trimmedDescription
    }
}

/// Suggests a human name for a generated playlist.
///
/// A conformer MAY throw; callers are expected to fall back to a localized template
/// name rather than surface the failure, so a naming failure never blocks a draft.
public protocol PlaylistNaming: Sendable {
    /// - Parameters:
    ///   - context: The draft's aggregates. Never a track list.
    ///   - locale: The language the name should be written in.
    func suggestName(
        for context: PlaylistNamingContext,
        locale: Locale
    ) async throws -> PlaylistNamingResult
}

// MARK: - Insight narration

/// One ranked track in a narration context.
///
/// Carries the two fields separately rather than a pre-joined display string, so
/// the separator and ordering stay a presentation decision.
public struct InsightNarrationTrack: Sendable, Equatable, Hashable {
    public var title: String?
    public var artistName: String?
    public var plays: Int

    public init(title: String?, artistName: String?, plays: Int) {
        self.title = title
        self.artistName = artistName
        self.plays = plays
    }
}

/// The token-budgeted projection of ONE listening window that a narrative is
/// allowed to be written from.
///
/// A full ``ListeningDigest`` holds four windows, per-track hour histograms, daypart
/// breakdowns and lifetime replay clusters — orders of magnitude more than a session
/// budget allows. ``projecting(_:topLimit:)`` is the single, shared reduction, so
/// the FM tier and the template fallback narrate from identical inputs and cannot
/// drift apart.
public struct InsightNarrationContext: Sendable, Equatable, Hashable {
    /// How many entries each ranked list is cut to.
    public static let defaultTopLimit = 5

    /// Which window this narrative covers.
    public var window: ListeningWindowKind
    /// Plays in the window.
    public var totalPlays: Int
    /// Seconds actually heard in the window.
    public var totalListenedSeconds: Double
    /// Top artists by plays, at most ``defaultTopLimit``.
    public var topArtists: [AssistantNameCount]
    /// Top genres by plays, at most ``defaultTopLimit``.
    public var topGenres: [AssistantNameCount]
    /// Top tracks by plays, at most ``defaultTopLimit``.
    public var topTracks: [InsightNarrationTrack]
    /// The local hour (`0...23`) the listener played most in, or `nil` when the
    /// window recorded no raw events to bucket.
    public var peakLocalHour: Int?

    public init(
        window: ListeningWindowKind,
        totalPlays: Int = 0,
        totalListenedSeconds: Double = 0,
        topArtists: [AssistantNameCount] = [],
        topGenres: [AssistantNameCount] = [],
        topTracks: [InsightNarrationTrack] = [],
        peakLocalHour: Int? = nil
    ) {
        self.window = window
        self.totalPlays = totalPlays
        self.totalListenedSeconds = totalListenedSeconds
        self.topArtists = topArtists
        self.topGenres = topGenres
        self.topTracks = topTracks
        self.peakLocalHour = peakLocalHour
    }

    /// Reduces one window of a digest to the narration budget.
    ///
    /// Pure and order-preserving: the digest's lists are already totally ordered, so
    /// taking a prefix keeps the determinism ``ListeningDigestBuilder`` guarantees.
    public static func projecting(
        _ digest: ListeningWindowDigest,
        topLimit: Int = defaultTopLimit
    ) -> InsightNarrationContext {
        let limit = max(0, topLimit)
        return InsightNarrationContext(
            window: digest.window,
            totalPlays: digest.totalPlays,
            totalListenedSeconds: digest.totalListenedSeconds,
            topArtists: digest.topArtists.prefix(limit).map {
                AssistantNameCount(name: $0.name, count: $0.plays)
            },
            topGenres: digest.topGenres.prefix(limit).map {
                AssistantNameCount(name: $0.name, count: $0.plays)
            },
            topTracks: digest.topTracks.prefix(limit).map {
                InsightNarrationTrack(
                    title: $0.track.title,
                    artistName: $0.track.artistName,
                    plays: $0.plays
                )
            },
            peakLocalHour: peakHour(in: digest.hourHistogram)
        )
    }

    /// The busiest local hour, earliest-wins on a tie so the result is stable.
    ///
    /// Written as a strict-`>` walk rather than `max(by:)` on purpose: `max(by:)`
    /// returns the LAST maximal element, which would make two equally busy hours
    /// resolve to the later one for no stated reason.
    private static func peakHour(in histogram: [Int]) -> Int? {
        var peak: (hour: Int, plays: Int)?
        for (hour, plays) in histogram.enumerated() where plays > (peak?.plays ?? 0) {
            peak = (hour, plays)
        }
        return peak?.hour
    }
}

/// Writes a short prose narrative over a window's listening aggregates.
///
/// GENERATED CONTENT IS DATA — see ``PlaylistNamingResult``. The narrative is
/// produced in the requested locale and rendered `Text(verbatim:)`.
public protocol InsightNarrating: Sendable {
    /// - Parameters:
    ///   - context: The token-budgeted window projection. Never a full digest.
    ///   - locale: The language the narrative should be written in.
    func narrate(
        _ context: InsightNarrationContext,
        locale: Locale
    ) async throws -> InsightNarrationResult
}

/// A generated listening narrative.
///
/// A one-field struct rather than a bare `String` so the seam can grow a headline or
/// a confidence marker without changing three protocol signatures — and so the
/// "generated content is DATA" rule has a type to be documented on.
public struct InsightNarrationResult: Sendable, Equatable, Hashable {
    /// The prose narrative, trimmed. May be empty only if the conformer produced
    /// nothing, which callers treat as "no narrative", not as an error.
    public var narrative: String

    public init(narrative: String) {
        self.narrative = narrative.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
