// IntelligenceLibraryBrowsingConsentStrings — the library-browsing disclosure, in words.
//
// A FIFTH `PreferencesStrings` extension file, for the reason there are already four:
// `swiftlint --strict` caps a file at 400 lines, and extension members do not count
// against the parent declaration. Every call site still reads
// `PreferencesStrings.<name>`, so the split stays invisible to the views.
//
// EVERY NUMBER IS A PARAMETER, exactly as in `IntelligenceConsentStrings`. The caps
// are supplied by ``LibraryBrowsingDisclosure``, which forwards ``ToolProfile`` and
// ``ToolLoopEngine``. Spelling one out here would put a second copy of a privacy
// promise in the tree, and the copy the listener read is the one that binds.
//
// The provider's name is a BRAND and arrives as an interpolated value; the sheet
// never composes a sentence out of `Text(verbatim:)` fragments.
import Foundation

extension PreferencesStrings {
    // MARK: Chrome

    static let browsingConsentTitle = LocalizedStringResource(
        "app.preferences.intelligence.browsing.title",
        defaultValue: "Let this provider browse your library?",
        comment: "Title of the sheet shown before a cloud provider may look things up during a conversation"
    )

    static let browsingConsentAccept = LocalizedStringResource(
        "app.preferences.intelligence.browsing.accept",
        defaultValue: "Allow Browsing",
        comment: "Button accepting the library-browsing disclosure"
    )

    static let browsingConsentCancel = LocalizedStringResource(
        "app.preferences.intelligence.browsing.cancel",
        defaultValue: "Not Now",
        comment: "Button declining the library-browsing disclosure"
    )

    static let browsingConsentAcceptHelp = LocalizedStringResource(
        "app.preferences.intelligence.browsing.accept.help",
        defaultValue: "Agree to let this provider look things up in your library while it answers.",
        comment: "Tooltip of the button accepting the library-browsing disclosure"
    )

    static let browsingConsentCancelHelp = LocalizedStringResource(
        "app.preferences.intelligence.browsing.cancel.help",
        defaultValue: "Keep conversations off for this provider. Single requests still work.",
        comment: "Tooltip of the button declining the library-browsing disclosure"
    )

    // MARK: The disclosure

    static let browsingConsentPayloadHeading = LocalizedStringResource(
        "app.preferences.intelligence.browsing.payload.heading",
        defaultValue: "While it answers, it can ask for and receive:",
        comment: "Heading above the itemised list of what a cloud provider may look up during a conversation"
    )

    static let browsingConsentNamesItem = LocalizedStringResource(
        "app.preferences.intelligence.browsing.payload.names",
        defaultValue: "Track titles, artist names and album names from your library.",
        comment: "Payload item: the track metadata a library lookup can return"
    )

    static let browsingConsentFacetsItem = LocalizedStringResource(
        "app.preferences.intelligence.browsing.payload.facets",
        defaultValue: "Genres, release years and playlist names.",
        comment: "Payload item: the descriptive facets a library lookup can return"
    )

    static let browsingConsentStatsItem = LocalizedStringResource(
        "app.preferences.intelligence.browsing.payload.stats",
        defaultValue: "Your listening statistics — what you played, how often, and when.",
        comment: "Payload item: the listening aggregates a library lookup can return"
    )

    static let browsingConsentExclusions = LocalizedStringResource(
        "app.preferences.intelligence.browsing.exclusions",
        defaultValue:
        "No audio, no file names or locations on disk, no artwork and no lyrics are ever sent.",
        comment: "States what a cloud provider never receives during a conversation"
    )

    static let browsingConsentDefault = LocalizedStringResource(
        "app.preferences.intelligence.browsing.default",
        defaultValue: "Until you accept, this provider answers one request at a time and browses nothing.",
        comment: "States that the one-shot request path is unaffected while the disclosure is unaccepted"
    )

    static let browsingConsentReversible = LocalizedStringResource(
        "app.preferences.intelligence.browsing.reversible",
        defaultValue:
        "Choose Apple Intelligence in Preferences ▸ Intelligence at any time to keep everything on this Mac.",
        comment: "States how to stop using a cloud provider for conversations"
    )

    /// Who does the browsing. The value is the provider's own brand name.
    static func browsingConsentLead(provider: String) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.preferences.intelligence.browsing.lead",
            defaultValue: "To hold a conversation, \(provider) looks things up in your library while it answers.",
            comment: "Lead sentence naming the provider that would browse the library"
        )
    }

    /// One lookup's size, from ``ToolProfile/cloud``.
    static func browsingConsentSizeItem(rows: Int, characters: Int) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.preferences.intelligence.browsing.payload.size",
            defaultValue: "At most \(rows.formatted()) results and \(characters.formatted()) characters per lookup.",
            comment: "Payload item: the row and character caps on one library lookup"
        )
    }

    /// How many lookups one question may cost, from ``ToolLoopEngine``.
    static func browsingConsentRoundsItem(lookups: Int) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.preferences.intelligence.browsing.payload.rounds",
            defaultValue: "Up to \(lookups.formatted()) lookups for a single question.",
            comment: "Payload item: the cap on how many library lookups one question may cost"
        )
    }
}
