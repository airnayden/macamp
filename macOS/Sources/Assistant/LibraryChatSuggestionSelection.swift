// LibraryChatSuggestionSelection — picking the songs a lookup could not find, and what
// asking for them carries.
//
// The selection machinery of ``LibraryChatSuggestionList`` lives here rather than beside
// the list: that file is at 268 lines against SwiftLint's strict 400-line ceiling, and
// this is a whole second surface — a per-row tick, a button, two captions and the payload
// they produce.
//
// ── A TICK IS KEYED BY WHAT THE ROW MEANS, NOT BY WHERE IT SITS ──────────────
//
// Selection is a `Set<String>` of ROW KEYS — never ``LinkableSuggestion/id``, which is a
// transient enumeration OFFSET; never the row index; never the suggestion's value.
// Enrichment rewrites a turn's suggestions in place after it lands — a link appears, a
// row's identity changes — and any of those three keys would silently re-point a tick at
// a different song. A row key means the same thing before and after that pass.
//
// ── AMENDED: EVERY ROW IS PICKABLE, AND A KEY IS NOT ALWAYS AN ID ────────────
//
// This header used to claim that a tick was ALWAYS a canonical 11-character video id,
// and that a row the normalizer could not key therefore got NO checkbox. Both halves are
// RETIRED. A verified row still keys by its canonical id, but a row that names no
// verified video now keys by the two strings it WAS named by —
// `"q:<folded title>|<folded artist>"`, see ``LibraryChatSuggestionList/rowKey(_:)`` —
// and is picked like any other. Refusing the tick only ever meant the listener could not
// ask for the song at all; resolving it at download time is strictly more useful than
// hiding it, and that is what ``ChatDownloadRequest/unresolved`` carries.
//
// The one row that still gets NO checkbox is the one with no title to look up: every
// such row would fold to the same degenerate `"q:|"`, so one tick would silently select
// all of them. That guard lives in ``LibraryChatSuggestionList/selectableKey(_:)``.
//
// ── THE LIST NEVER LOOKS ANYTHING UP ─────────────────────────────────────────
//
// Both closures are INJECTED props. The list does not read `AppEnvironment`, does not
// touch the database, and does not consult settings: ``ChatDownloadRequest`` is built
// from the props the row already carries, and the import preview is a closure the
// composition root supplies. That is what lets the composition suite drive the whole
// surface with recorders, and it is what keeps a SwiftUI `body` free of I/O.
import DesignSystem
import Services
import SwiftUI

/// A picked row that names no verified video: the key it was ticked under, and the two
/// strings a lookup has to go on.
///
/// Both strings are carried because the consumer looks the song UP, and
/// ``LinkableSuggestion/name`` cannot be split back into them. The key travels alongside
/// so the consumer can report each lookup's progress back to the row that asked for it,
/// which is a row it can no longer address any other way.
struct ChatDownloadCandidate: Equatable {
    /// The row key this candidate was ticked under — see
    /// ``LibraryChatSuggestionList/rowKey(_:)``.
    let key: String
    /// The miss's own title, verbatim. What a lookup searches for.
    let title: String
    /// The miss's own artist, verbatim, or `nil` when the miss named none.
    let artist: String?
}

/// What one press of "Download selected" asks for: WHICH songs, and WHERE they land.
///
/// Two lists rather than one, because the two cost different things. A verified id goes
/// straight to the downloader; a candidate has to be LOOKED UP first, over the network,
/// and may not resolve at all. Folding candidates into ``videoIDs`` would mean putting
/// ids there that do not exist yet.
struct ChatDownloadRequest: Equatable {
    /// The picked videos that were already verified, in the order the list draws them,
    /// each appearing once.
    let videoIDs: [String]
    /// The picked rows that name no verified video, in that same draw order, each key
    /// appearing once.
    let unresolved: [ChatDownloadCandidate]
    /// The playlist the turn established, or `nil` for a plain download.
    let appendTarget: SuggestionAppendTarget?
    /// The profile a ``SuggestionAppendTarget/playlist(_:)`` target was read as.
    let appendProfileId: Int64?

    /// Spelled out rather than synthesized so ``unresolved`` can default to empty: a
    /// caller that only ever has verified ids — the re-entry a resolver makes, and every
    /// site that predates candidates — still reads as the three-field request it was.
    init(
        videoIDs: [String],
        unresolved: [ChatDownloadCandidate] = [],
        appendTarget: SuggestionAppendTarget?,
        appendProfileId: Int64?
    ) {
        self.videoIDs = videoIDs
        self.unresolved = unresolved
        self.appendTarget = appendTarget
        self.appendProfileId = appendProfileId
    }
}

// MARK: - Derivation (static so the composition suite can drive it)

extension LibraryChatSuggestionList {
    /// The key this row's tick would carry, or `nil` when the row draws no tick — the
    /// per-row half of ``showsDownloadControls(_:isEnabled:)``, kept here so both halves
    /// of the gate change together.
    static func rowSelectionKey(_ suggestion: LinkableSuggestion, isEnabled: Bool) -> String? {
        guard isEnabled else { return nil }
        return selectableKey(suggestion)
    }

    /// Every key this list can be asked for, in draw order, each once.
    ///
    /// De-duplicated because two rows can mean the same song (the same miss suggested
    /// twice, or a remaster whose link is the original's): they share one tick and must
    /// produce one download.
    static func selectableKeys(_ suggestions: [LinkableSuggestion]) -> [String] {
        var seen: Set<String> = []
        return suggestions.compactMap { suggestion in
            guard let key = selectableKey(suggestion), seen.insert(key).inserted else {
                return nil
            }
            return key
        }
    }

    /// The ticked keys that are still on offer, in draw order.
    ///
    /// The intersection is the whole point: selection state outlives the rows it was made
    /// on (enrichment rewrites them), so a key the list no longer offers is DROPPED here
    /// rather than sent to the downloader.
    static func selectedKeys(_ selected: Set<String>, in suggestions: [LinkableSuggestion]) -> [String] {
        selectableKeys(suggestions).filter(selected.contains)
    }

    /// How many songs the button says it will download.
    ///
    /// Counted against the WHOLE list, never the visible window, so folding rows behind
    /// the expander does not silently shrink the number the listener is looking at.
    static func selectedCount(_ selected: Set<String>, in suggestions: [LinkableSuggestion]) -> Int {
        selectedKeys(selected, in: suggestions).count
    }

    /// Nothing ticked, nothing to ask for.
    static func canDownload(selectedCount: Int) -> Bool {
        selectedCount > 0
    }

    /// The payload one press produces, with the ticked rows split by what they cost.
    ///
    /// Walks the list rather than the selection so both lists come out in DRAW order, and
    /// carries its own `seen` set so a key two rows share contributes once — the same
    /// reason ``selectableKeys(_:)`` de-duplicates.
    static func request(
        selected: Set<String>,
        in suggestions: [LinkableSuggestion],
        appendTarget: SuggestionAppendTarget?,
        appendProfileId: Int64?
    ) -> ChatDownloadRequest {
        let picked = Set(selectedKeys(selected, in: suggestions))
        var videoIDs: [String] = []
        var unresolved: [ChatDownloadCandidate] = []
        var seen: Set<String> = []
        for suggestion in suggestions {
            guard let key = selectableKey(suggestion), picked.contains(key), seen.insert(key).inserted else {
                continue
            }
            if let videoID = verifiedVideoID(suggestion) {
                videoIDs.append(videoID)
            } else {
                unresolved.append(
                    ChatDownloadCandidate(key: key, title: suggestion.title, artist: suggestion.artist)
                )
            }
        }
        return ChatDownloadRequest(
            videoIDs: videoIDs,
            unresolved: unresolved,
            appendTarget: appendTarget,
            appendProfileId: appendProfileId
        )
    }

    /// Whether this list draws checkboxes, a button and their captions at all.
    ///
    /// Two conditions: somebody is listening (`isEnabled`, i.e. a non-`nil` handler), and
    /// at least one row can actually be picked. Only a list whose every row is untitled
    /// draws none of it.
    static func showsDownloadControls(_ suggestions: [LinkableSuggestion], isEnabled: Bool) -> Bool {
        isEnabled && !selectableKeys(suggestions).isEmpty
    }

    /// States that these downloads join no playlist, when that is the case.
    static func showsNoPlaylistCaption(
        _ suggestions: [LinkableSuggestion],
        isEnabled: Bool,
        appendTarget: SuggestionAppendTarget?
    ) -> Bool {
        showsDownloadControls(suggestions, isEnabled: isEnabled) && appendTarget == nil
    }

    /// Warns that a finished download would not reach the library.
    ///
    /// Advisory: the preview reads cached state, while the authoritative check runs when
    /// the download finishes. The two deliberately read different sources.
    static func showsImportWarning(
        _ suggestions: [LinkableSuggestion],
        isEnabled: Bool,
        isImportConfigured: @autoclosure () -> Bool
    ) -> Bool {
        showsDownloadControls(suggestions, isEnabled: isEnabled) && !isImportConfigured()
    }

    /// Addressed by the key the tick MEANS, so a UI test names a song rather than a
    /// position — the same reason the link rows carry their kind.
    static func selectionIdentifier(prefix: String, rowKey: String) -> String {
        "\(prefix).select.\(rowKey)"
    }

    static func downloadIdentifier(prefix: String) -> String {
        "\(prefix).downloadSelected"
    }
}

// MARK: - The per-row tick

/// The checkbox beside a verified row.
///
/// A native `.checkbox` toggle rather than a drawn glyph, so it inherits the platform's
/// own hit target, focus ring and VoiceOver contract — the same choice, for the same
/// reason, as `ProposalPreviewSections.includeToggle`.
struct ChatSuggestionSelectionToggle: View {
    let rowKey: String
    /// The row's display name, spoken so VoiceOver says WHICH song is being ticked.
    let name: String
    let identifierPrefix: String
    @Binding var isSelected: Bool

    var body: some View {
        Toggle(isOn: $isSelected) { EmptyView() }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .pointingHandCursor()
            .help(Text(LibraryChatStrings.downloadSelectHelp))
            .accessibilityLabel(Text(LibraryChatStrings.downloadSelectLabel(name: name)))
            .accessibilityIdentifier(
                LibraryChatSuggestionList.selectionIdentifier(prefix: identifierPrefix, rowKey: rowKey)
            )
    }
}

// MARK: - The action

/// "Download selected (N)", trailing the list.
///
/// `.borderedProminent` rather than the accent-tinted `.plain` label this used to be: a
/// plain-styled label reads as prose and was missed, so the batch action takes the
/// platform's own filled control, hit target and focus ring.
struct ChatSuggestionDownloadButton: View {
    let count: Int
    let identifierPrefix: String
    let action: () -> Void

    var body: some View {
        let isEnabled = LibraryChatSuggestionList.canDownload(selectedCount: count)
        let button = Button(action: action) {
            Label {
                Text(LibraryChatStrings.downloadSelected(count: count))
            } icon: {
                Image(systemName: "arrow.down.circle")
            }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .disabled(!isEnabled)
        .help(Text(LibraryChatStrings.downloadSelectedHelp))
        .accessibilityLabel(Text(LibraryChatStrings.downloadSelected(count: count)))
        .accessibilityIdentifier(LibraryChatSuggestionList.downloadIdentifier(prefix: identifierPrefix))

        // The hand cursor claims a control can be pressed, so an inert button must not
        // show one — applied per state rather than inside a shared helper.
        if isEnabled {
            button.pointingHandCursor()
        } else {
            button
        }
    }
}

// MARK: - What the listener should know before pressing it

/// One line of advisory copy under the download surface.
struct ChatSuggestionCaption: View {
    let text: LocalizedStringResource
    let systemImage: String
    /// Warnings read in the warning colour; the plain note is secondary text.
    let isWarning: Bool
    let identifier: String

    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: tokens.spacing.xxSmall) {
            Image(systemName: systemImage)
                .accessibilityHidden(true)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(tokens.typography.caption.font)
        .foregroundStyle(
            isWarning
                ? tokens.colors.warning.resolve(scheme)
                : tokens.colors.textTertiary.resolve(scheme)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(text))
        .accessibilityIdentifier(identifier)
    }
}

// MARK: - Copy

//
// An extension rather than more of `LibraryChatStrings.swift`, which is at 381 lines
// against the same 400-line ceiling this file's header explains.

extension LibraryChatStrings {
    /// The button's label. Inflected through automatic grammar agreement — the same
    /// mechanism ``proposalCardSubtitle(count:)`` uses — so "1 song" reads correctly in
    /// every locale without a plural table.
    static func downloadSelected(count: Int) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.assistant.chat.download.selected",
            defaultValue: "Download selected (^[\(count) song](inflect: true))",
            comment: "Button that downloads the songs ticked in the list of songs the library does not have"
        )
    }

    static let downloadSelectedHelp = LocalizedStringResource(
        "app.assistant.chat.download.help",
        defaultValue: "Download the ticked songs to your downloads folder.",
        comment: "Tooltip of the button that downloads the ticked songs the library does not have"
    )

    static let downloadSelectHelp = LocalizedStringResource(
        "app.assistant.chat.download.selectHelp",
        defaultValue: "Tick this song to download it.",
        comment: "Tooltip of the checkbox that picks one song for download"
    )

    /// Names WHICH song the checkbox picks, so VoiceOver reads more than "checkbox".
    static func downloadSelectLabel(name: String) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.assistant.chat.download.select",
            defaultValue: "Select \(name) to download",
            comment: "Accessibility label of the checkbox that picks one song for download"
        )
    }

    static let downloadNoPlaylistCaption = LocalizedStringResource(
        "app.assistant.chat.download.noPlaylist",
        defaultValue: "This conversation named no playlist, so these downloads won’t be added to one.",
        comment: "Note stating that songs downloaded from this conversation will not join a playlist"
    )

    static let downloadImportWarning = LocalizedStringResource(
        "app.assistant.chat.download.importOff",
        defaultValue: """
        Downloads won’t appear in your library until you turn on "Add finished downloads to my library" in \
        Settings ▸ Downloads, or add your downloads folder to your library.
        """,
        comment: "Warning that downloaded songs will not enter the library with the current settings"
    )
}
