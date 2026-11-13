// IntelligencePreferencesStrings — user-facing copy for the Intelligence pane.
//
// Split out of `PreferencesStrings` (which is close to the 400-line file ceiling)
// exactly as `KaraokePreferencesStrings` was, and declared as an extension so call
// sites keep reading `PreferencesStrings.<name>`. Same conventions as the parent:
// every label is a `LocalizedStringResource` with an English `defaultValue` and a
// dotted `app.preferences.intelligence.*` key, which is the single handoff list
// for translation.
//
// NOT declared here: the availability REASON messages. Those already exist as
// `AssistantAvailabilityStrings` in PlayerCore and are reached through
// `AssistantUnavailableReason.message`, so the pane renders the same sentence the
// rest of the app does rather than a second, drifting copy.
//
// "Apple Intelligence" is Apple's product name and stays as written in the English
// copy; the "MacAMP" brand never appears here, so no verbatim brand token is
// needed.
import Foundation
import Services

extension PreferencesStrings {
    // MARK: Tab + hero header

    static let tabIntelligence = LocalizedStringResource(
        "app.preferences.tab.intelligence",
        defaultValue: "Intelligence",
        comment: "Preferences tab: on-device AI features and audio analysis"
    )
    static let intelligenceSubtitle = LocalizedStringResource(
        "app.preferences.intelligence.subtitle",
        defaultValue: "On-device features that understand your library.",
        comment: "One-line subtitle under the Intelligence preferences pane title"
    )

    // MARK: Master switch

    static let intelligenceToggle = LocalizedStringResource(
        "app.preferences.intelligence.toggle",
        defaultValue: "Intelligence features",
        comment: "The single switch that turns every on-device AI feature on or off"
    )
    static let intelligenceCaptionRetired = LocalizedStringResource(
        "app.preferences.intelligence.caption.retired",
        defaultValue: "Choose a provider below. A local Ollama server keeps everything on this Mac.",
        comment: "Caption under the Intelligence master switch after Apple Intelligence was retired"
    )
    /// DEPRECATED: describes the retired Apple Intelligence tier.
    static let intelligenceCaption = LocalizedStringResource(
        "app.preferences.intelligence.caption",
        defaultValue: "Apple Intelligence runs on this Mac. Other providers use the network.",
        comment: "Distinguishes on-device Apple Intelligence from network-connected providers"
    )
    static let intelligenceOffNotice = LocalizedStringResource(
        "app.preferences.intelligence.offNotice",
        defaultValue: "Turning this off leaves the playlists you already made in place.",
        comment: "Reassures the user that disabling Intelligence never deletes generated playlists"
    )

    // MARK: Availability status

    /// Label of the status row when no provider is selected (Apple Intelligence retired).
    static let intelligenceStatusLabelNoProvider = LocalizedStringResource(
        "app.preferences.intelligence.status.noProvider",
        defaultValue: "AI provider",
        comment: "Label of the status row when no AI provider is selected"
    )
    static let intelligenceSubtitleRetired = LocalizedStringResource(
        "app.preferences.intelligence.subtitle.retired",
        defaultValue: "AI features that understand your library.",
        comment: "One-line subtitle under the Intelligence preferences pane title"
    )
    /// DEPRECATED: the Apple Intelligence row label, unused while the tier is retired.
    static let intelligenceStatusLabel = LocalizedStringResource(
        "app.preferences.intelligence.status",
        defaultValue: "Apple Intelligence",
        comment: "Label of the row reporting whether the on-device language model can run"
    )
    static let intelligenceStatusAvailable = LocalizedStringResource(
        "app.preferences.intelligence.status.available",
        defaultValue: "Ready on this device.",
        comment: "Status shown when the on-device language model is reachable and enabled"
    )
    static let intelligenceStatusFallback = LocalizedStringResource(
        "app.preferences.intelligence.status.fallback",
        defaultValue: "Requests still work — they are matched without the language model.",
        comment: "Explains that the heuristic tier keeps working when the on-device model is unavailable"
    )

    // MARK: Feature bundles

    static let intelligenceFeaturesSection = LocalizedStringResource(
        "app.preferences.intelligence.features",
        defaultValue: "Features",
        comment: "Header of the section listing the individual Intelligence feature switches"
    )

    /// The switch label for one feature bundle.
    static func intelligenceBundleLabel(_ bundle: AIFeatureBundle) -> LocalizedStringResource {
        switch bundle {
        case .nlCreation: intelligenceNLCreation
        case .autoMixes: intelligenceAutoMixes
        case .organization: intelligenceOrganization
        case .rediscovery: intelligenceRediscovery
        case .insights: intelligenceInsights
        case .hygiene: intelligenceHygiene
        }
    }

    /// The one-line explanation under one feature bundle's switch.
    static func intelligenceBundleCaption(_ bundle: AIFeatureBundle) -> LocalizedStringResource {
        switch bundle {
        case .nlCreation: intelligenceNLCreationCaption
        case .autoMixes: intelligenceAutoMixesCaption
        case .organization: intelligenceOrganizationCaption
        case .rediscovery: intelligenceRediscoveryCaption
        case .insights: intelligenceInsightsCaption
        case .hygiene: intelligenceHygieneCaption
        }
    }

    static let intelligenceNLCreation = LocalizedStringResource(
        "app.preferences.intelligence.nlCreation",
        defaultValue: "Playlists from a description",
        comment: "Switch label: create playlists by describing them in plain language"
    )
    static let intelligenceNLCreationCaption = LocalizedStringResource(
        "app.preferences.intelligence.nlCreation.caption",
        defaultValue: "Ask for something like “upbeat 90s rock” and review the result before it is saved.",
        comment: "Explains the natural-language playlist creation switch"
    )
    static let intelligenceAutoMixes = LocalizedStringResource(
        "app.preferences.intelligence.autoMixes",
        defaultValue: "Auto mixes",
        comment: "Switch label: standing generated mixes that refresh themselves"
    )
    static let intelligenceAutoMixesCaption = LocalizedStringResource(
        "app.preferences.intelligence.autoMixes.caption",
        defaultValue: "Keeps a few ready-made mixes up to date for the time of day.",
        comment: "Explains the auto-mixes switch"
    )
    static let intelligenceOrganization = LocalizedStringResource(
        "app.preferences.intelligence.organization",
        defaultValue: "Organization suggestions",
        comment: "Switch label: proposals for restructuring folders and playlists"
    )
    static let intelligenceOrganizationCaption = LocalizedStringResource(
        "app.preferences.intelligence.organization.caption",
        defaultValue: "Proposes tidier folders and playlists. Nothing moves until you accept it.",
        comment: "Explains the organization-suggestions switch"
    )
    static let intelligenceRediscovery = LocalizedStringResource(
        "app.preferences.intelligence.rediscovery",
        defaultValue: "Rediscovery",
        comment: "Switch label: surfaces forgotten favourites and never-played tracks"
    )
    static let intelligenceRediscoveryCaption = LocalizedStringResource(
        "app.preferences.intelligence.rediscovery.caption",
        defaultValue: "Brings back forgotten favourites and tracks you have never played.",
        comment: "Explains the rediscovery switch"
    )
    static let intelligenceInsights = LocalizedStringResource(
        "app.preferences.intelligence.insights",
        defaultValue: "Listening insights",
        comment: "Switch label: narrative summaries of listening history"
    )
    static let intelligenceInsightsCaption = LocalizedStringResource(
        "app.preferences.intelligence.insights.caption",
        defaultValue: "Turns your listening history into a short, readable summary.",
        comment: "Explains the listening-insights switch"
    )
    static let intelligenceHygiene = LocalizedStringResource(
        "app.preferences.intelligence.hygiene",
        defaultValue: "Library hygiene",
        comment: "Switch label: finds duplicates, inconsistent genres and missing tags"
    )
    static let intelligenceHygieneCaption = LocalizedStringResource(
        "app.preferences.intelligence.hygiene.caption",
        defaultValue: "Points out duplicates, inconsistent genres and missing tags.",
        comment: "Explains the library-hygiene switch"
    )

    // MARK: Audio analysis

    static let intelligenceAnalysisSection = LocalizedStringResource(
        "app.preferences.intelligence.analysis",
        defaultValue: "Audio Analysis",
        comment: "Header of the section that measures tempo, energy and brightness"
    )
    static let intelligenceAnalysisCaption = LocalizedStringResource(
        "app.preferences.intelligence.analysis.caption",
        defaultValue: "Measures tempo, energy and brightness so mixes and rules can use them. Runs only when you start it.",
        comment: "Explains what the audio-analysis pass does and that it never starts on its own"
    )
    static let intelligenceAnalysisStart = LocalizedStringResource(
        "app.preferences.intelligence.analysis.start",
        defaultValue: "Analyze Library",
        comment: "Button that starts the audio-analysis pass over the library"
    )
    static let intelligenceAnalysisStartHelp = LocalizedStringResource(
        "app.preferences.intelligence.analysis.startHelp",
        defaultValue: "Analyze only the tracks that have no up-to-date measurements yet",
        comment: "Tooltip on the incremental Analyze Library button"
    )
    static let intelligenceAnalysisRescan = LocalizedStringResource(
        "app.preferences.intelligence.analysis.rescan",
        defaultValue: "Re-analyze Library",
        comment: "Button that discards all cached measurements and analyzes the whole library again"
    )
    static let intelligenceAnalysisRescanHelp = LocalizedStringResource(
        "app.preferences.intelligence.analysis.rescanHelp",
        defaultValue: "Measure every track again, in case something was missed",
        comment: "Tooltip on the Re-analyze Library button"
    )
    static let intelligenceAnalysisRescanConfirmTitle = LocalizedStringResource(
        "app.preferences.intelligence.analysis.rescanConfirmTitle",
        defaultValue: "Re-analyze your whole library?",
        comment: "Title of the confirmation asked before a full re-analysis"
    )
    static let intelligenceAnalysisRescanConfirmMessage = LocalizedStringResource(
        "app.preferences.intelligence.analysis.rescanConfirmMessage",
        defaultValue: """
        This discards every measurement MacAMP has cached and decodes every audio file again. \
        On a large library it can take a long time. You can pause or stop it at any point, \
        and your music files are never changed.
        """,
        comment: "Honest description of what a full re-analysis costs, shown in the confirmation"
    )
    static let intelligenceAnalysisRescanConfirmAction = LocalizedStringResource(
        "app.preferences.intelligence.analysis.rescanConfirmAction",
        defaultValue: "Re-analyze",
        comment: "Destructive confirm button of the full re-analysis dialog"
    )
    static let intelligenceAnalysisRescanCancel = LocalizedStringResource(
        "app.preferences.intelligence.analysis.rescanCancel",
        defaultValue: "Cancel",
        comment: "Cancel button of the full re-analysis dialog"
    )
    static let intelligenceAnalysisRunning = LocalizedStringResource(
        "app.preferences.intelligence.analysis.running",
        defaultValue: "Analyzing…",
        comment: "Status shown while the audio-analysis pass is running"
    )
    static let intelligenceAnalysisPaused = LocalizedStringResource(
        "app.preferences.intelligence.analysis.paused",
        defaultValue: "Paused",
        comment: "Status shown while a running audio-analysis pass is suspended"
    )
    static let intelligenceAnalysisEmpty = LocalizedStringResource(
        "app.preferences.intelligence.analysis.empty",
        defaultValue: "Nothing to analyze yet — add music to your library first.",
        comment: "Coverage line shown when the library holds no analyzable tracks"
    )

    /// "34% analyzed — 340 of 1,000 tracks". Deliberately reads "analyzed", never
    /// "complete": a permanently undecodable file is retried by every pass and
    /// never counted, so this figure can legitimately sit below 100% forever.
    static func intelligenceAnalysisCoverage(
        percent: String,
        analyzed: Int,
        total: Int
    ) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.preferences.intelligence.analysis.coverage",
            defaultValue: "\(percent) analyzed — \(analyzed.formatted()) of \(total.formatted()) tracks",
            comment: "Coverage line: share of the library carrying current audio analysis"
        )
    }

    /// "3 tracks could not be analyzed" — the honest footnote behind a figure that
    /// never reaches 100%.
    static func intelligenceAnalysisSkipped(count: Int) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.preferences.intelligence.analysis.skipped",
            defaultValue: "\(count.formatted()) tracks could not be analyzed and are skipped.",
            comment: "Footnote explaining why the analyzed percentage stays below 100%"
        )
    }
}
