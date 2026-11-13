// LibraryChatSuggestionTableRow — one miss, drawn on ``TrackListRow``'s grid.
//
// Split from `LibraryChatSuggestionTable.swift` to keep both files inside SwiftLint's
// strict 400-line ceiling — the same reason `LibraryChatSuggestionKeys.swift` was split
// off `LibraryChatSuggestionSelection.swift`. That file holds the decisions (which
// status reads in which colour, whether a button can be pressed, what the identifiers
// are); this one holds the drawing.
//
// Everything the row renders is a PLAIN VALUE it was handed. It reads no
// `AppEnvironment`, resolves no status of its own and opens nothing itself: the two
// actions are injected closures, exactly like ``TrackListRow``'s favourite and karaoke
// accessories, so the row stays O(1) and the composition suite can drive every decision
// behind it without a host.
import DesignSystem
import SwiftUI

// MARK: - One row

/// One miss: its position, what it is, what its download is doing, and the two things
/// that can be done to it.
///
/// Takes the ``LinkableSuggestion`` whole rather than its fields apart. The row needs
/// `title`, `artist`, `kind`, the display `name` AND the row key, all of which that
/// value already carries verbatim — Todo 5 split `title`/`artist` onto it for exactly
/// this — so five props collapse into one and none of them can be passed inconsistently.
struct ChatSuggestionTableRow: View {
    /// Ordinal in the leading slot, 1-based over the WHOLE list.
    let number: Int
    let suggestion: LinkableSuggestion
    /// The key this row can be PICKED by, or `nil` when it draws neither a tick nor a
    /// Download button — the one row with no title to look up.
    let selectionKey: String?
    let status: ChatDownloadRowStatus
    let identifierPrefix: String
    @Binding var isSelected: Bool
    let onOpen: () -> Void
    let onDownload: () -> Void

    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: tokens.spacing.small) {
            selectionSlot
            ordinal
            identity
            Spacer(minLength: tokens.spacing.small)
            ChatSuggestionStatusLabel(
                status: status,
                identifier: LibraryChatSuggestionList.statusIdentifier(prefix: identifierPrefix, rowKey: rowKey)
            )
            openButton
            if selectionKey != nil {
                downloadButton
            }
        }
        .padding(.vertical, tokens.spacing.xxSmall)
        .contentShape(Rectangle())
        .contextMenu {
            Button { LibraryChatSuggestionList.copy(suggestion) } label: {
                Text(LibraryChatStrings.suggestionCopyLink)
            }
        }
    }

    private var rowKey: String {
        LibraryChatSuggestionList.rowKey(suggestion)
    }
}

// MARK: - The row's parts

private extension ChatSuggestionTableRow {
    /// The tick, or the space it would have taken.
    ///
    /// A clear placeholder rather than nothing, so an unpickable row's title still
    /// lines up with every other row's.
    @ViewBuilder
    var selectionSlot: some View {
        if let selectionKey {
            ChatSuggestionSelectionToggle(
                rowKey: selectionKey,
                name: suggestion.name,
                identifierPrefix: identifierPrefix,
                isSelected: $isSelected
            )
        } else {
            Color.clear.frame(width: 16, height: 1)
        }
    }

    /// ``TrackListRow``'s leading slot, to the pixel: 24 pt, centred, timecode digits.
    /// Hidden from VoiceOver — the row's own buttons name the song, and a bare number
    /// read before them says nothing.
    var ordinal: some View {
        Text(verbatim: "\(number)")
            .font(tokens.typography.timecode.font)
            .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
            .frame(width: 24, alignment: .center)
            .accessibilityHidden(true)
    }

    /// Title over artist, as every other list surface draws them. Track data, so both
    /// render verbatim.
    var identity: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: tokens.spacing.xxSmall) {
                Text(verbatim: suggestion.title)
                    .font(tokens.typography.body.font)
                    .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
                    .lineLimit(1)
                if suggestion.kind == .search {
                    searchTag
                }
            }
            if let artist = suggestion.artist, !artist.isEmpty {
                Text(verbatim: artist)
                    .font(tokens.typography.caption.font)
                    .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
                    .lineLimit(1)
            }
        }
    }

    /// The marker that makes a fallback visibly different from a verified video.
    ///
    /// Hidden from VoiceOver because the row's own button already names which kind of
    /// link this is — reading the tag too would say "search" twice.
    var searchTag: some View {
        Text(LibraryChatStrings.suggestionSearchTag)
            .font(tokens.typography.caption.font)
            .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
            .padding(.horizontal, tokens.spacing.xxSmall)
            .background(Capsule().fill(tokens.colors.surfaceRaised.resolve(scheme)))
            .accessibilityHidden(true)
    }
}

// MARK: - The two actions

private extension ChatSuggestionTableRow {
    /// Opens the row's destination in the browser. Keeps the list's long-standing
    /// `….link.<kind>.<position>` identifier, which is what names the promise the
    /// button makes — and what the shipped XCUITest walks.
    var openButton: some View {
        Button(action: onOpen) {
            Label {
                Text(suggestion.kind.actionLabel)
            } icon: {
                Image(systemName: "safari")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .pointingHandCursor()
        .help(Text(suggestion.kind.help))
        .accessibilityLabel(Text(suggestion.kind.label(name: suggestion.name)))
        .accessibilityIdentifier(LibraryChatSuggestionList.identifier(prefix: identifierPrefix, suggestion))
    }

    /// Downloads this one song, without touching the ticks — pressing it is not the
    /// same gesture as ticking the row, and must not silently become one.
    @ViewBuilder
    var downloadButton: some View {
        let isEnabled = LibraryChatSuggestionList.downloadButtonEnabled(status: status)
        let button = Button(action: onDownload) {
            Label {
                Text(LibraryChatStrings.suggestionDownloadAction)
            } icon: {
                Image(systemName: "arrow.down.circle")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(!isEnabled)
        .help(Text(LibraryChatStrings.suggestionDownloadRowHelp))
        .accessibilityLabel(Text(LibraryChatStrings.suggestionDownloadRowLabel(name: suggestion.name)))
        .accessibilityIdentifier(
            LibraryChatSuggestionList.rowDownloadIdentifier(prefix: identifierPrefix, rowKey: rowKey)
        )

        // The hand cursor claims a control can be pressed, so a row already working
        // must not show one — applied per state, never inside a shared helper.
        if isEnabled {
            button.pointingHandCursor()
        } else {
            button
        }
    }
}
