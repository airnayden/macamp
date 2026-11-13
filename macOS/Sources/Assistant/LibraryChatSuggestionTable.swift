// LibraryChatSuggestionTable — the songs a lookup could not find, as a table a
// listener can act on row by row.
//
// ── WHY A TABLE AND NOT A LIST OF LINKS ──────────────────────────────────────
//
// The surface this replaces drew one tappable link per miss, with a checkbox in front
// of the rows that happened to carry a verified video. That shape answered exactly one
// question — "where can I hear this?" — and answered it identically for a song already
// downloading and a song nothing had ever been asked about. Now every row states its
// own position, its own title and artist apart, its own download status, and offers the
// two actions separately: OPEN (a browser navigation, free) and DOWNLOAD (a transfer,
// which costs something and can fail). Those are different promises and they get
// different buttons.
//
// The grid is ``TrackListRow``'s, deliberately: a 24-pt leading ordinal slot, a
// title/artist stack in `body`/`caption` over `textPrimary`/`textSecondary`, trailing
// accessories, and `spacing.small` between them. A transcript that lists library tracks
// one paragraph above and misses one paragraph below must not render them in two
// different grids.
//
// ── THE TABLE STILL LOOKS NOTHING UP ─────────────────────────────────────────
//
// ``ChatSuggestionHooks`` is INJECTED, exactly like `onDownloadSelected` and
// `isImportConfigured` beside it, and defaults to ``ChatSuggestionHooks/inert``. This
// file reads no `AppEnvironment`, no database and no settings: a status is a closure
// call, and priming one is a closure call. That is what lets the composition suite
// drive the whole surface with recorders, and it is what keeps a SwiftUI `body` free
// of I/O — the contract `LibraryChatSuggestionSelection.swift`'s header states.
import DesignSystem
import SwiftUI

// MARK: - What the table has to be told

/// The two things the table cannot derive from a suggestion: what a row's download is
/// currently doing, and that a turn's rows have appeared.
///
/// ONE struct rather than two loose closure props, because they are one seam — todo 9
/// hands both halves to the same `ChatDownloadStatusStore`, and a surface that threaded
/// only one of them would render a status column nothing ever primes.
///
/// Both closures are `@MainActor` (the store they will reach is a `@MainActor`
/// `@Observable` class) and `@Sendable` (so this type is `Sendable` and ``inert`` is a
/// concurrency-safe `static let`) — the shape ``LibraryChatEngine`` established.
struct ChatSuggestionHooks {
    /// What the row keyed by this string currently says. A key nothing has been told
    /// about must answer ``ChatDownloadRowStatus/none`` rather than throwing or
    /// blocking: the table renders every row on first sight, before anything is primed.
    var status: @MainActor @Sendable (String) -> ChatDownloadRowStatus
    /// The verified video ids a turn's suggestions just put on screen, so a wiring
    /// layer can prime "you already downloaded this" for them.
    ///
    /// Called ONCE per distinct set — see
    /// ``LibraryChatSuggestionList/announcedVideoIDs(_:)`` — never once per `body`
    /// evaluation, which a scrolling transcript performs constantly.
    var onSuggestionsShown: @MainActor @Sendable ([String]) -> Void

    /// The default every existing call site, every preview and every test gets: a
    /// table that reports nothing and primes nothing.
    static let inert = ChatSuggestionHooks(status: { _ in .none }, onSuggestionsShown: { _ in })
}

/// Which token role a status reads in.
///
/// A named tone rather than a `Color` so the mapping is assertable without a rendered
/// view and without a `DesignTokens` instance — the same reason every other decision
/// on this surface is a static.
enum ChatSuggestionStatusTone: Equatable {
    /// Something is happening and will change on its own. `textSecondary`.
    case working
    /// The song arrived. `success`.
    case success
    /// The song will not arrive without another attempt. `warning`.
    case warning
    /// A note about the past, not a report about this row's work. `textTertiary`.
    case advisory
}

// MARK: - Derivation (static so the composition suite can drive it)

extension LibraryChatSuggestionList {
    /// Whether the table draws its heading.
    ///
    /// Keyed on rows ALONE, not on the download surface: "Not in your library" names
    /// what the rows beneath it are, and a list of unexplained links is worse than a
    /// heading over a read-only list.
    static func showsHeader(_ suggestions: [LinkableSuggestion]) -> Bool {
        !suggestions.isEmpty
    }

    /// Whether the heading carries its subtitle.
    ///
    /// The subtitle tells a listener how to PICK songs, so it follows the download
    /// surface rather than the heading — with no handler there is nothing to pick and
    /// the sentence would describe controls that are not drawn.
    static func showsHeaderSubtitle(_ suggestions: [LinkableSuggestion], isEnabled: Bool) -> Bool {
        showsDownloadControls(suggestions, isEnabled: isEnabled)
    }

    /// The verified video ids this list just put on screen, in draw order, each once.
    ///
    /// Only the VERIFIED ones: a candidate has no video id yet, so there is nothing
    /// download history could be asked about.
    static func announcedVideoIDs(_ suggestions: [LinkableSuggestion]) -> [String] {
        var seen: Set<String> = []
        return suggestions.compactMap { suggestion in
            guard let videoID = verifiedVideoID(suggestion), seen.insert(videoID).inserted else {
                return nil
            }
            return videoID
        }
    }

    /// Whether a row's own Download button can be pressed.
    ///
    /// Refused only while the row is already WORKING — pressing again would ask the
    /// queue for a download it is in the middle of. Every settled status stays
    /// pressable on purpose: `.failed` and `.notFound` are worth retrying, and
    /// `.downloaded`/`.alreadyDownloaded` are the listener's call to make again.
    static func downloadButtonEnabled(status: ChatDownloadRowStatus) -> Bool {
        switch status {
        case .resolving, .queued, .downloading, .converting:
            false
        case .none, .notFound, .alreadyDownloaded, .downloaded, .addedToPlaylist, .failed:
            true
        }
    }

    /// The colour role a status reads in, or `nil` when it draws nothing.
    static func statusTone(for status: ChatDownloadRowStatus) -> ChatSuggestionStatusTone? {
        switch status {
        case .none: nil
        case .resolving, .queued, .downloading, .converting: .working
        case .downloaded, .addedToPlaylist: .success
        case .failed, .notFound: .warning
        case .alreadyDownloaded: .advisory
        }
    }

    /// The determinate fraction a status draws a bar for, or `nil`.
    ///
    /// Only `.downloading` has one, and it is `nil` there too while the phase is
    /// indeterminate (the metadata prefetch, or an unsized stream).
    static func statusFraction(for status: ChatDownloadRowStatus) -> Double? {
        guard case let .downloading(fraction) = status else { return nil }
        return fraction
    }

    /// The sentence a row's status reads, or `nil` when the row says nothing.
    ///
    /// Split across ``settledStatusText(for:)`` purely for SwiftLint's
    /// `cyclomatic_complexity` ceiling (10, and `--strict` makes the warning an error),
    /// and split by GROUPING rather than with a `default:` — both halves stay
    /// exhaustive over the whole vocabulary, so an eleventh status is a compile error
    /// in both rather than a silently blank column in one.
    static func statusText(for status: ChatDownloadRowStatus) -> LocalizedStringResource? {
        switch status {
        case .none: nil
        case .resolving: LibraryChatStrings.statusResolving
        case .queued: LibraryChatStrings.statusQueued
        case .downloading: LibraryChatStrings.statusDownloading
        case .converting: LibraryChatStrings.statusConverting
        case .notFound, .alreadyDownloaded, .downloaded, .addedToPlaylist, .failed:
            settledStatusText(for: status)
        }
    }

    /// The half of ``statusText(for:)`` a row has stopped moving in.
    ///
    /// An empty playlist name falls back to the unnamed copy — the rendering side owns
    /// that, exactly as `ChatDownloadToastCoalescer.summaryText(count:playlist:)` does.
    private static func settledStatusText(for status: ChatDownloadRowStatus) -> LocalizedStringResource? {
        switch status {
        case .notFound: LibraryChatStrings.statusNotFound
        case .alreadyDownloaded: LibraryChatStrings.statusAlreadyDownloaded
        case .downloaded: LibraryChatStrings.statusDownloaded
        case let .addedToPlaylist(name): name.isEmpty
            ? LibraryChatStrings.statusAddedToUnnamedPlaylist
            : LibraryChatStrings.statusAddedToPlaylist(name: name)
        case .failed: LibraryChatStrings.statusFailed
        case .none, .resolving, .queued, .downloading, .converting: nil
        }
    }

    // MARK: Identifiers

    static func headerIdentifier(prefix: String) -> String {
        "\(prefix).header"
    }

    /// Addressed by the key the row MEANS, like the tick beside it, so a UI test names
    /// a song rather than a position.
    static func statusIdentifier(prefix: String, rowKey: String) -> String {
        "\(prefix).status.\(rowKey)"
    }

    /// The row's OWN Download button. Distinct from ``downloadIdentifier(prefix:)``,
    /// which is the one batch button at the foot of the list.
    static func rowDownloadIdentifier(prefix: String, rowKey: String) -> String {
        "\(prefix).download.\(rowKey)"
    }
}

// MARK: - What the leading button says

extension SuggestionLinkKind {
    /// The word on the row's browser button.
    ///
    /// Two words for two promises: a verified row OPENS a video that was checked to
    /// exist, a fallback row SEARCHES and may find nothing. Colour and an icon alone
    /// are not a distinction anyone can rely on — the same reasoning behind the
    /// visible "search" tag beside the title.
    var actionLabel: LocalizedStringResource {
        switch self {
        case .video: LibraryChatStrings.suggestionOpenAction
        case .search: LibraryChatStrings.suggestionSearchAction
        }
    }
}

// MARK: - The status column

/// What one row's download is currently doing, in one caption-weight line.
struct ChatSuggestionStatusLabel: View {
    let status: ChatDownloadRowStatus
    let identifier: String

    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let text = LibraryChatSuggestionList.statusText(for: status) {
            HStack(spacing: tokens.spacing.xxSmall) {
                Text(text).lineLimit(1)
                if let fraction = LibraryChatSuggestionList.statusFraction(for: status) {
                    // The percentage is a BAR, never interpolated into the sentence: a
                    // number formatted into copy is one a locale cannot re-format.
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                        .frame(width: 48)
                        .accessibilityHidden(true)
                }
            }
            .font(tokens.typography.caption.font)
            .foregroundStyle(color)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(text))
            .accessibilityIdentifier(identifier)
        }
    }

    private var color: Color {
        switch LibraryChatSuggestionList.statusTone(for: status) {
        case .success: tokens.colors.success.resolve(scheme)
        case .warning: tokens.colors.warning.resolve(scheme)
        case .advisory: tokens.colors.textTertiary.resolve(scheme)
        // `.working` and the `nil` that draws nothing share the neutral role — the
        // `nil` branch is unreachable inside the `if let` above and is spelled so the
        // switch needs no `default:`.
        case .working, nil: tokens.colors.textSecondary.resolve(scheme)
        }
    }
}
