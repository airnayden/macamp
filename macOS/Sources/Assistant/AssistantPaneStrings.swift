// Localized copy for the macOS Assistant pane and its sidebar section.
//
// The `app.assistant.*` namespace is deliberately NOT `assistant.*`: PlayerCore's
// `AssistantStrings` / `AssistantAvailabilityStrings` own that prefix, and the
// re-runnable key-sync checker under `.omo/evidence/` extracts every `assistant.*`
// key mechanically out of `PlayerCore/Sources`. Shell-only copy therefore keeps the
// shell's own `app.*` prefix (matching `MacAMPStrings`), so the two sets can never
// be confused for one another.
import Foundation

enum AssistantPaneStrings {
    static let sidebarSection = LocalizedStringResource(
        "app.assistant.sidebarSection",
        defaultValue: "Assistant",
        comment: "Sidebar section header above the local-AI assistant row"
    )
    static let title = LocalizedStringResource(
        "app.assistant.title",
        defaultValue: "Assistant",
        comment: "Sidebar row and window title for the local-AI assistant destination"
    )

    // MARK: Request field

    static let promptPlaceholder = LocalizedStringResource(
        "app.assistant.promptPlaceholder",
        defaultValue: "Describe a playlist — “upbeat 90s rock”",
        comment: "Placeholder inside the assistant request field"
    )
    static let promptLabel = LocalizedStringResource(
        "app.assistant.promptLabel",
        defaultValue: "Playlist request",
        comment: "Accessibility label for the assistant request field"
    )
    static let submit = LocalizedStringResource(
        "app.assistant.submit",
        defaultValue: "Suggest",
        comment: "Button that sends the typed request to the assistant"
    )
    static let submitHelp = LocalizedStringResource(
        "app.assistant.submitHelp",
        defaultValue: "Turn this request into a playlist you can review before it is saved",
        comment: "Tooltip on the assistant request button"
    )
    static let appleIntelligence = LocalizedStringResource(
        "app.assistant.appleIntelligence",
        defaultValue: "Enhanced by Apple Intelligence",
        comment: "Caption shown only while the on-device language model is available"
    )

    /// Both arguments are DATA interpolated into localized chrome and are never
    /// translated: `provider` is the connector's own brand name, `model` its wire
    /// identifier. The model is named beside the provider because the listener chose
    /// BOTH in the Intelligence pane, and "Powered by Anthropic Claude" alone cannot
    /// tell a Sonnet answer from an Opus one.
    static func poweredBy(provider: String, model: String) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.assistant.poweredBy",
            defaultValue: "Powered by \(provider) — \(model)",
            comment: "Caption naming the cloud AI provider and the model answering in the assistant pane"
        )
    }

    /// The same caption for a provider with no model chosen.
    ///
    /// A SEPARATE key rather than an empty `model` argument: a translator handed
    /// "Powered by Ollama — " has no way to know the trailing dash is a hole, and
    /// several languages need different punctuation once the second half is gone.
    static func poweredBy(provider: String) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.assistant.poweredByProvider",
            defaultValue: "Powered by \(provider)",
            comment: "Caption naming the cloud AI provider answering in the assistant pane, with no model chosen"
        )
    }

    // MARK: Feed

    static let autoMixesTitle = LocalizedStringResource(
        "app.assistant.autoMixesTitle",
        defaultValue: "Auto Mixes",
        comment: "Header above the automatically generated mix cards"
    )
    static let autoMixSubtitle = LocalizedStringResource(
        "app.assistant.autoMixSubtitle",
        defaultValue: "Refreshed from what you have been playing",
        comment: "Subtitle on an auto-mix suggestion card"
    )
    static let rediscoveryTitle = LocalizedStringResource(
        "app.assistant.rediscoveryTitle",
        defaultValue: "Rediscover",
        comment: "Header above the rediscovery mix cards"
    )
    static let rediscoverySubtitle = LocalizedStringResource(
        "app.assistant.rediscoverySubtitle",
        defaultValue: "Favourites you have not played in a while",
        comment: "Subtitle on a rediscovery suggestion card"
    )
    static let hygieneTitle = LocalizedStringResource(
        "app.assistant.hygieneTitle",
        defaultValue: "Library Health",
        comment: "Header above the library hygiene summary card"
    )
    static let hygieneIssues = LocalizedStringResource(
        "app.assistant.hygieneIssues",
        defaultValue: "Things worth reviewing",
        comment: "Title of the hygiene card when the library has findings; the count is shown beside it"
    )
    static let hygieneIssuesSubtitle = LocalizedStringResource(
        "app.assistant.hygieneIssuesSubtitle",
        defaultValue: "Duplicates, mixed genre spellings and missing tags",
        comment: "Subtitle listing what the hygiene pass looks for"
    )
    static let hygieneClean = LocalizedStringResource(
        "app.assistant.hygieneClean",
        defaultValue: "Your library looks tidy",
        comment: "Title of the hygiene card when the pass found nothing"
    )
    static let openPlaylist = LocalizedStringResource(
        "app.assistant.openPlaylist",
        defaultValue: "Open playlist",
        comment: "Accessibility label and tooltip for a suggestion card that opens its playlist"
    )

    // MARK: States

    static let loading = LocalizedStringResource(
        "app.assistant.loading",
        defaultValue: "Looking through your library…",
        comment: "Loading state while the suggestion feed is being built"
    )
    static let emptyTitle = LocalizedStringResource(
        "app.assistant.emptyTitle",
        defaultValue: "No Suggestions Yet",
        comment: "Empty state title when the assistant has nothing to show"
    )
    static let emptyMessage = LocalizedStringResource(
        "app.assistant.emptyMessage",
        defaultValue: "Add music and play a few tracks, or ask for a playlist above.",
        comment: "Empty state message when the assistant has nothing to show"
    )
    static let disabledTitle = LocalizedStringResource(
        "app.assistant.disabledTitle",
        defaultValue: "Intelligence Is Off",
        comment: "State shown when the assistant pane is reached while the Intelligence toggle is off"
    )
    static let disabledMessage = LocalizedStringResource(
        "app.assistant.disabledMessage",
        defaultValue: "Turn Intelligence on in Settings to get playlist suggestions.",
        comment: "Message telling the user where to switch the Intelligence feature back on"
    )

    // MARK: Request failures

    //
    // ONLY the outcomes `AssistantViewModel.submit` can actually reach get pane copy
    // of their own. The remaining ``AssistantProposalError`` cases describe APPLY-time
    // conditions that the request field cannot produce, and `ProposalPreviewStrings`
    // already words each of them for the surface that can — see
    // ``AssistantErrorCopy``, which stays exhaustive by borrowing those rather than
    // shipping a second English sentence per case for a state this pane cannot show.

    static let errorBannerLabel = LocalizedStringResource(
        "app.assistant.errorBannerLabel",
        defaultValue: "Request problem",
        comment: "Accessibility label for the banner explaining why a request produced no playlist"
    )
    static let errorNoMatchingTracks = LocalizedStringResource(
        "app.assistant.errorNoMatchingTracks",
        defaultValue: "Nothing in your library matched that request. Try different words, or add more music.",
        comment: "Banner shown when a request was understood but selected no playable tracks"
    )
    static let errorGenerationFailed = LocalizedStringResource(
        "app.assistant.errorGenerationFailed",
        defaultValue: "MacAMP couldn't read your library to build that suggestion. Nothing was changed.",
        comment: "Banner shown when a read failed while building a proposal"
    )

    // MARK: Provider fall-through notices

    static let noticeLabel = LocalizedStringResource(
        "app.assistant.noticeLabel",
        defaultValue: "Provider notice",
        comment: "Accessibility label for the notice saying which AI tier answered the last request"
    )
    static let noticeConnectorUnavailable = LocalizedStringResource(
        "app.assistant.noticeConnectorUnavailable",
        defaultValue: "Your AI provider couldn't be reached, so this was matched on your Mac instead.",
        comment: "Notice shown when the selected AI provider was not ready and a local tier answered"
    )
    static let noticeConnectorTimedOut = LocalizedStringResource(
        "app.assistant.noticeConnectorTimedOut",
        defaultValue: "Your AI provider didn't answer in time, so this was matched on your Mac instead.",
        comment: "Notice shown when the selected AI provider missed its deadline and a local tier answered"
    )
    static let noticeConnectorFailed = LocalizedStringResource(
        "app.assistant.noticeConnectorFailed",
        defaultValue: "Your AI provider returned an error, so this was matched on your Mac instead.",
        comment: "Notice shown when the selected AI provider threw and a local tier answered"
    )
    static let noticeModelFailed = LocalizedStringResource(
        "app.assistant.noticeModelFailed",
        defaultValue: "Apple Intelligence couldn't answer, so this was matched on your Mac instead.",
        comment: "Notice shown when the on-device model threw and the heuristic tier answered"
    )
    static let pendingTitle = LocalizedStringResource(
        "app.assistant.pendingTitle",
        defaultValue: "Waiting for you",
        comment: "Heading of the feed section listing proposals that have not been reviewed yet"
    )
    static let pendingSubtitle = LocalizedStringResource(
        "app.assistant.pendingSubtitle",
        defaultValue: "Suggested, not saved. Review it to decide.",
        comment: "Subtitle of a card for a proposal awaiting review"
    )
    static let pendingOpen = LocalizedStringResource(
        "app.assistant.pendingOpen",
        defaultValue: "Review",
        comment: "Action hint on a card that opens an un-reviewed proposal"
    )
    static let pendingUnnamed = LocalizedStringResource(
        "app.assistant.pendingUnnamed",
        defaultValue: "A change to review",
        comment: "Title of a pending proposal that carries no name of its own"
    )
}
