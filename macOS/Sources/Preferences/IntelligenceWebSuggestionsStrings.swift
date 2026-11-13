// IntelligenceWebSuggestionsStrings — the web-suggestions section, in words.
//
// Another `PreferencesStrings` extension file, for the reason there are already
// several: `swiftlint --strict` caps a file at 400 lines and extension members do
// not count against the parent declaration, so every call site still reads
// `PreferencesStrings.<name>` and the split stays invisible to the views. The
// `IntelligenceMCPStrings` / `IntelligenceMCPConsentStrings` pair is the pattern.
//
// The filename prefix is LOAD-BEARING, not decorative:
// `scripts/check-ai-network-boundary.sh` scans
// `macOS/Sources/Preferences/Intelligence*`, so a plausible-looking
// `PreferencesStrings+Web.swift` would carry this feature's copy — and any future
// code that drifted into it — outside the guard entirely.
//
// ── WHAT IS COPY HERE, AND WHAT IS DATA ──────────────────────────────────────
//
// "Tavily" and "YouTube" are BRANDS. They are never localized and never spelled out
// in a `defaultValue`; they arrive as arguments from ``WebSuggestionsDisclosure``
// and are interpolated into the templates below, exactly as an MCP server's own name
// is. That way a build that talks to a different service says so, in every language,
// without a copy edit.
//
// ── THE DISCLOSURE STATES THREE THINGS, DELIBERATELY ─────────────────────────
//
// What leaves (song titles and artists that are not in the library, to a search
// provider and to a video service), WHEN it can leave (only while a cloud provider
// is answering — the on-device path never has these tools), and what a key changes
// (nothing about what is sent; only the provider's rate limit). A listener who reads
// only the three payload rows has been told the whole of it.
import Foundation

extension PreferencesStrings {
    // MARK: Section chrome

    static let webSuggestionsSection = LocalizedStringResource(
        "app.preferences.intelligence.webSuggestions.section",
        defaultValue: "Web & Music Suggestions",
        comment: "Heading of the section that lets the assistant suggest music from outside your library"
    )

    static let webSuggestionsToggle = LocalizedStringResource(
        "app.preferences.intelligence.webSuggestions.toggle",
        defaultValue: "Suggest music beyond my library",
        comment: "Switch enabling the optional public-web lookups behind music suggestions"
    )

    static let webSuggestionsCaption = LocalizedStringResource(
        "app.preferences.intelligence.webSuggestions.caption",
        defaultValue: """
        Lets the assistant recommend songs you do not own yet, and attach a link to listen to each one.
        """,
        comment: "Caption explaining what the web-suggestions feature adds to the assistant"
    )

    static let webSuggestionsCloudOnlyCaption = LocalizedStringResource(
        "app.preferences.intelligence.webSuggestions.cloudOnly.caption",
        defaultValue: """
        Only used while a cloud provider is answering. The on-device assistant never looks anything up.
        """,
        comment: "Caption stating the feature is inert on the on-device assistant tier"
    )

    static let webSuggestionsNeedsIntelligence = LocalizedStringResource(
        "app.preferences.intelligence.webSuggestions.needsIntelligence",
        defaultValue: "Turn on Intelligence above to use web suggestions.",
        comment: "Caption shown when the master Intelligence switch is off and this section is inert"
    )

    static let webSuggestionsKeyFailed = LocalizedStringResource(
        "app.preferences.intelligence.webSuggestions.keyFailed",
        defaultValue: "That key could not be saved. Check that your Keychain is unlocked, then try again.",
        comment: "Caption shown when storing or removing an optional API key did not settle"
    )

    // MARK: The two optional keys

    static let webSuggestionsKeysHeading = LocalizedStringResource(
        "app.preferences.intelligence.webSuggestions.keys.heading",
        defaultValue: "Optional API keys",
        comment: "Sub-heading above the two optional API key fields"
    )

    static let webSuggestionsKeysCaption = LocalizedStringResource(
        "app.preferences.intelligence.webSuggestions.keys.caption",
        defaultValue: """
        Both services work without a key, at a limited rate. Adding your own key raises that limit; \
        it changes nothing about what is sent. Keys are kept in your Keychain.
        """,
        comment: "Caption explaining that the two API keys are optional and only raise rate limits"
    )

    static let webSuggestionsKeySaved = LocalizedStringResource(
        "app.preferences.intelligence.webSuggestions.keys.saved",
        defaultValue: "A key is already saved. Leave this blank to keep it.",
        comment: "Caption shown beside a key field when a key is already stored"
    )

    static let webSuggestionsKeyAbsent = LocalizedStringResource(
        "app.preferences.intelligence.webSuggestions.keys.absent",
        defaultValue: "No key saved — the rate-limited keyless mode is in use.",
        comment: "Caption shown beside a key field when no key is stored"
    )

    static let webSuggestionsSaveKey = LocalizedStringResource(
        "app.preferences.intelligence.webSuggestions.keys.save",
        defaultValue: "Save Key",
        comment: "Button storing the optional API key that was just typed"
    )

    static let webSuggestionsSaveKeyHelp = LocalizedStringResource(
        "app.preferences.intelligence.webSuggestions.keys.save.help",
        defaultValue: "Keep this key in your Keychain and use it for future lookups.",
        comment: "Tooltip of the button that stores an optional API key"
    )

    static let webSuggestionsRemoveKey = LocalizedStringResource(
        "app.preferences.intelligence.webSuggestions.keys.remove",
        defaultValue: "Remove Key",
        comment: "Button deleting a stored optional API key"
    )

    static let webSuggestionsRemoveKeyHelp = LocalizedStringResource(
        "app.preferences.intelligence.webSuggestions.keys.remove.help",
        defaultValue: "Delete this key from your Keychain and go back to the rate-limited keyless mode.",
        comment: "Tooltip of the button that deletes a stored optional API key"
    )

    /// The label of one key field. The PROVIDER is data; the sentence around it is
    /// copy, so a different search provider needs no new key here.
    static func webSuggestionsKeyLabel(_ slot: WebSuggestionsKeySlot, provider: String) -> LocalizedStringResource {
        switch slot {
        case .search:
            LocalizedStringResource(
                "app.preferences.intelligence.webSuggestions.keys.search.label",
                defaultValue: "\(provider) search key",
                comment: "Label of the optional API key field for the web search provider"
            )
        case .video:
            LocalizedStringResource(
                "app.preferences.intelligence.webSuggestions.keys.video.label",
                defaultValue: "\(provider) Data API key",
                comment: "Label of the optional API key field for the video service used to verify links"
            )
        }
    }
}

// MARK: - The disclosure

extension PreferencesStrings {
    static let webSuggestionsConsentTitle = LocalizedStringResource(
        "app.preferences.intelligence.webSuggestions.consent.title",
        defaultValue: "Look up music on the web?",
        comment: "Title of the disclosure shown before the web-suggestions feature is switched on"
    )

    static let webSuggestionsConsentLead = LocalizedStringResource(
        "app.preferences.intelligence.webSuggestions.consent.lead",
        defaultValue: """
        Turning this on lets the assistant recommend songs you do not own, and check that each link \
        it offers really plays.
        """,
        comment: "Lead paragraph of the web-suggestions disclosure"
    )

    static let webSuggestionsConsentHeading = LocalizedStringResource(
        "app.preferences.intelligence.webSuggestions.consent.heading",
        defaultValue: "While this is on:",
        comment: "Heading above the list of things the web-suggestions feature does"
    )

    /// What leaves, and to whom. The song text is the listener's own request turned
    /// into a query; the provider is a BRAND, interpolated verbatim.
    static func webSuggestionsConsentSearchItem(provider: String) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.preferences.intelligence.webSuggestions.consent.searchItem",
            defaultValue: """
            The titles and artists of songs that are not in your library are sent to the search \
            provider, \(provider), to find them.
            """,
            comment: "Disclosure row naming the search provider that receives song titles and artists"
        )
    }

    /// The second recipient, and the narrower reason it gets the same text.
    static func webSuggestionsConsentVideoItem(provider: String) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.preferences.intelligence.webSuggestions.consent.videoItem",
            defaultValue: """
            Those same titles and artists are sent to \(provider) to find and verify a link that \
            actually plays.
            """,
            comment: "Disclosure row naming the video service that receives song titles and artists"
        )
    }

    static let webSuggestionsConsentCloudOnlyItem = LocalizedStringResource(
        "app.preferences.intelligence.webSuggestions.consent.cloudOnlyItem",
        defaultValue: """
        This happens only while a cloud AI provider is selected. The on-device assistant is never \
        given these lookups, so nothing leaves this Mac on that setting.
        """,
        comment: "Disclosure row stating the feature is active only on the cloud tier, never on-device"
    )

    static let webSuggestionsConsentRateLimitItem = LocalizedStringResource(
        "app.preferences.intelligence.webSuggestions.consent.rateLimitItem",
        defaultValue: """
        Without a key, both services run in a rate-limited free mode. Adding your own key raises \
        those limits and changes nothing about what is sent.
        """,
        comment: "Disclosure row explaining keyless rate limits and what an optional key changes"
    )

    static let webSuggestionsConsentExclusions = LocalizedStringResource(
        "app.preferences.intelligence.webSuggestions.consent.exclusions",
        defaultValue: """
        Your files, file paths, playlists and listening history are never sent — only the song text \
        needed to search for a track.
        """,
        comment: "Note listing what the web-suggestions feature never sends"
    )

    static let webSuggestionsConsentReversible = LocalizedStringResource(
        "app.preferences.intelligence.webSuggestions.consent.reversible",
        defaultValue: "You can switch this off again at any time, and remove a saved key with it.",
        comment: "Note stating the web-suggestions grant is reversible"
    )

    static let webSuggestionsConsentAccept = LocalizedStringResource(
        "app.preferences.intelligence.webSuggestions.consent.accept",
        defaultValue: "Turn On",
        comment: "Button accepting the web-suggestions disclosure and enabling the feature"
    )

    static let webSuggestionsConsentAcceptHelp = LocalizedStringResource(
        "app.preferences.intelligence.webSuggestions.consent.accept.help",
        defaultValue: "Allow these lookups and switch web suggestions on.",
        comment: "Tooltip of the button accepting the web-suggestions disclosure"
    )

    static let webSuggestionsConsentCancel = LocalizedStringResource(
        "app.preferences.intelligence.webSuggestions.consent.cancel",
        defaultValue: "Not Now",
        comment: "Button refusing the web-suggestions disclosure, leaving the feature off"
    )

    static let webSuggestionsConsentCancelHelp = LocalizedStringResource(
        "app.preferences.intelligence.webSuggestions.consent.cancel.help",
        defaultValue: "Leave web suggestions off. Nothing is saved and nothing is sent.",
        comment: "Tooltip of the button refusing the web-suggestions disclosure"
    )
}
