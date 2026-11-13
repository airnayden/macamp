// EnrichmentStrings — user-facing copy for the macOS metadata-enrichment settings.
//
// A standalone enum (not an `extension MacAMPStrings`, which already sits at the
// SwiftLint `type_body_length` limit) following the per-feature `*Strings.swift`
// pattern used by `FileAccessStrings` / `PreferencesStrings`. Every label resolves
// through a `LocalizedStringResource` with an English `defaultValue`, so the
// running app and previews show real copy now and the dotted keys
// (`app.preferences.enrichment.*`) are the single handoff list for Task 44.
//
// "MusicBrainz" and "LRCLIB" are proper nouns (the online sources) and stay in the
// English copy. No copy embeds the "MacAMP" brand, so nothing here needs a verbatim
// brand token.
import Foundation

/// Localized copy for the library-pane metadata-enrichment section.
enum EnrichmentStrings {
    // MARK: Section + toggle

    static let sectionTitle = LocalizedStringResource(
        "app.preferences.enrichment.title",
        defaultValue: "Metadata Enrichment",
        comment: "Header of the section that auto-fills missing metadata and lyrics"
    )
    static let autoEnrichToggle = LocalizedStringResource(
        "app.preferences.enrichment.autoEnrich",
        defaultValue: "Auto-enrich imported tracks",
        comment: "Toggle that enriches newly imported tracks with online metadata and lyrics"
    )
    static let autoEnrichCaption = LocalizedStringResource(
        "app.preferences.enrichment.autoEnrich.caption",
        defaultValue: "Automatically fetches missing metadata and lyrics from MusicBrainz and LRCLIB after importing.",
        comment: "Explains what the auto-enrich toggle does"
    )

    // MARK: Live status

    static let enrichingTitle = LocalizedStringResource(
        "app.preferences.enrichment.enriching",
        defaultValue: "Enriching…",
        comment: "Status shown while an enrichment pass is running"
    )
    static let paused = LocalizedStringResource(
        "app.preferences.enrichment.paused",
        defaultValue: "Paused",
        comment: "Status shown while a running enrichment pass is suspended"
    )
    static let upToDate = LocalizedStringResource(
        "app.preferences.enrichment.upToDate",
        defaultValue: "Up to date",
        comment: "Idle status shown when no enrichment has run yet"
    )

    // MARK: Controls

    static let enrichNow = LocalizedStringResource(
        "app.preferences.enrichment.enrichNow",
        defaultValue: "Enrich Now",
        comment: "Button that starts a metadata-enrichment pass over the library"
    )
    static let pause = LocalizedStringResource(
        "app.preferences.enrichment.pause",
        defaultValue: "Pause",
        comment: "Button that suspends the running enrichment pass"
    )
    static let resume = LocalizedStringResource(
        "app.preferences.enrichment.resume",
        defaultValue: "Resume",
        comment: "Button that resumes a paused enrichment pass"
    )
    static let stop = LocalizedStringResource(
        "app.preferences.enrichment.stop",
        defaultValue: "Stop",
        comment: "Button that cancels the running enrichment pass"
    )

    // MARK: Counters (locale-grouped)

    /// "42 of 1,234" — the live completed/total counter beside the progress bar.
    static func count(completed: Int, total: Int) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.preferences.enrichment.count",
            defaultValue: "\(completed.formatted()) of \(total.formatted())",
            comment: "Live counter: tracks enriched so far out of the total to process"
        )
    }

    /// "1,234 tracks enriched" — the idle summary after a pass finishes or stops.
    static func enrichedSummary(count: Int) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.preferences.enrichment.summary",
            defaultValue: "\(count.formatted()) tracks enriched",
            comment: "Idle summary: how many tracks were enriched in the last pass"
        )
    }

    // MARK: Measured coverage (locale-grouped)

    /// "Lyrics for 12 of 340 tracks · 58 missing details" — what the library
    /// actually holds, shown instead of a last-pass tally when no pass has run.
    static func coverageSummary(
        withLyrics: Int,
        presentTracks: Int,
        missingDetails: Int
    ) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.preferences.enrichment.coverage.summary",
            defaultValue: """
            Lyrics for \(withLyrics.formatted()) of \(presentTracks.formatted()) tracks · \
            \(missingDetails.formatted()) missing details
            """,
            comment: "Idle summary: measured lyrics coverage and how many tracks still lack core tags"
        )
    }

    /// The same line plus the tracks a lyrics lookup genuinely came back empty for.
    /// Those are finished work, never "enriched", so they are counted apart.
    static func coverageSummaryProbed(
        withLyrics: Int,
        presentTracks: Int,
        noLyricsFound: Int,
        missingDetails: Int
    ) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.preferences.enrichment.coverage.summaryProbed",
            defaultValue: """
            Lyrics for \(withLyrics.formatted()) of \(presentTracks.formatted()) tracks · \
            \(noLyricsFound.formatted()) with no lyrics found · \(missingDetails.formatted()) missing details
            """,
            comment: "Idle summary variant that also reports tracks searched for lyrics with no result"
        )
    }
}
