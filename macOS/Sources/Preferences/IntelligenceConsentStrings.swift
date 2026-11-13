// IntelligenceConsentStrings — the connect-time payload disclosure, in words.
//
// A FOURTH strings file, for the reason the third one was split: `PreferencesStrings`
// is capped at 400 lines per file under `swiftlint --strict`, and it is already
// spread across `IntelligencePreferencesStrings`, `IntelligenceConnectorStrings` and
// `IntelligenceConnectorConfigStrings`. Declared as an extension, so every call site
// still reads `PreferencesStrings.<name>` and the split stays invisible to the views.
//
// ── EVERY NUMBER IS A PARAMETER, NEVER A LITERAL ───────────────────────────────
//
// The three caps are supplied by ``IntelligenceConsentDisclosure``, which forwards
// ``ConnectorPayloadBudget``. Spelling any of them out here as a literal would put a
// second copy of a privacy promise in the tree, and the copy the listener read is
// the one that binds — so the day the budget moves, this file moves with it.
//
// The provider's name is a BRAND and arrives as an interpolated `%@`; the sheet
// never composes a sentence out of `Text(verbatim:)` fragments.
import Foundation

extension PreferencesStrings {
    // MARK: Chrome

    static let connectorConsentTitle = LocalizedStringResource(
        "app.preferences.intelligence.consent.title",
        defaultValue: "Send requests to this provider?",
        comment: "Title of the sheet shown before a remote AI provider is used for the first time"
    )
    static let connectorConsentAccept = LocalizedStringResource(
        "app.preferences.intelligence.consent.accept",
        defaultValue: "Accept and Save",
        comment: "Button accepting the payload disclosure and committing the provider's setup"
    )
    static let connectorConsentCancel = LocalizedStringResource(
        "app.preferences.intelligence.consent.cancel",
        defaultValue: "Cancel",
        comment: "Button dismissing the payload disclosure without saving anything"
    )
    static let connectorConsentAcceptHelp = LocalizedStringResource(
        "app.preferences.intelligence.consent.accept.help",
        defaultValue: "Agree to send this information, then save this provider's setup.",
        comment: "Tooltip of the button accepting the payload disclosure"
    )
    static let connectorConsentCancelHelp = LocalizedStringResource(
        "app.preferences.intelligence.consent.cancel.help",
        defaultValue: "Leave this provider unconfigured and keep everything on this Mac.",
        comment: "Tooltip of the button declining the payload disclosure"
    )

    // MARK: The disclosure

    static let connectorConsentPayloadHeading = LocalizedStringResource(
        "app.preferences.intelligence.consent.payload.heading",
        defaultValue: "Each request carries exactly this, and nothing else:",
        comment: "Heading above the itemised list of what a request sends to a remote provider"
    )
    static let connectorConsentExclusions = LocalizedStringResource(
        "app.preferences.intelligence.consent.exclusions",
        defaultValue:
        "No audio, no files, no artwork, no lyrics, and no listening history are ever sent.",
        comment: "States what a remote provider never receives"
    )
    static let connectorConsentReversible = LocalizedStringResource(
        "app.preferences.intelligence.consent.reversible",
        defaultValue:
        "Choose Remove in this provider's setup at any time to go back to on-device Apple Intelligence.",
        comment: "States that the choice is reversible from the provider setup sheet"
    )
    static let connectorConsentDefault = LocalizedStringResource(
        "app.preferences.intelligence.consent.default",
        defaultValue: "Until you accept, MacAMP answers on this Mac and sends nothing.",
        comment: "States that the app stays on-device while the disclosure is unaccepted"
    )

    /// Who receives the request. `%@` is the provider's own brand name.
    static func connectorConsentLead(provider: String) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.preferences.intelligence.consent.lead",
            defaultValue: "What you type is sent to \(provider) over the internet and answered there.",
            comment: "Lead sentence naming the provider a request would be sent to"
        )
    }

    /// The listener's own words, capped at ``ConnectorPayloadBudget/maxRequestCharacters``.
    static func connectorConsentRequestItem(characters: Int) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.preferences.intelligence.consent.payload.request",
            defaultValue: "Your request, up to \(characters.formatted()) characters.",
            comment: "Payload item: the typed request text and its character cap"
        )
    }

    /// The answer vocabulary, capped at ``ConnectorPayloadBudget/maxGenres``.
    static func connectorConsentGenresItem(count: Int) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.preferences.intelligence.consent.payload.genres",
            defaultValue: "Up to \(count.formatted()) genre names from your library, as the list to choose from.",
            comment: "Payload item: the genre vocabulary and its count cap"
        )
    }

    /// The "more like this" hints, capped at ``ConnectorPayloadBudget/maxArtists``.
    static func connectorConsentArtistsItem(count: Int) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.preferences.intelligence.consent.payload.artists",
            defaultValue: "Up to \(count.formatted()) of your most-played artist names, with play counts.",
            comment: "Payload item: the artist aggregates and their count cap"
        )
    }
}
