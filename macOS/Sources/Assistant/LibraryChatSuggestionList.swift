// LibraryChatSuggestionList — the songs a lookup was asked for and could not find.
//
// ── A URL IS BUILT HERE, OR IT WAS VALIDATED BEFORE IT ARRIVED ───────────────
//
// AMENDED INVARIANT. This header used to claim something stronger: that every URL is
// built here because "there is no field on ``AssistantChatSuggestion`` that could
// carry one". That by-construction property is RETIRED —
// ``AssistantChatSuggestion/videoURL`` now exists, filled in after a turn lands by
// `LibraryChatViewModel`'s enrichment seam.
//
// The rule is narrowed, not dropped: a RECEIVED URL renders only if
// `YouTubeLinkResolver.validatedWatchURL` — AIConnectorKit's ONE sanctioned
// validator — accepted it, and everything else is still built here. The fallback this
// view draws is composed by ``YouTubeSearchLink`` against a fixed endpoint from the
// suggestion's two strings, both of which came from the LISTENER's own request by way
// of `match_tracks`. So a URL a model merely WROTE is still never rendered; what
// changed is that the guarantee is now upheld by that validator plus the two producer
// pins behind it, rather than by the absence of a field.
//
// ── THE VALIDATOR IS CALLED HERE, NOT TRUSTED FROM UPSTREAM ──────────────────
//
// ``destination(for:)`` runs every RECEIVED link through
// `YouTubeLinkResolver.validatedWatchURL` even though the enricher that wrote it
// already did. That is not belt and braces for its own sake: it makes the rendering
// gate STRUCTURAL, so the guarantee holds for whatever writes the field next rather
// than resting on a promise made in another file. Anything the validator rejects — a
// lookalike host, a `/results` path, a short id — falls through to the search link
// this app builds, which is exactly what the surface drew before the field existed.
//
// A `videoURL` is the ONLY input that can become a direct link. A title or artist
// that happens to READ like a URL is search terms and nothing else, which is what
// keeps a model that spells a link into its prose from having drawn one.
//
// ``open(_:)`` hands that URL to `NSWorkspace`, which opens the default browser as
// USER-INITIATED navigation — the same property the `Link` this surface used to draw
// had, now spelled as a call because a row's browser affordance is a `Button` beside
// a second one. Nothing here fetches: the AI network boundary guard forbids
// `URLSession` outside `AIConnectorKit`, and this file makes no request at all.
import AIConnectorKit
import AppKit
import DesignSystem
import Services
import SwiftUI
import ViewModels

struct LibraryChatSuggestionList: View {
    let suggestions: [AssistantChatSuggestion]
    /// Prefix for this list's accessibility identifiers, unique per activity row.
    let identifierPrefix: String
    /// Where a song downloaded from this list should land, straight off the turn's own
    /// row. `nil` is the plain-download case: the link still opens, nothing is linked.
    var appendTarget: SuggestionAppendTarget?
    /// The profile a ``SuggestionAppendTarget/playlist(_:)`` target was read as.
    var appendProfileId: Int64?
    /// Asked for the ticked songs. `nil` hides the whole download surface, which is what
    /// every existing call site and every preview gets.
    var onDownloadSelected: ((ChatDownloadRequest) -> Void)?
    /// Advisory preview of whether a finished download would reach the library. Injected
    /// — see `LibraryChatSuggestionSelection.swift`'s header for why it is never read
    /// from the environment here.
    var isImportConfigured: () -> Bool = { true }
    /// What each row's download is doing, and the seam that primes it. Injected for the
    /// same reason as the two above; ``ChatSuggestionHooks/inert`` reports nothing and
    /// primes nothing, which is what every preview and every existing call site gets.
    var hooks: ChatSuggestionHooks = .inert

    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    @State private var isExpanded = false
    /// Ticked rows, keyed by ``LibraryChatSuggestionList/rowKey(_:)`` so a tick survives
    /// both the expander and an enrichment pass that rewrites the rows underneath it.
    @State private var selectedKeys: Set<String> = []

    var body: some View {
        let linkable = Self.linkable(suggestions)
        if Self.showsHeader(linkable) {
            VStack(alignment: .leading, spacing: tokens.spacing.xxSmall) {
                header(linkable)
                table(linkable)
                if Self.showsExpander(linkable, isExpanded: isExpanded) {
                    expander(total: linkable.count)
                }
                downloadSection(linkable)
            }
            .padding(.leading, tokens.spacing.medium)
            .padding(.top, tokens.spacing.xxSmall)
            .accessibilityIdentifier(identifierPrefix)
            // Keyed on the ids themselves, so this fires once per DISTINCT set rather
            // than once per `body` evaluation — a scrolling transcript performs those
            // constantly, and an enrichment pass that verifies more rows legitimately
            // produces a new set worth priming.
            .task(id: Self.announcedVideoIDs(linkable).joined(separator: ",")) {
                announce(linkable)
            }
        }
    }
}

// MARK: - Rows

private extension LibraryChatSuggestionList {
    /// What the rows beneath are, and — when they can be acted on — how.
    var headerText: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(LibraryChatStrings.suggestionsHeader)
                .font(tokens.typography.caption.font)
                .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
            if Self.showsHeaderSubtitle(Self.linkable(suggestions), isEnabled: onDownloadSelected != nil) {
                Text(LibraryChatStrings.suggestionsTableSubtitle)
                    .font(tokens.typography.caption.font)
                    .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    func header(_: [LinkableSuggestion]) -> some View {
        headerText
            .accessibilityElement(children: .combine)
            // An explicit label because a combined `Text` publishes its string as the
            // accessibility VALUE and leaves the name empty — the defect
            // `LibraryChatMessageRow`'s header records.
            .accessibilityLabel(Text(LibraryChatStrings.suggestionsHeader))
            .accessibilityIdentifier(Self.headerIdentifier(prefix: identifierPrefix))
    }

    /// The rows, numbered over the WHOLE list so a position means the same thing
    /// collapsed and expanded.
    func table(_ linkable: [LinkableSuggestion]) -> some View {
        let isEnabled = onDownloadSelected != nil
        return LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(Self.visible(linkable, isExpanded: isExpanded).enumerated()), id: \.element.id) { row in
                let selectionKey = Self.rowSelectionKey(row.element, isEnabled: isEnabled)
                ChatSuggestionTableRow(
                    number: row.offset + 1,
                    suggestion: row.element,
                    selectionKey: selectionKey,
                    status: hooks.status(Self.rowKey(row.element)),
                    identifierPrefix: identifierPrefix,
                    isSelected: selectionKey.map { binding(for: $0) } ?? .constant(false),
                    onOpen: { Self.open(row.element) },
                    onDownload: { download(only: row.element, in: linkable) }
                )
            }
        }
    }

    /// Tells the wiring layer which verified videos are on screen, once.
    func announce(_ linkable: [LinkableSuggestion]) {
        let videoIDs = Self.announcedVideoIDs(linkable)
        guard !videoIDs.isEmpty else { return }
        hooks.onSuggestionsShown(videoIDs)
    }

    /// One tick, addressed by the key rather than by the row that carries it.
    func binding(for rowKey: String) -> Binding<Bool> {
        Binding(
            get: { selectedKeys.contains(rowKey) },
            set: { isSelected in
                if isSelected {
                    selectedKeys.insert(rowKey)
                } else {
                    selectedKeys.remove(rowKey)
                }
            }
        )
    }

    func expander(total: Int) -> some View {
        Button { isExpanded = true } label: {
            Label {
                Text(LibraryChatStrings.showAllSuggestions(count: total))
            } icon: {
                Image(systemName: "chevron.down")
            }
            .font(tokens.typography.caption.font)
        }
        .buttonStyle(.plain)
        .foregroundStyle(tokens.colors.accent.resolve(scheme))
        .pointingHandCursor()
        .accessibilityIdentifier("\(identifierPrefix).expander")
    }

    /// The download surface: what the listener should know, then the action.
    ///
    /// Driven by the WHOLE linkable set rather than the visible window, so the count and
    /// the captions mean the same thing collapsed and expanded.
    @ViewBuilder
    func downloadSection(_ linkable: [LinkableSuggestion]) -> some View {
        let isEnabled = onDownloadSelected != nil
        if Self.showsNoPlaylistCaption(linkable, isEnabled: isEnabled, appendTarget: appendTarget) {
            ChatSuggestionCaption(
                text: LibraryChatStrings.downloadNoPlaylistCaption,
                systemImage: "info.circle",
                isWarning: false,
                identifier: "\(identifierPrefix).noPlaylistNotice"
            )
        }
        if Self.showsImportWarning(linkable, isEnabled: isEnabled, isImportConfigured: isImportConfigured()) {
            ChatSuggestionCaption(
                text: LibraryChatStrings.downloadImportWarning,
                systemImage: "exclamationmark.triangle",
                isWarning: true,
                identifier: "\(identifierPrefix).importNotice"
            )
        }
        if Self.showsDownloadControls(linkable, isEnabled: isEnabled) {
            ChatSuggestionDownloadButton(
                count: Self.selectedCount(selectedKeys, in: linkable),
                identifierPrefix: identifierPrefix,
                action: { download(linkable) }
            )
        }
    }

    func download(_ linkable: [LinkableSuggestion]) {
        guard let onDownloadSelected else { return }
        onDownloadSelected(Self.request(
            selected: selectedKeys,
            in: linkable,
            appendTarget: appendTarget,
            appendProfileId: appendProfileId
        ))
    }

    /// One row's own Download button: the SAME payload ticking only that row and
    /// pressing the batch button would produce, built through the same derivation so
    /// the two gestures can never disagree about what they asked for.
    ///
    /// The ticks are deliberately not touched — pressing a row's button is not the
    /// same gesture as selecting it.
    func download(only suggestion: LinkableSuggestion, in linkable: [LinkableSuggestion]) {
        guard let onDownloadSelected, let key = Self.selectableKey(suggestion) else { return }
        onDownloadSelected(Self.request(
            selected: [key],
            in: linkable,
            appendTarget: appendTarget,
            appendProfileId: appendProfileId
        ))
    }
}

// MARK: - Derivation (static so the composition suite can drive it)

/// What a row's link PROMISES. The two are drawn, spoken and identified apart
/// because they are different claims: one opens a video that was verified to
/// exist, the other opens a search that may find nothing.
enum SuggestionLinkKind {
    /// A watch link the ONE validator accepted.
    case video
    /// The search link this app composes from the miss's own two strings.
    case search

    var help: LocalizedStringResource {
        switch self {
        case .video: LibraryChatStrings.suggestionVideoHelp
        case .search: LibraryChatStrings.suggestionHelp
        }
    }

    /// The segment that makes a row's accessibility identifier state its kind, so
    /// a UI test can assert WHICH link rendered rather than only that one did.
    var identifierSegment: String {
        switch self {
        case .video: "video"
        case .search: "search"
        }
    }

    func label(name: String) -> LocalizedStringResource {
        switch self {
        case .video: LibraryChatStrings.suggestionVideoLabel(name: name)
        case .search: LibraryChatStrings.suggestionLabel(name: name)
        }
    }
}

/// One miss that resolved to a link, with the display name it reads under, the two
/// strings it was named by, and the kind of promise that link makes.
///
/// ``name`` is the DISPLAY string ("Title — Artist"); ``title`` and ``artist`` are the
/// miss's own two fields, carried apart because a row that names no verified video is
/// downloaded by being LOOKED UP from them — see
/// ``LibraryChatSuggestionList/rowKey(_:)``. The split has to be CARRIED rather than
/// recovered: a title may contain an em dash of its own, so splitting `name` back apart
/// would cut the wrong song in half.
struct LinkableSuggestion: Identifiable {
    let id: Int
    let name: String
    /// The miss's own title, verbatim from ``AssistantChatSuggestion``.
    let title: String
    /// The miss's own artist, verbatim — `nil` when the miss named none.
    let artist: String?
    let url: URL
    let kind: SuggestionLinkKind
}

extension LibraryChatSuggestionList {
    /// How many misses show before the expander.
    static let visibleLimit = 10

    /// "Title — Artist", or just the title when the miss named no artist.
    ///
    /// Track data, so it renders through `Text(verbatim:)`; the dash is punctuation,
    /// not copy.
    static func name(for suggestion: AssistantChatSuggestion) -> String {
        guard let artist = suggestion.artist?.trimmingCharacters(in: .whitespacesAndNewlines),
              !artist.isEmpty
        else {
            return suggestion.title
        }
        return "\(suggestion.title) — \(artist)"
    }

    /// The one URL this surface may open, and what it promises.
    ///
    /// A received link is admitted only by `YouTubeLinkResolver.validatedWatchURL`
    /// — AIConnectorKit's single sanctioned validator, never a check written here.
    /// Its output is what renders, so a link carrying a playlist or a timestamp
    /// opens the canonical form rather than whatever arrived. Everything it turns
    /// down falls through to the search link this app builds.
    static func destination(for suggestion: AssistantChatSuggestion) -> (url: URL, kind: SuggestionLinkKind)? {
        if let received = suggestion.videoURL,
           let validated = YouTubeLinkResolver.validatedWatchURL(received)
        {
            return (validated, .video)
        }
        guard let search = YouTubeSearchLink.url(title: suggestion.title, artist: suggestion.artist) else {
            return nil
        }
        return (search, .search)
    }

    /// The misses that produced a link. One that did not — a blank title — is
    /// dropped, because a line with nothing to search for is not worth a row.
    static func linkable(_ suggestions: [AssistantChatSuggestion]) -> [LinkableSuggestion] {
        suggestions.enumerated().compactMap { offset, suggestion in
            guard let destination = destination(for: suggestion) else { return nil }
            return LinkableSuggestion(
                id: offset,
                name: name(for: suggestion),
                title: suggestion.title,
                artist: suggestion.artist,
                url: destination.url,
                kind: destination.kind
            )
        }
    }

    static func identifier(prefix: String, _ suggestion: LinkableSuggestion) -> String {
        "\(prefix).link.\(suggestion.kind.identifierSegment).\(suggestion.id)"
    }

    static func visible(_ suggestions: [LinkableSuggestion], isExpanded: Bool) -> [LinkableSuggestion] {
        isExpanded ? suggestions : Array(suggestions.prefix(visibleLimit))
    }

    static func showsExpander(_ suggestions: [LinkableSuggestion], isExpanded: Bool) -> Bool {
        !isExpanded && suggestions.count > visibleLimit
    }
}

// MARK: - Copy Link

extension LibraryChatSuggestionList {
    /// Exactly what "Copy Link" puts on the pasteboard: the row's destination,
    /// character for character. For a video row that is the raw `watch?v=` URL —
    /// a machine-readable address something downstream can consume, never the
    /// display name beside it and never a formatted variant.
    ///
    /// Split from the write so the contract is assertable without a pasteboard.
    static func copyText(for suggestion: LinkableSuggestion) -> String {
        suggestion.url.absoluteString
    }

    static func copy(_ suggestion: LinkableSuggestion) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(copyText(for: suggestion), forType: .string)
    }

    /// Hands the row's destination to the default browser.
    ///
    /// `NSWorkspace` rather than the `Link` the row used to be, because the row is now
    /// a table with two buttons and a `Link` cannot be one of them — but the NAVIGATION
    /// is unchanged: the same validated URL, opened as user-initiated navigation, with
    /// nothing in this file fetching anything.
    static func open(_ suggestion: LinkableSuggestion) {
        NSWorkspace.shared.open(suggestion.url)
    }
}
