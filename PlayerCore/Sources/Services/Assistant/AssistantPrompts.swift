// AssistantPrompts — the exact text a naming or narration request sends a model.
//
// Floor-available and PURE, deliberately: the FoundationModels island in
// `FMNamingNarrating.swift` builds the session, but the strings it sends are
// assembled here, so a token-budget test can measure the worst case on ANY host
// without a model, a session or Apple Intelligence. That is the same split
// ``AssistantLibraryContext/instructionsText(locale:)`` makes for the query tier.
//
// ── BOUNDED BY CONSTRUCTION ──────────────────────────────────────────────────
//
// ``PlaylistNamingContext`` and ``InsightNarrationContext`` enforce no caps of
// their own (``InsightNarrationContext/projecting(_:topLimit:)`` does, but a
// caller may build one by hand), so the caps live HERE. The policy matches
// ``AssistantLibraryContext`` exactly: a name over ``AssistantNamingPrompt/maxNameLength``
// is DROPPED rather than truncated, and the drop happens BEFORE the count cap.
//
// ── ENGLISH LABELS ARE CORRECT ───────────────────────────────────────────────
//
// "Genres:", "Plays:", "the last 7 days" and friends are prompt text for a model,
// not copy for a listener — nothing here reaches a screen. The language the ANSWER
// must be written in is named in the instructions instead, from the `locale`
// parameter the seams carry. Everything the user actually reads goes through
// ``AssistantStrings``.
import Foundation

/// The instructions and prompt text one naming request sends.
///
/// Pure and floor-available on purpose: a token-budget test measures the EXACT
/// strings production sends without building a session, the same way
/// ``AssistantLibraryContext/instructionsText(locale:)`` is measured.
public enum AssistantNamingPrompt {
    /// Ranked entries carried into a prompt. A draft's aggregates are already short,
    /// but the cap is enforced HERE so the prompt is bounded whatever a caller built.
    public static let maxRankedNames = 5
    /// Longest genre or artist name carried into a prompt. A longer one is DROPPED,
    /// never truncated — same policy and same reason as
    /// ``AssistantLibraryContext/maxNameLength``.
    public static let maxNameLength = 40

    public static func instructionsText(locale: Locale) -> String {
        [
            "You name music playlists.",
            "Answer with a short evocative name of at most six words, plus one short sentence describing it.",
            "Use ONLY the facts given. Never invent an artist, a genre or a year.",
            "Write both in \(locale.identifier).",
        ].joined(separator: "\n")
    }

    /// The draft's aggregates as labelled lines.
    ///
    /// English labels are correct here: this is prompt text for a model, not copy
    /// for a listener, and the requested OUTPUT language is named in the
    /// instructions instead.
    public static func promptText(for context: PlaylistNamingContext) -> String {
        var lines = ["Tracks: \(context.trackCount)"]
        if let genres = AssistantPromptFormatting.rankedLine(context.topGenres) {
            lines.append("Genres: \(genres)")
        }
        if let artists = AssistantPromptFormatting.rankedLine(context.topArtists) {
            lines.append("Artists: \(artists)")
        }
        if context.distinctArtistCount > 0 {
            lines.append("Distinct artists: \(context.distinctArtistCount)")
        }
        if let decade = context.dominantDecade {
            lines.append("Decade: \(decade)s")
        }
        if !context.moodTags.isEmpty {
            lines.append("Moods: \(context.moodTags.map(\.rawValue).joined(separator: ", "))")
        }
        return lines.joined(separator: "\n")
    }
}

/// The instructions and prompt text one narration request sends.
public enum AssistantNarrationPrompt {
    public static func instructionsText(locale: Locale) -> String {
        [
            "You summarise how someone has been listening to music.",
            "Answer with two or three short sentences. No lists, no headings, no markdown.",
            "Use ONLY the numbers given and state them exactly. Never invent a track, an artist or a genre.",
            "Write in \(locale.identifier).",
        ].joined(separator: "\n")
    }

    public static func promptText(for context: InsightNarrationContext) -> String {
        var lines = [
            "Period: \(windowLabel(context.window))",
            "Plays: \(context.totalPlays)",
            "Minutes listened: \(Int(min(max(context.totalListenedSeconds, 0) / 60, 1_000_000_000)))",
        ]
        if let artists = AssistantPromptFormatting.rankedLine(context.topArtists) {
            lines.append("Artists: \(artists)")
        }
        if let genres = AssistantPromptFormatting.rankedLine(context.topGenres) {
            lines.append("Genres: \(genres)")
        }
        if let tracks = trackLine(context.topTracks) {
            lines.append("Tracks: \(tracks)")
        }
        if let hour = context.peakLocalHour, (0 ..< 24).contains(hour) {
            lines.append("Busiest local hour: \(AssistantNarrationTemplates.hourToken(hour))")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Private

    private static func windowLabel(_ window: ListeningWindowKind) -> String {
        switch window {
        case .last7Days: "the last 7 days"
        case .last30Days: "the last 30 days"
        case .last12Months: "the last 12 months"
        case .allTime: "all time"
        }
    }

    private static func trackLine(_ tracks: [InsightNarrationTrack]) -> String? {
        let rendered = tracks
            .compactMap { track -> String? in
                let title = AssistantPromptFormatting.bounded(track.title)
                let artist = AssistantPromptFormatting.bounded(track.artistName)
                guard let title else { return nil }
                guard let artist else { return "\(title) (\(track.plays))" }
                return "\(title) by \(artist) (\(track.plays))"
            }
            .prefix(AssistantNamingPrompt.maxRankedNames)
        return rendered.isEmpty ? nil : rendered.joined(separator: ", ")
    }
}

/// Shared bounding for everything that goes into a prompt.
enum AssistantPromptFormatting {
    /// `"Rock (25), Jazz (10)"`, capped and with unknown-name buckets dropped.
    ///
    /// DROP FIRST, cap second — the same order as
    /// ``AssistantLibraryContext/bounded(_:limit:)``. Capping first would let one
    /// corrupt 5000-character tag SPEND a slot it is then dropped from, so the
    /// prompt would silently carry four genres where it advertises five.
    static func rankedLine(_ ranked: [AssistantNameCount]) -> String? {
        let rendered = ranked
            .compactMap { entry -> String? in
                guard let name = bounded(entry.name) else { return nil }
                return "\(name) (\(entry.count))"
            }
            .prefix(AssistantNamingPrompt.maxRankedNames)
        return rendered.isEmpty ? nil : rendered.joined(separator: ", ")
    }

    /// A trimmed name, or `nil` when it is empty or over the length cap.
    static func bounded(_ name: String?) -> String? {
        guard let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              trimmed.count <= AssistantNamingPrompt.maxNameLength
        else { return nil }
        return trimmed
    }
}
