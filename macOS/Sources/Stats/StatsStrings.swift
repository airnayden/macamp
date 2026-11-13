// StatsStrings — user-facing copy for the macOS library-wide listening-statistics
// page (the Stats sidebar destination).
//
// A standalone enum (not an `extension MacAMPStrings`, which already sits at the
// SwiftLint `type_body_length` limit) following the per-feature `*Strings.swift`
// pattern of `EnrichmentStrings` / `PreferencesStrings`. Every entry resolves
// through a `LocalizedStringResource` with an English `defaultValue`, so the
// running app and previews show real copy now and the dotted `app.stats.*` keys
// are the single handoff list for translation.
//
// The right panel's per-track Stats tab keeps its own `StatsPanelStrings`; this
// enum covers only the library-wide page. Copy here is deliberately HONEST about
// which figures are windowed and which are lifetime — see `rawHorizonCaption` and
// `lifetimeCaption`, which exist so no number on the page can silently mislead.
import Foundation
import Services

/// Localized copy for the library-wide listening-statistics page.
enum StatsStrings {
    // MARK: Page chrome

    static let pageTitle = LocalizedStringResource(
        "app.stats.title",
        defaultValue: "Listening Stats",
        comment: "Title of the library-wide listening statistics page"
    )
    static let windowFilterLabel = LocalizedStringResource(
        "app.stats.windowFilter.label",
        defaultValue: "Period",
        comment: "Accessibility label for the control that picks which time span the statistics cover"
    )
    static let windowFilterHelp = LocalizedStringResource(
        "app.stats.windowFilter.help",
        defaultValue: "Choose the time span these statistics cover",
        comment: "Tooltip for the control that picks which time span the statistics cover"
    )

    // MARK: Time windows

    static let windowLast7Days = LocalizedStringResource(
        "app.stats.window.last7Days",
        defaultValue: "7 Days",
        comment: "Statistics period covering the last seven days"
    )
    static let windowLast30Days = LocalizedStringResource(
        "app.stats.window.last30Days",
        defaultValue: "30 Days",
        comment: "Statistics period covering the last thirty days"
    )
    static let windowLast12Months = LocalizedStringResource(
        "app.stats.window.last12Months",
        defaultValue: "12 Months",
        comment: "Statistics period covering the last twelve months"
    )
    static let windowAllTime = LocalizedStringResource(
        "app.stats.window.allTime",
        defaultValue: "All Time",
        comment: "Statistics period covering the whole retained history"
    )

    /// The segmented filter's label for one window, in `ListeningWindowKind`'s own
    /// declaration order.
    static func windowName(_ kind: ListeningWindowKind) -> LocalizedStringResource {
        switch kind {
        case .last7Days: windowLast7Days
        case .last30Days: windowLast30Days
        case .last12Months: windowLast12Months
        case .allTime: windowAllTime
        }
    }

    // MARK: Overview cards

    static let cardPlays = LocalizedStringResource(
        "app.stats.card.plays",
        defaultValue: "Plays",
        comment: "Overview card label: how many tracks were played in the selected period"
    )
    static let cardListeningTime = LocalizedStringResource(
        "app.stats.card.listeningTime",
        defaultValue: "Listening Time",
        comment: "Overview card label: how long the listener actually heard music in the selected period"
    )
    static let cardCompletion = LocalizedStringResource(
        "app.stats.card.completion",
        defaultValue: "Completion",
        comment: "Overview card label: what share of plays reached the end of the track"
    )
    static let cardSkipRate = LocalizedStringResource(
        "app.stats.card.skipRate",
        defaultValue: "Skip Rate",
        comment: "Overview card label: what share of plays the listener cut short"
    )

    // MARK: Group and section titles

    static let historyGroupTitle = LocalizedStringResource(
        "app.stats.group.history",
        defaultValue: "All Time & History",
        comment: "Heading of the page group whose figures ignore the selected period"
    )
    static let listeningClock = LocalizedStringResource(
        "app.stats.section.listeningClock",
        defaultValue: "Listening Clock",
        comment: "Section heading for the charts of when during the day and week music is played"
    )
    static let topSection = LocalizedStringResource(
        "app.stats.section.top",
        defaultValue: "Top",
        comment: "Section heading for the most-played tracks, artists and genres of the selected period"
    )
    static let topTracks = LocalizedStringResource(
        "app.stats.top.tracks",
        defaultValue: "Tracks",
        comment: "Sub-filter of the Top section showing the most played tracks"
    )
    static let topArtists = LocalizedStringResource(
        "app.stats.top.artists",
        defaultValue: "Artists",
        comment: "Sub-filter of the Top section showing the most played artists"
    )
    static let topGenres = LocalizedStringResource(
        "app.stats.top.genres",
        defaultValue: "Genres",
        comment: "Sub-filter of the Top section showing the most played genres"
    )
    static let mostReplayed = LocalizedStringResource(
        "app.stats.section.mostReplayed",
        defaultValue: "Most Replayed",
        comment: "Section heading for the tracks whose parts are replayed most often"
    )
    static let recentPlays = LocalizedStringResource(
        "app.stats.section.recentPlays",
        defaultValue: "Recent Plays",
        comment: "Section heading for the newest entries of the play history"
    )
    static let lifetimeMostPlayed = LocalizedStringResource(
        "app.stats.section.lifetimeMostPlayed",
        defaultValue: "Lifetime Most Played",
        comment: "Section heading for the all-time most played tracks, counted by the library's own play counters"
    )

    // MARK: Honesty captions

    /// Governs EVERY raw-only facet of the all-time view — the listening clock and
    /// the top lists alike — which is why it renders at the group header rather
    /// than beside a single section.
    ///
    /// The month is a bare `YYYY-MM` token (`ListeningDigest.rawHorizonYearMonth`)
    /// and is interpolated verbatim.
    static func rawHorizonCaption(month: String) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.stats.caption.rawHorizon",
            defaultValue: """
            Per-track and time-of-day detail covers plays since \(month); \
            artist and genre totals are all-time.
            """,
            comment: "Explains that some all-time figures only reach back to the month detailed history begins"
        )
    }

    static let lifetimeCaption = LocalizedStringResource(
        "app.stats.caption.lifetime",
        defaultValue: "All-time counts from your library's play counters — includes plays before detailed history began.",
        comment: "Explains that the lifetime most-played list comes from counters, not from the detailed history"
    )
    static let replayedCaption = LocalizedStringResource(
        "app.stats.caption.replayed",
        defaultValue: "All time — songs need three full listens, or one passage heard three times.",
        comment: "Explains the noise floor and the lifetime scope of the most-replayed list"
    )
    static let recentCaption = LocalizedStringResource(
        "app.stats.caption.recent",
        defaultValue: "Latest 50 plays.",
        comment: "Explains how many entries the recent-plays list shows"
    )
    static let topEmpty = LocalizedStringResource(
        "app.stats.top.empty",
        defaultValue: "Nothing played in this period yet.",
        comment: "Shown in place of a top list when the selected period has no plays"
    )

    // MARK: Shared fallbacks

    static let unknown = LocalizedStringResource(
        "app.stats.unknown",
        defaultValue: "Unknown",
        comment: "Placeholder for a track, artist or genre whose name was never recorded"
    )
}

// MARK: - Listening clock

/// Copy for the hour-of-day and day-of-week charts and their verdict caption.
///
/// Split into an extension purely for SwiftLint's `type_body_length` budget — every
/// entry belongs to the same `app.stats.*` key space and the same translation handoff
/// list as the main enum. The section HEADING (`listeningClock`) stays above.
extension StatsStrings {
    // MARK: Chart titles and axes

    static let clockHourTitle = LocalizedStringResource(
        "app.stats.clock.hourTitle",
        defaultValue: "By Hour of Day",
        comment: "Title of the chart showing how many tracks were played in each hour of the day"
    )
    static let clockWeekdayTitle = LocalizedStringResource(
        "app.stats.clock.weekdayTitle",
        defaultValue: "By Day of Week",
        comment: "Title of the chart showing how many tracks were played on each day of the week"
    )
    static let clockHourAxis = LocalizedStringResource(
        "app.stats.clock.axis.hour",
        defaultValue: "Hour",
        comment: "Name of the horizontal axis of the hour-of-day chart, read out by VoiceOver"
    )
    static let clockWeekdayAxis = LocalizedStringResource(
        "app.stats.clock.axis.weekday",
        defaultValue: "Day",
        comment: "Name of the horizontal axis of the day-of-week chart, read out by VoiceOver"
    )

    // MARK: Chart accessibility summaries

    /// Spoken summary of the hour chart, naming its tallest bar. The hour is a
    /// 24-hour-clock number so it reads back exactly as the axis labels it.
    static func clockHourPeak(hour: Int, plays: Int) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.stats.clock.hourTitle.peak",
            defaultValue: "Plays by hour of day. Busiest hour \(hour), \(plays) plays.",
            comment: "VoiceOver summary of the hour-of-day chart, naming its busiest hour"
        )
    }

    /// Spoken summary of the weekday chart, naming its tallest bar. The day arrives as
    /// the locale's own short weekday name.
    static func clockWeekdayPeak(day: String, plays: Int) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.stats.clock.weekdayTitle.peak",
            defaultValue: "Plays by day of week. Busiest day \(day), \(plays) plays.",
            comment: "VoiceOver summary of the day-of-week chart, naming its busiest day"
        )
    }

    // MARK: Dayparts

    static let daypartNight = LocalizedStringResource(
        "app.stats.daypart.night",
        defaultValue: "Night",
        comment: "Name of the block of local hours from midnight to 6 a.m."
    )
    static let daypartMorning = LocalizedStringResource(
        "app.stats.daypart.morning",
        defaultValue: "Morning",
        comment: "Name of the block of local hours from 6 a.m. to noon"
    )
    static let daypartAfternoon = LocalizedStringResource(
        "app.stats.daypart.afternoon",
        defaultValue: "Afternoon",
        comment: "Name of the block of local hours from noon to 6 p.m."
    )
    static let daypartEvening = LocalizedStringResource(
        "app.stats.daypart.evening",
        defaultValue: "Evening",
        comment: "Name of the block of local hours from 6 p.m. to midnight"
    )

    /// The name of one block of local hours, in ``ListeningDaypart``'s own order.
    static func daypartName(_ daypart: ListeningDaypart) -> LocalizedStringResource {
        switch daypart {
        case .night: daypartNight
        case .morning: daypartMorning
        case .afternoon: daypartAfternoon
        case .evening: daypartEvening
        }
    }

    /// The listening clock's one-line verdict.
    ///
    /// The name arrives already localized from ``daypartName(_:)``. A colon rather
    /// than a preposition keeps the sentence clear of the article and gender agreement
    /// a translated daypart name would otherwise force on every locale.
    static func mostActive(daypartName: String) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.stats.caption.mostActive",
            defaultValue: "Most active: \(daypartName)",
            comment: "Caption under the listening clock naming the busiest part of the day"
        )
    }
}

// MARK: - Top lists

/// Copy for the Top section's tracks / artists / genres sub-filter.
///
/// The three list NAMES (`topTracks`, `topArtists`, `topGenres`), the section
/// heading (`topSection`), the empty line (`topEmpty`) and the `unknown` fallback
/// all live in the main enum above — only the sub-picker's own chrome is here.
/// Split into an extension for the same `type_body_length` reason as the clock block.
extension StatsStrings {
    static let topCategoryLabel = LocalizedStringResource(
        "app.stats.top.category.label",
        defaultValue: "Top List",
        comment: "Accessibility label for the control that picks between top tracks, artists and genres"
    )
    static let topCategoryHelp = LocalizedStringResource(
        "app.stats.top.category.help",
        defaultValue: "Choose whether to rank tracks, artists or genres",
        comment: "Tooltip for the control that picks between top tracks, artists and genres"
    )
}

// MARK: - Most replayed

/// Copy for the Most Replayed rows. The section heading (`mostReplayed`), its
/// caption (`replayedCaption`) and the `unknown` fallback all live in the main enum
/// above; only the per-row metrics are here, split out for the same
/// `type_body_length` reason as the clock and top-list blocks.
extension StatsStrings {
    /// How many committed listening passes are folded into a row's heatmap.
    ///
    /// Inflected because the caption above the list talks in "full listens" and a row
    /// showing "3 full listen" would read as a typo. A row can legitimately show
    /// "1 full listen": the floor is `ReplayHeatAnalysis.hasTrustworthyShape`, which
    /// also admits a single sitting that replayed one passage. It is applied when the
    /// rows are ranked — never re-applied at the row.
    static func passes(count: Int) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.stats.replayed.passes",
            defaultValue: "^[\(count) full listen](inflect: true)",
            comment: "How many complete listens a most-replayed row's heatmap was built from"
        )
    }

    /// Names the bare percentage beside a most-replayed row, which is otherwise a
    /// number with no visible label — as a hover tooltip and as its spoken label.
    static let replayAffinity = LocalizedStringResource(
        "app.stats.replayed.affinity",
        defaultValue: "Replay affinity",
        comment: "Label for the percentage measuring how concentrated a track's replays are"
    )
}

// MARK: - Recent plays

/// Copy for the Recent Plays rows. The section heading (`recentPlays`), its
/// caption (`recentCaption`) and the `unknown` fallback all live in the main enum
/// above; only the skip marker is here, split out for the same
/// `type_body_length` reason as the clock, top-list and most-replayed blocks.
extension StatsStrings {
    /// Names the arrow glyph marking a play that was cut short.
    ///
    /// Used as BOTH the glyph's hover tooltip and its spoken label — it is a bare
    /// symbol with no visible text, so without this it would be a silent decoration
    /// to VoiceOver and a mystery to the pointer.
    ///
    /// "Skipped" is the recorder's own judgement — a user-driven transition away
    /// from a track heard less than halfway (`PlayEventRecorder.skipReasons` plus
    /// its completion threshold) — not merely "the next button was pressed".
    static let skippedBadge = LocalizedStringResource(
        "app.stats.recent.skipped",
        defaultValue: "Skipped",
        comment: "Label for the marker on a recent-plays row whose track was cut short"
    )
}
