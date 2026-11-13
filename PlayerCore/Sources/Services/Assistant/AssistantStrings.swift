// AssistantStrings — the localized TEMPLATE chrome the naming and narration
// fallbacks are assembled from.
//
// ── GENERATED CONTENT IS DATA (the decision this file exists to make precise) ──
//
// A generated name or narrative — whether it came from FoundationModels or from
// the templates below — is DATA once assembled. It is produced in the listener's
// language at generation time, PERSISTED (a name lands in `playlist.name`), and
// therefore does NOT re-localize when the app language changes. Shells render it
// with `Text(verbatim:)`. See ``PlaylistNamingResult`` and
// ``InsightNarrationResult``, which document the same rule on the types.
//
// What IS localized is only what this file holds: the template SHAPE. Every
// constant below is catalog chrome with holes in it. The values pushed into those
// holes — a genre name, an artist name, a decade, a play count — are DATA read
// verbatim out of the library, never translated. A fallback name is therefore a
// MIXED construction, and that is deliberate: "1990s Rock" must reorder in German
// ("Rock der 1990er") while "Rock" itself must not become "Fels".
//
// ── WHY WHOLE SENTENCES, NEVER ASSEMBLED FRAGMENTS ────────────────────────────
//
// Each key is a COMPLETE phrase or sentence with its arguments as positional
// placeholders, so a translator can reorder them. Concatenating localized
// fragments ("You played " + count + " tracks") is the classic i18n bug: it fixes
// English word order into every language. That is also why there are four separate
// `narrative.template.window*` keys rather than one sentence plus a localized
// window name — "in the last 7 days" is not a noun phrase in every language.
//
// KEY CONVENTION: `assistant.naming.*` / `assistant.narrative.*`, matching
// ``AssistantAvailabilityStrings`` (`assistant.availability.<case>`) and
// ``SeparationStrings`` (`separation.<area>.<case>`). PlayerCore ships NO String
// Catalog, so every key here MUST also exist in BOTH shell catalogs
// (`macOS/Sources/Localizable.xcstrings`, `iOS/Sources/Localizable.xcstrings`) or
// it renders its English `defaultValue` in every locale. They were synced in the
// same commit as this file with
// `.omo/evidence/local-ai-playlists/todo-13-sync-assistant-keys.py`.
import Foundation

/// Localized template chrome for ``AssistantNamingTemplates`` and
/// ``AssistantNarrationTemplates``.
///
/// Every member is either a constant (no holes) or a function taking the DATA that
/// fills its holes. Nothing here formats anything: the callers own the decision of
/// WHICH template applies, this type owns only WHAT it says.
public enum AssistantStrings {
    // MARK: Naming templates

    /// "1990s Rock" — the most specific naming case, and the reason word order has
    /// to be a translator's decision rather than a `+`.
    public static func nameGenreDecade(genre: String, decade: String) -> LocalizedStringResource {
        LocalizedStringResource(
            "assistant.naming.template.genreDecade",
            defaultValue: "\(decade)s \(genre)",
            comment: "Playlist name from a dominant genre and decade; 1 = decade like 1990, 2 = genre name"
        )
    }

    /// "Energetic Rock".
    public static func nameMoodGenre(mood: String, genre: String) -> LocalizedStringResource {
        LocalizedStringResource(
            "assistant.naming.template.moodGenre",
            defaultValue: "\(mood) \(genre)",
            comment: "Playlist name from a mood and a genre; 1 = localized mood word, 2 = genre name"
        )
    }

    /// "Rock Mix".
    public static func nameGenre(genre: String) -> LocalizedStringResource {
        LocalizedStringResource(
            "assistant.naming.template.genre",
            defaultValue: "\(genre) Mix",
            comment: "Playlist name from a genre alone; the argument is the genre name"
        )
    }

    /// "More Radiohead" — used only when the draft is effectively one artist.
    public static func nameArtist(artist: String) -> LocalizedStringResource {
        LocalizedStringResource(
            "assistant.naming.template.artist",
            defaultValue: "More \(artist)",
            comment: "Playlist name for a single-artist draft; the argument is the artist name"
        )
    }

    /// "1990s Mix".
    public static func nameDecade(decade: String) -> LocalizedStringResource {
        LocalizedStringResource(
            "assistant.naming.template.decade",
            defaultValue: "\(decade)s Mix",
            comment: "Playlist name from a decade alone; the argument is a decade like 1990"
        )
    }

    /// "Energetic Mix".
    public static func nameMood(mood: String) -> LocalizedStringResource {
        LocalizedStringResource(
            "assistant.naming.template.mood",
            defaultValue: "\(mood) Mix",
            comment: "Playlist name from a mood alone; the argument is a localized mood word"
        )
    }

    /// The last rung: a draft whose aggregates say nothing still gets a name.
    public static let nameGeneric = LocalizedStringResource(
        "assistant.naming.template.generic",
        defaultValue: "New Mix",
        comment: "Playlist name used when a draft's aggregates suggest no genre, artist, decade or mood"
    )

    /// "47 tracks · 12 artists" — the one-line description under a generated name.
    public static func nameSummary(trackCount: Int, artistCount: Int) -> LocalizedStringResource {
        LocalizedStringResource(
            "assistant.naming.description.summary",
            defaultValue: "\(trackCount) tracks · \(artistCount) artists",
            comment: "One-line playlist description; 1 = number of tracks, 2 = number of distinct artists"
        )
    }

    // MARK: Mood words

    /// The localized adjective for one ``PlaylistMoodTag``.
    ///
    /// A mood is a closed app vocabulary, not library data, so unlike a genre it IS
    /// translated. Written as a switch over the enum rather than a dictionary so a
    /// new mood is a compile error here (this repo's no-`default:` rule).
    public static func moodWord(_ mood: PlaylistMoodTag) -> LocalizedStringResource {
        switch mood {
        case .calm: moodCalm
        case .energetic: moodEnergetic
        case .dark: moodDark
        case .bright: moodBright
        }
    }

    static let moodCalm = LocalizedStringResource(
        "assistant.naming.mood.calm",
        defaultValue: "Calm",
        comment: "Mood adjective for low-energy music, used inside a generated playlist name"
    )
    static let moodEnergetic = LocalizedStringResource(
        "assistant.naming.mood.energetic",
        defaultValue: "Energetic",
        comment: "Mood adjective for high-energy music, used inside a generated playlist name"
    )
    static let moodDark = LocalizedStringResource(
        "assistant.naming.mood.dark",
        defaultValue: "Dark",
        comment: "Mood adjective for low-brightness music, used inside a generated playlist name"
    )
    static let moodBright = LocalizedStringResource(
        "assistant.naming.mood.bright",
        defaultValue: "Bright",
        comment: "Mood adjective for high-brightness music, used inside a generated playlist name"
    )

    // MARK: Narrative templates

    /// The opening sentence, one key per window — see the file header for why the
    /// window is not a substituted noun phrase.
    public static func narrativeWindow(_ window: ListeningWindowKind, plays: Int) -> LocalizedStringResource {
        switch window {
        case .last7Days: narrativeWindow7Days(plays: plays)
        case .last30Days: narrativeWindow30Days(plays: plays)
        case .last12Months: narrativeWindow12Months(plays: plays)
        case .allTime: narrativeWindowAllTime(plays: plays)
        }
    }

    static func narrativeWindow7Days(plays: Int) -> LocalizedStringResource {
        LocalizedStringResource(
            "assistant.narrative.template.window7Days",
            defaultValue: "You played \(plays) tracks in the last 7 days.",
            comment: "Opening line of the listening narrative for the 7-day window; the argument is a play count"
        )
    }

    static func narrativeWindow30Days(plays: Int) -> LocalizedStringResource {
        LocalizedStringResource(
            "assistant.narrative.template.window30Days",
            defaultValue: "You played \(plays) tracks in the last 30 days.",
            comment: "Opening line of the listening narrative for the 30-day window; the argument is a play count"
        )
    }

    static func narrativeWindow12Months(plays: Int) -> LocalizedStringResource {
        LocalizedStringResource(
            "assistant.narrative.template.window12Months",
            defaultValue: "You played \(plays) tracks in the last 12 months.",
            comment: "Opening line of the listening narrative for the 12-month window; the argument is a play count"
        )
    }

    static func narrativeWindowAllTime(plays: Int) -> LocalizedStringResource {
        LocalizedStringResource(
            "assistant.narrative.template.windowAllTime",
            defaultValue: "You have played \(plays) tracks in total.",
            comment: "Opening line of the listening narrative for the all-time window; the argument is a play count"
        )
    }

    /// Shown instead of everything else when the window recorded nothing.
    public static let narrativeEmpty = LocalizedStringResource(
        "assistant.narrative.template.empty",
        defaultValue: "Nothing has been played in this period yet.",
        comment: "The whole listening narrative when a window contains no plays at all"
    )

    /// "Radiohead led the way with 31 plays."
    public static func narrativeTopArtist(artist: String, plays: Int) -> LocalizedStringResource {
        LocalizedStringResource(
            "assistant.narrative.template.topArtist",
            defaultValue: "\(artist) led the way with \(plays) plays.",
            comment: "Listening narrative sentence; 1 = most-played artist name, 2 = that artist's play count"
        )
    }

    /// "Rock was your most-played genre."
    public static func narrativeTopGenre(genre: String) -> LocalizedStringResource {
        LocalizedStringResource(
            "assistant.narrative.template.topGenre",
            defaultValue: "\(genre) was your most-played genre.",
            comment: "Listening narrative sentence; the argument is the most-played genre name"
        )
    }

    /// "You listened most around 21:00." The clock token is a locale-neutral
    /// 24-hour string — see ``AssistantNarrationTemplates/hourToken(_:)``.
    public static func narrativePeakHour(hour: String) -> LocalizedStringResource {
        LocalizedStringResource(
            "assistant.narrative.template.peakHour",
            defaultValue: "You listened most around \(hour).",
            comment: "Listening narrative sentence; the argument is a 24-hour clock token such as 21:00"
        )
    }

    /// "That is about 9 hours of listening."
    public static func narrativeHours(hours: Int) -> LocalizedStringResource {
        LocalizedStringResource(
            "assistant.narrative.template.listeningHours",
            defaultValue: "That is about \(hours) hours of listening.",
            comment: "Listening narrative sentence; the argument is a whole number of hours"
        )
    }

    /// "That is about 12 minutes of listening."
    public static func narrativeMinutes(minutes: Int) -> LocalizedStringResource {
        LocalizedStringResource(
            "assistant.narrative.template.listeningMinutes",
            defaultValue: "That is about \(minutes) minutes of listening.",
            comment: "Listening narrative sentence used under one hour; the argument is a whole number of minutes"
        )
    }
}
