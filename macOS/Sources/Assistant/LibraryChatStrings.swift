// LibraryChatStrings — every word the conversation surface says.
//
// ── TOOL CAPTIONS ARE KEYED OFF THE NAME, NEVER OFF THE SUMMARY ──────────────
//
// `AssistantChatEvent.toolResult` carries the tool's own rendered text: English
// prose addressed to a MODEL, bounded by W1's tier budget, and explicitly NOT copy
// (W1 note 2, restated in the W3 contract). A shell that printed one to a person
// would ship untranslated model-facing text and would break the moment a tool
// rephrased itself. So the transcript renders a LOCALIZED caption chosen by the
// stable snake_case ``LibraryTool/name``, which is a wire format and safe to switch
// on, and the summary is never displayed at all.
//
// The switch below is over STRINGS, not over a Swift enum, because the tool registry
// is data — so it needs a default, and the default is an honest generic sentence
// rather than the raw name. `everyToolHasItsOwnCaption` pins that all ten shipped
// names resolve to their own caption, so a new tool arriving without copy is
// visible as a test failure rather than as a vague row.
import Foundation

enum LibraryChatStrings {
    // MARK: Chrome

    static let resetTitle = LocalizedStringResource(
        "app.assistant.chat.reset",
        defaultValue: "New Conversation",
        comment: "Button that clears the conversation and starts a fresh one"
    )

    static let resetHelp = LocalizedStringResource(
        "app.assistant.chat.reset.help",
        defaultValue: "Forget this conversation and start again.",
        comment: "Tooltip of the button that clears the conversation"
    )

    static let listenerLabel = LocalizedStringResource(
        "app.assistant.chat.role.you",
        defaultValue: "You",
        comment: "Accessibility role prefix for a message the listener sent"
    )

    static let assistantLabel = LocalizedStringResource(
        "app.assistant.chat.role.assistant",
        defaultValue: "Assistant",
        comment: "Accessibility role prefix for a message the assistant sent"
    )

    static let respondingLabel = LocalizedStringResource(
        "app.assistant.chat.responding",
        defaultValue: "Looking through your library…",
        comment: "Status shown while the assistant is answering"
    )

    static let activityLabel = LocalizedStringResource(
        "app.assistant.chat.activity",
        defaultValue: "Lookup",
        comment: "Accessibility role prefix for a row describing a library lookup the assistant made"
    )

    /// The action on a message bubble's context menu.
    ///
    /// Its own key rather than a reuse of ``suggestionCopyLink``: "Copy Link" names a
    /// web address and "Copy" names what was said, and a locale is free to translate
    /// the two apart — several inflect the verb by what is being copied.
    static let copyMessage = LocalizedStringResource(
        "app.assistant.chat.copyMessage",
        defaultValue: "Copy",
        comment: "Context-menu action that copies a conversation message's text to the clipboard"
    )

    /// The hover button's tooltip. The context-menu item deliberately takes no
    /// `.help` — an `NSMenu` row never receives `.onHover` — but this one is
    /// icon-only, so the exemption does not carry over to it.
    static let copyMessageHelp = LocalizedStringResource(
        "app.assistant.chat.copyMessage.help",
        defaultValue: "Copy this message to the clipboard.",
        comment: "Tooltip of the button that appears on a conversation message when the pointer is over it"
    )

    /// Confirmation after the hover button writes to the pasteboard: nothing else
    /// on screen changes, so without it a successful copy and a missed click look
    /// identical.
    static let copiedToast = LocalizedStringResource(
        "app.assistant.chat.copiedToast",
        defaultValue: "Copied",
        comment: "Toast confirming that a conversation message was copied to the clipboard"
    )

    // MARK: Per-turn notices

    static let truncatedNotice = LocalizedStringResource(
        "app.assistant.chat.truncated",
        defaultValue: "This answer stopped after the maximum number of lookups, so it may be incomplete.",
        comment: "Notice shown on a turn that used up its library-lookup budget before finishing"
    )

    // MARK: Why there is no conversation

    static let unavailableTitle = LocalizedStringResource(
        "app.assistant.chat.unavailable.title",
        defaultValue: "Conversations aren't available right now",
        comment: "Heading of the notice explaining that the assistant cannot hold a conversation"
    )

    static let unavailableOnDevice = LocalizedStringResource(
        "app.assistant.chat.unavailable.onDevice",
        defaultValue: """
        Your request was answered as a single question instead. \
        Choose a provider in Preferences ▸ Intelligence to talk about your library.
        """,
        comment: "Explains that the on-device tier cannot converse and points at the provider picker"
    )

    static let unavailableProviderCannotChat = LocalizedStringResource(
        "app.assistant.chat.unavailable.provider",
        defaultValue: """
        The provider you chose can't look things up in your library. \
        Pick another one in Preferences ▸ Intelligence.
        """,
        comment: "Explains that the selected provider cannot call tools and points at the provider picker"
    )

    static let unavailableNeedsModel = LocalizedStringResource(
        "app.assistant.chat.unavailable.model",
        defaultValue: "Choose a model for this provider in Preferences ▸ Intelligence, then ask again.",
        comment: "Explains that the selected provider has no model chosen and points at the model picker"
    )

    static let unavailableConsentDeclined = LocalizedStringResource(
        "app.assistant.chat.unavailable.declined",
        defaultValue: """
        You haven't allowed this provider to browse your library, so your request was answered as a \
        single question. Choose Apple Intelligence to talk about your library entirely on this Mac.
        """,
        comment: "Explains that the library-browsing agreement was declined and what still works"
    )

    // MARK: Proposals

    static let proposalCardHint = LocalizedStringResource(
        "app.assistant.chat.proposal.hint",
        defaultValue: "Review before saving",
        comment: "Hint on the card that opens a playlist the assistant proposed during a conversation"
    )

    /// How big the proposed playlist is. Inflected, so one track reads correctly.
    static func proposalCardSubtitle(count: Int) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.assistant.chat.proposal.subtitle",
            defaultValue: "^[\(count) track](inflect: true) — nothing is saved yet",
            comment: "Subtitle of a proposed-playlist card, stating its size and that it is not saved"
        )
    }

    // MARK: The track list a lookup answered with

    /// Reveals the rows past the first ten. Inflected, like every other count here.
    static func showAllTracks(count: Int) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.assistant.chat.rows.showAll",
            defaultValue: "Show all ^[\(count) track](inflect: true)",
            comment: "Button that expands a shortened list of tracks a library lookup found"
        )
    }

    // MARK: What the lookup could not find

    static let suggestionsHeader = LocalizedStringResource(
        "app.assistant.chat.suggestions.header",
        defaultValue: "Not in your library",
        comment: "Heading over the songs a lookup was asked for and could not find"
    )

    static func showAllSuggestions(count: Int) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.assistant.chat.suggestions.showAll",
            defaultValue: "Show all ^[\(count) song](inflect: true)",
            comment: "Button that expands a shortened list of songs the lookup could not find"
        )
    }

    static let suggestionHelp = LocalizedStringResource(
        "app.assistant.chat.suggestions.help",
        defaultValue: "Search for this on YouTube.",
        comment: "Tooltip of a link that searches the web for a song the library does not have"
    )

    /// Names what the link searches for, so VoiceOver reads more than "link".
    static func suggestionLabel(name: String) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.assistant.chat.suggestions.label",
            defaultValue: "Search the web for \(name)",
            comment: "Accessibility label of a link that searches the web for a song the library does not have"
        )
    }

    /// Marks a row that fell back to a search. Beside the name, never instead of
    /// it — a listener has to be able to tell a verified video from a guess at a
    /// glance, and colour alone is not a distinction anyone can rely on.
    static let suggestionSearchTag = LocalizedStringResource(
        "app.assistant.chat.suggestions.searchTag",
        defaultValue: "search",
        comment: "Small tag marking a row that links to a web search rather than to a specific video"
    )

    static let suggestionVideoHelp = LocalizedStringResource(
        "app.assistant.chat.suggestions.video.help",
        defaultValue: "Open this video on YouTube.",
        comment: "Tooltip of a link that opens one specific video for a song the library does not have"
    )

    /// Says WHICH kind of link this is, so VoiceOver distinguishes the two rows.
    static func suggestionVideoLabel(name: String) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.assistant.chat.suggestions.video.label",
            defaultValue: "Watch a video of \(name) on the web",
            comment: "Accessibility label of a link that opens one specific video for a song the library lacks"
        )
    }

    static let suggestionCopyLink = LocalizedStringResource(
        "app.assistant.chat.suggestions.copyLink",
        defaultValue: "Copy Link",
        comment: "Context-menu action that copies a suggestion's web address to the clipboard"
    )

    // MARK: Why an on-device conversation has no web links

    static let webPointerMessage = LocalizedStringResource(
        "app.assistant.chat.webPointer",
        defaultValue: "Web suggestions need a cloud provider — choose one in Settings ▸ Intelligence.",
        comment: "Notice telling an on-device listener why the web suggestions they turned on are not appearing"
    )

    static let webPointerDismiss = LocalizedStringResource(
        "app.assistant.chat.webPointer.dismiss",
        defaultValue: "Dismiss",
        comment: "Button that hides the notice about web suggestions needing a cloud provider"
    )
}

// MARK: - Tool captions

extension LibraryChatStrings {
    /// Every caption keyed by the wire name it belongs to.
    ///
    /// A table rather than a `switch` because the registry is data and grows: one
    /// `case` per tool is a branch SwiftLint counts, and the eleventh would trip
    /// `cyclomatic_complexity` on a function whose only job is a lookup.
    private static let toolCaptions: [String: LocalizedStringResource] = [
        "search_tracks": toolSearchTracks,
        "list_genres": toolListGenres,
        "get_tracks": toolGetTracks,
        "get_track_features": toolGetTrackFeatures,
        "get_listening_stats": toolGetListeningStats,
        "list_playlists": toolListPlaylists,
        "get_playlist": toolGetPlaylist,
        "sample_tracks": toolSampleTracks,
        "propose_playlist": toolProposePlaylist,
        "match_tracks": toolMatchTracks,
        "web_search": toolWebSearch,
    ]

    /// What the assistant did, in the listener's language, chosen by the tool's wire
    /// name. See this file's header for why the tool's own summary is never shown.
    static func toolCaption(for name: String) -> LocalizedStringResource {
        toolCaptions[name] ?? toolUnknown
    }

    /// How much the lookup found, appended after the caption.
    ///
    /// Inflected through automatic grammar agreement, the same mechanism
    /// ``proposalCardSubtitle(count:)`` uses, so "1 result" reads correctly in
    /// every locale without a plural table. The count itself is
    /// `ToolResult.resultCount` carried end to end — see the header of
    /// `LibraryChatToolCounts.swift`; nothing here counts anything.
    static func toolResultCount(_ count: Int) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.assistant.chat.tool.resultCount",
            defaultValue: "— ^[\(count) result](inflect: true)",
            comment: "Suffix on a library-lookup row stating how many results the lookup found"
        )
    }

    static func lookupSummary(count: Int) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.assistant.chat.lookups.summary",
            defaultValue: "^[\(count) lookup](inflect: true) behind this answer",
            comment: "Collapsed disclosure summarising the library lookups a chat answer used; expanding shows each one"
        )
    }

    /// The SF Symbol beside a lookup row. Decorative — never the accessible name.
    static func toolSymbol(for name: String) -> String {
        switch name {
        case "search_tracks": "magnifyingglass"
        case "list_genres", "get_playlist", "list_playlists": "list.bullet"
        case "get_tracks", "sample_tracks": "music.note"
        case "match_tracks": "checklist"
        case "get_track_features": "waveform"
        case "get_listening_stats": "chart.bar"
        case "propose_playlist": "wand.and.stars"
        case "web_search": "globe"
        default: "sparkles"
        }
    }

    static let toolSearchTracks = LocalizedStringResource(
        "app.assistant.chat.tool.searchTracks",
        defaultValue: "Searched your library",
        comment: "Caption for the search_tracks library lookup"
    )

    static let toolListGenres = LocalizedStringResource(
        "app.assistant.chat.tool.listGenres",
        defaultValue: "Read your genre list",
        comment: "Caption for the list_genres library lookup"
    )

    static let toolGetTracks = LocalizedStringResource(
        "app.assistant.chat.tool.getTracks",
        defaultValue: "Looked up track details",
        comment: "Caption for the get_tracks library lookup"
    )

    static let toolGetTrackFeatures = LocalizedStringResource(
        "app.assistant.chat.tool.getTrackFeatures",
        defaultValue: "Checked tempo and energy",
        comment: "Caption for the get_track_features library lookup"
    )

    static let toolGetListeningStats = LocalizedStringResource(
        "app.assistant.chat.tool.getListeningStats",
        defaultValue: "Read your listening history",
        comment: "Caption for the get_listening_stats library lookup"
    )

    static let toolListPlaylists = LocalizedStringResource(
        "app.assistant.chat.tool.listPlaylists",
        defaultValue: "Listed your playlists",
        comment: "Caption for the list_playlists library lookup"
    )

    static let toolGetPlaylist = LocalizedStringResource(
        "app.assistant.chat.tool.getPlaylist",
        defaultValue: "Opened one of your playlists",
        comment: "Caption for the get_playlist library lookup"
    )

    static let toolSampleTracks = LocalizedStringResource(
        "app.assistant.chat.tool.sampleTracks",
        defaultValue: "Picked candidates from your library",
        comment: "Caption for the sample_tracks library lookup"
    )

    static let toolProposePlaylist = LocalizedStringResource(
        "app.assistant.chat.tool.proposePlaylist",
        defaultValue: "Put a playlist together for you to review",
        comment: "Caption for the propose_playlist action"
    )

    static let toolMatchTracks = LocalizedStringResource(
        "app.assistant.chat.tool.matchTracks",
        defaultValue: "Matched a list of tracks against your library",
        comment: "Caption for the match_tracks library lookup"
    )

    /// The one caption that is NOT about the library. Without it `web_search` — the
    /// first non-library tool the merge publishes — falls to ``toolUnknown`` and
    /// tells a listener their library was searched when the web was.
    static let toolWebSearch = LocalizedStringResource(
        "app.assistant.chat.tool.webSearch",
        defaultValue: "Searched the web",
        comment: "Caption for the web_search lookup, the one tool that does not read the listener's library"
    )

    static let toolUnknown = LocalizedStringResource(
        "app.assistant.chat.tool.unknown",
        defaultValue: "Looked something up in your library",
        comment: "Caption for a library lookup this version of the app has no specific wording for"
    )
}
