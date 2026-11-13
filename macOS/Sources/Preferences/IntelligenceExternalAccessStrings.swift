// IntelligenceExternalAccessStrings — the External Access section and its disclosure, in words.
//
// A SIXTH `PreferencesStrings` extension file, for the reason there are already five:
// `swiftlint --strict` caps a file at 400 lines and extension members do not count
// against the parent declaration, so every call site still reads
// `PreferencesStrings.<name>`.
//
// EVERY NUMBER IS A PARAMETER, as in the two disclosures before it. The per-lookup
// caps come from ``ToolProfile/external`` through ``ExternalAccessDisclosure``, and
// the port from the setting the listener chose. A privacy promise written twice is a
// privacy promise that will disagree with itself.
import Foundation

extension PreferencesStrings {
    // MARK: Section

    static let externalAccessSection = LocalizedStringResource(
        "app.preferences.intelligence.external.section",
        defaultValue: "External Access",
        comment: "Heading of the section that lets other programs on this Mac read the library"
    )

    static let externalAccessToggle = LocalizedStringResource(
        "app.preferences.intelligence.external.toggle",
        defaultValue: "Allow AI tools on this Mac to read your library",
        comment: "The switch that starts or stops the local server other programs connect to"
    )

    static let externalAccessCaption = LocalizedStringResource(
        "app.preferences.intelligence.external.caption",
        defaultValue:
        "Off by default. When on, MacAMP answers questions from AI tools running on this Mac only.",
        comment: "Caption under the external-access switch"
    )

    static let externalAccessReviewCaption = LocalizedStringResource(
        "app.preferences.intelligence.external.review.caption",
        defaultValue:
        "A connected tool can suggest a playlist. Nothing is saved until you review and apply it here.",
        comment: "Caption stating that an externally proposed playlist still needs in-app review"
    )

    static let externalAccessNeedsIntelligence = LocalizedStringResource(
        "app.preferences.intelligence.external.needsIntelligence",
        defaultValue: "Turn Intelligence features on to allow external access.",
        comment: "Caption explaining that the master Intelligence switch gates external access"
    )

    static let externalAccessPortLabel = LocalizedStringResource(
        "app.preferences.intelligence.external.port",
        defaultValue: "Port",
        comment: "Label for the field holding the local port the server listens on"
    )

    static let externalAccessPortCaption = LocalizedStringResource(
        "app.preferences.intelligence.external.port.caption",
        defaultValue: "Press Return to apply. If the port is taken, MacAMP says so rather than moving.",
        comment: "Caption under the port field"
    )

    static let externalAccessAddressLabel = LocalizedStringResource(
        "app.preferences.intelligence.external.address",
        defaultValue: "Address",
        comment: "Label for the read-only address an external tool should be pointed at"
    )

    static let externalAccessStatusLabel = LocalizedStringResource(
        "app.preferences.intelligence.external.status",
        defaultValue: "Status",
        comment: "Label for the row reporting whether the local server is serving"
    )

    static let externalAccessStatusStopped = LocalizedStringResource(
        "app.preferences.intelligence.external.status.stopped",
        defaultValue: "Not serving",
        comment: "Status: the local server is not listening"
    )

    static func externalAccessStatusRunning(port: Int) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.preferences.intelligence.external.status.running",
            defaultValue: "Serving on this Mac only, port \(port.formatted(.number.grouping(.never)))",
            comment: "Status: the local server is listening on the given loopback port"
        )
    }

    static func externalAccessStatusPortBusy(port: Int) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.preferences.intelligence.external.status.portBusy",
            defaultValue: "Port \(port.formatted(.number.grouping(.never))) is already in use — choose another",
            comment: "Status: the configured port could not be bound because something else holds it"
        )
    }

    static let externalAccessStatusFailed = LocalizedStringResource(
        "app.preferences.intelligence.external.status.failed",
        defaultValue: "Could not start",
        comment: "Status: the local server failed to start for a reason other than a busy port"
    )

    // MARK: Disclosure

    static let externalAccessConsentTitle = LocalizedStringResource(
        "app.preferences.intelligence.external.consent.title",
        defaultValue: "Let other programs on this Mac read your library?",
        comment: "Title of the sheet shown before external access may be switched on"
    )

    static let externalAccessConsentLead = LocalizedStringResource(
        "app.preferences.intelligence.external.consent.lead",
        defaultValue:
        "AI tools running on this Mac will be able to ask MacAMP about your music while this is on.",
        comment: "Lead sentence of the external-access disclosure"
    )

    static let externalAccessConsentPayloadHeading = LocalizedStringResource(
        "app.preferences.intelligence.external.consent.payload.heading",
        defaultValue: "A connected tool can ask for and receive:",
        comment: "Heading above the itemised list of what an external program may read"
    )

    static let externalAccessConsentNamesItem = LocalizedStringResource(
        "app.preferences.intelligence.external.consent.payload.names",
        defaultValue: "Track titles, artist names and album names from your library.",
        comment: "Payload item: the track metadata an external lookup can return"
    )

    static let externalAccessConsentFacetsItem = LocalizedStringResource(
        "app.preferences.intelligence.external.consent.payload.facets",
        defaultValue: "Genres, release years and playlist names.",
        comment: "Payload item: the descriptive facets an external lookup can return"
    )

    static let externalAccessConsentStatsItem = LocalizedStringResource(
        "app.preferences.intelligence.external.consent.payload.stats",
        defaultValue: "Your listening statistics — what you played, how often, and when.",
        comment: "Payload item: the listening aggregates an external lookup can return"
    )

    static let externalAccessConsentProposalsItem = LocalizedStringResource(
        "app.preferences.intelligence.external.consent.payload.proposals",
        defaultValue:
        "It can suggest a playlist, which appears in MacAMP for you to review. It cannot save one.",
        comment: "Payload item: an external program may file a proposal but never write to the library"
    )

    static let externalAccessConsentExclusions = LocalizedStringResource(
        "app.preferences.intelligence.external.consent.exclusions",
        defaultValue:
        "No audio, no file names or locations on disk, no artwork and no lyrics are ever sent.",
        comment: "States what an external program never receives"
    )

    static let externalAccessConsentIdentity = LocalizedStringResource(
        "app.preferences.intelligence.external.consent.identity",
        defaultValue:
        "MacAMP cannot tell which program is connected — any program running as you can, while this is on.",
        comment: "States plainly that connected programs are not identified or individually approved"
    )

    static let externalAccessConsentReversible = LocalizedStringResource(
        "app.preferences.intelligence.external.consent.reversible",
        defaultValue: "Turn this off in Preferences ▸ Intelligence at any time to close the connection.",
        comment: "States how to stop allowing external access"
    )

    static let externalAccessConsentAccept = LocalizedStringResource(
        "app.preferences.intelligence.external.consent.accept",
        defaultValue: "Allow External Access",
        comment: "Button accepting the external-access disclosure"
    )

    static let externalAccessConsentCancel = LocalizedStringResource(
        "app.preferences.intelligence.external.consent.cancel",
        defaultValue: "Not Now",
        comment: "Button declining the external-access disclosure"
    )

    static let externalAccessConsentAcceptHelp = LocalizedStringResource(
        "app.preferences.intelligence.external.consent.accept.help",
        defaultValue: "Start answering questions from AI tools running on this Mac.",
        comment: "Tooltip of the button accepting the external-access disclosure"
    )

    static let externalAccessConsentCancelHelp = LocalizedStringResource(
        "app.preferences.intelligence.external.consent.cancel.help",
        defaultValue: "Leave external access off. Nothing outside MacAMP can reach your library.",
        comment: "Tooltip of the button declining the external-access disclosure"
    )

    /// The reach of the connection, with the port the listener chose.
    static func externalAccessConsentLoopback(port: Int) -> LocalizedStringResource {
        let number = port.formatted(.number.grouping(.never))
        return LocalizedStringResource(
            "app.preferences.intelligence.external.consent.loopback",
            defaultValue: """
            The connection is limited to this Mac (127.0.0.1, port \(number)) \
            and is never reachable from your network.
            """,
            comment: "States that the local server is bound to loopback and unreachable from the network"
        )
    }

    /// One lookup's size, from ``ToolProfile/external``.
    static func externalAccessConsentSizeItem(rows: Int, characters: Int) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.preferences.intelligence.external.consent.payload.size",
            defaultValue: "At most \(rows.formatted()) results and \(characters.formatted()) characters per lookup.",
            comment: "Payload item: the row and character caps on one external lookup"
        )
    }
}
