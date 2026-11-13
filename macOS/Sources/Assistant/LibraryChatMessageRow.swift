// LibraryChatMessageRow — one exchange, drawn.
//
// ── PROSE COMES FROM `text`, ACTIVITY COMES FROM `events` ────────────────────
//
// Both tiers report an `.assistantText` EVENT and also fold the same prose into the
// turn's `text` (`AssistantChatEventMapping.answerText` derives one from the other on
// purpose, so they can never disagree). Rendering both would print every answer
// twice, so this row reads `text` for what was said and `events` ONLY for the tool
// calls. `.toolResult`'s SUMMARY is never drawn — it is the tool's model-facing
// prose, which is inspection payload and not copy (W1 note 2). Its `resultCount` is
// a different kind of thing: a number the tool computed from the rows it built, so
// it is drawn, through a localized template, beside the caption its call already
// earned. A lookup that reports no count renders exactly as it did before.
//
// ── THE ROW IS ONE ACCESSIBILITY ELEMENT WITH AN EXPLICIT LABEL ──────────────
//
// Measured on this platform and recorded: a SwiftUI `Text` publishes its string as
// the accessibility VALUE and leaves `label` EMPTY, and a bare
// `.accessibilityElement(children: .combine)` therefore yields a value-only element
// with no name. `AssistantStatusView` already carries the fix — combine, then set an
// EXPLICIT composed label that keeps the role prefix — and this file uses the same
// `spoken(_:_:)` shape so the two surfaces sound alike.
//
// Identifiers sit on the COMBINED element, which after `.combine` has no accessible
// children left to shadow it — the defect class that took two `AssistantFlowTests`
// cases down when an identifier sat on a container holding an SF Symbol.
import DesignSystem
import Persistence
import Services
import SwiftUI
import ViewModels

/// One message in the conversation, with everything that happened to produce it.
struct LibraryChatMessageRow: View {
    let message: LibraryChatMessage
    /// The row's position, used only to build unique accessibility identifiers.
    let index: Int
    /// Resolves a filed proposal so the card can state its size. `nil` once the
    /// proposal has been applied or discarded, which correctly hides the card.
    let proposal: (UUID) -> AIProposal?
    let openProposal: (AIProposal) -> Void
    /// Asked for the songs ticked in this row's suggestion lists. INJECTED rather than
    /// read from `AppEnvironment` so the composition suite can drive it with a recorder;
    /// `nil` hides the download surface entirely.
    var onDownloadSelected: ((ChatDownloadRequest) -> Void)?
    /// Advisory preview of whether a finished download would reach the library. Injected
    /// for the same reason, and defaulted so nothing that does not know about downloads
    /// has to say anything.
    var isImportConfigured: () -> Bool = { true }
    /// What each suggestion row's download is doing, and the seam that primes it.
    /// Injected and defaulted for the same reasons as the two above.
    var hooks: ChatSuggestionHooks = .inert

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    /// The live library rows behind this message's lookups. One read per message,
    /// off-main, from the `.task` below — never from `body`.
    @State private var tracks = ChatTrackResolver()

    /// Whether the collapsed lookup machinery of a proposal turn is expanded.
    @State private var showsLookups = false

    var body: some View {
        VStack(alignment: message.role == .listener ? .trailing : .leading, spacing: tokens.spacing.xxSmall) {
            switch message.role {
            case .listener:
                listenerBubble
            case .assistant:
                assistantContent
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .listener ? .trailing : .leading)
        .task(id: message.id) { await resolveTracks() }
    }

    private func resolveTracks() async {
        await tracks.load(
            key: message.id,
            repository: TrackRepository(environment.database),
            profileId: environment.profileService.activeProfile.id ?? ProfileRecord.guestID,
            trackIds: ChatTrackResolver.trackIds(in: message.toolActivity)
        )
    }
}

// MARK: - The listener's side

private extension LibraryChatMessageRow {
    var listenerBubble: some View {
        Text(verbatim: message.text)
            .font(tokens.typography.body.font)
            .foregroundStyle(tokens.colors.onAccent.resolve(scheme))
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, tokens.spacing.small)
            .padding(.vertical, tokens.spacing.xSmall)
            .background(
                RoundedRectangle(cornerRadius: tokens.radii.medium, style: .continuous)
                    .fill(tokens.colors.accent.resolve(scheme))
            )
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Self.spoken(LibraryChatStrings.listenerLabel, Text(verbatim: message.text)))
            .accessibilityIdentifier(Self.bubbleIdentifier(role: .listener, index: index))
            // Last on purpose: it overlays a Copy button, and anything added under
            // `.combine` above is folded into the bubble's label instead of staying
            // its own element.
            .chatMessageCopyAffordances(for: message, index: index)
    }
}

// MARK: - The assistant's side

private extension LibraryChatMessageRow {
    @ViewBuilder
    var assistantContent: some View {
        if Self.collapsesActivity(message) {
            if !message.text.isEmpty {
                assistantBubble
            }
            proposalCards
            suggestionLists
            lookupDisclosure
        } else {
            activityRows
            if !message.text.isEmpty {
                assistantBubble
            }
            proposalCards
        }
        if message.isTruncated {
            notice(LibraryChatStrings.truncatedNotice, identifier: "assistant.chat.truncated.\(index)")
        }
        if let failure = message.failure {
            failureBanner(failure)
        }
    }

    /// One row per tool CALL, in call order, each followed by whatever it found.
    var activityRows: some View {
        ForEach(Array(message.toolActivity.enumerated()), id: \.offset) { offset, activity in
            activityRow(activity)
            LibraryChatTrackList(
                rows: activity.rows,
                resolved: tracks.resolved,
                identifierPrefix: "assistant.chat.tracks.\(index).\(offset)"
            )
            suggestionList(activity, offset: offset)
        }
    }

    /// The suggestion lists alone, in activity order, keeping each activity's own
    /// identifier position so a UI test addresses the same row either way.
    ///
    /// Rendered OUTSIDE the disclosure on a proposal turn: a song the library
    /// lacks is actionable content beside the proposal, not machinery behind it.
    var suggestionLists: some View {
        ForEach(Array(message.toolActivity.enumerated()), id: \.offset) { offset, activity in
            suggestionList(activity, offset: offset)
        }
    }

    /// The gathering machinery of a proposal turn — every lookup caption and every
    /// intermediate track list — folded behind one collapsed row.
    var lookupDisclosure: some View {
        DisclosureGroup(isExpanded: $showsLookups) {
            ForEach(Array(message.toolActivity.enumerated()), id: \.offset) { offset, activity in
                activityRow(activity)
                LibraryChatTrackList(
                    rows: activity.rows,
                    resolved: tracks.resolved,
                    identifierPrefix: "assistant.chat.tracks.\(index).\(offset)"
                )
            }
        } label: {
            // The summary itself toggles the group: SwiftUI's disclosure label is inert,
            // so the chevron was the only target and the sentence beside it looked
            // pressable without being so.
            Button { showsLookups.toggle() } label: {
                Text(LibraryChatStrings.lookupSummary(count: message.toolActivity.count))
                    .font(tokens.typography.caption.font)
                    .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
        }
        .disclosureGroupStyle(.automatic)
        .tint(tokens.colors.textSecondary.resolve(scheme))
        .accessibilityIdentifier("assistant.chat.lookups.\(index)")
    }

    func activityRow(_ activity: AssistantChatActivity) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: tokens.spacing.xSmall) {
            Image(systemName: LibraryChatStrings.toolSymbol(for: activity.name))
                .font(tokens.typography.caption.font)
                .foregroundStyle(tokens.colors.accent.resolve(scheme))
                .accessibilityHidden(true)
            Self.activityText(activity)
                .font(tokens.typography.caption.font)
                .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.spoken(LibraryChatStrings.activityLabel, Self.activityText(activity)))
        .accessibilityIdentifier("assistant.chat.tool.\(activity.name)")
    }

    var assistantBubble: some View {
        Text(verbatim: message.text)
            .font(tokens.typography.body.font)
            .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, tokens.spacing.small)
            .padding(.vertical, tokens.spacing.xSmall)
            .background(
                RoundedRectangle(cornerRadius: tokens.radii.medium, style: .continuous)
                    .fill(tokens.colors.surfaceRaised.resolve(scheme))
            )
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Self.spoken(LibraryChatStrings.assistantLabel, Text(verbatim: message.text)))
            .accessibilityIdentifier(Self.bubbleIdentifier(role: .assistant, index: index))
            // Last on purpose — see `listenerBubble`.
            .chatMessageCopyAffordances(for: message, index: index)
    }

    /// Cards for playlists `propose_playlist` filed during this turn.
    ///
    /// Tapping one opens the EXISTING ``ProposalPreviewSheet`` with its per-track
    /// checkboxes — the single review surface every other proposal already goes
    /// through. Nothing here can write.
    var proposalCards: some View {
        ForEach(message.proposalIds, id: \.self) { proposalId in
            if let filed = proposal(proposalId) {
                AssistantSuggestionCard(
                    systemImage: "wand.and.stars",
                    title: Text(verbatim: LibraryChatMessageRow.name(of: filed)),
                    subtitle: Text(LibraryChatStrings.proposalCardSubtitle(count: filed.affectedCount)),
                    actionHint: LibraryChatStrings.proposalCardHint,
                    action: { openProposal(filed) }
                )
                .accessibilityIdentifier("assistant.chat.proposal.\(proposalId.uuidString)")
            }
        }
    }
}

// MARK: - The lookup row's copy

extension LibraryChatMessageRow {
    /// "Searched your library", or "Searched your library — 12 results".
    ///
    /// The count is only ever appended when the tool ANSWERED with one: a digest,
    /// a filed proposal and a refusal carry `nil`, and today's copy is what they
    /// still render. Composed as one `Text` so the row stays a single
    /// accessibility element whose label reads the whole sentence.
    ///
    /// Not `private`: this is the template selection `LibraryChatCompositionTests`
    /// drives, and a row rendered by SwiftUI cannot be inspected after the fact.
    static func activityText(_ activity: AssistantChatActivity) -> Text {
        let caption = Text(LibraryChatStrings.toolCaption(for: activity.name))
        guard let resultCount = activity.resultCount else { return caption }
        return caption + Text(verbatim: " ") + Text(LibraryChatStrings.toolResultCount(resultCount))
    }

    /// Whether this turn's lookup machinery folds behind the collapsed disclosure.
    ///
    /// A turn that FILED A PROPOSAL is answered by its card — the searches that
    /// gathered the membership are provenance, not content, and a 43-track ask
    /// renders a dozen of them. A turn with no proposal keeps the flat layout:
    /// there the track lists ARE the answer the prose deliberately does not repeat.
    /// Keyed on `proposalIds`, never on the resolver — an applied proposal must
    /// not spring the machinery back open.
    static func collapsesActivity(_ message: LibraryChatMessage) -> Bool {
        !message.proposalIds.isEmpty && !message.toolActivity.isEmpty
    }
}

// MARK: - Notices

private extension LibraryChatMessageRow {
    func notice(_ text: LocalizedStringResource, identifier: String) -> some View {
        HStack(alignment: .top, spacing: tokens.spacing.xSmall) {
            Image(systemName: "info.circle")
                .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
                .accessibilityHidden(true)
            Text(text)
                .font(tokens.typography.caption.font)
                .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(tokens.spacing.xSmall)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: tokens.radii.small, style: .continuous)
                .fill(tokens.colors.surfaceRaised.resolve(scheme))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.spoken(AssistantPaneStrings.noticeLabel, Text(text)))
        .accessibilityIdentifier(identifier)
    }

    func failureBanner(_ failure: LibraryChatFailure) -> some View {
        HStack(alignment: .top, spacing: tokens.spacing.xSmall) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(tokens.colors.danger.resolve(scheme))
                .accessibilityHidden(true)
            Text(LibraryChatFailureCopy.message(for: failure))
                .font(tokens.typography.caption.font)
                .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(tokens.spacing.xSmall)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: tokens.radii.small, style: .continuous)
                .fill(tokens.colors.danger.resolve(scheme).opacity(0.12))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.spoken(
            AssistantPaneStrings.errorBannerLabel,
            Text(LibraryChatFailureCopy.message(for: failure))
        ))
        .accessibilityIdentifier("assistant.chat.failure.\(index)")
    }

    /// "<role>: <message>", composed. See the file header.
    static func spoken(_ role: LocalizedStringResource, _ message: Text) -> Text {
        Text(role) + Text(verbatim: ": ") + message
    }

    /// A proposed playlist's name. `.createPlaylist` is the only kind chat can file,
    /// but the switch stays exhaustive so a future kind is a compile error here.
    static func name(of proposal: AIProposal) -> String {
        switch proposal.kind {
        case let .createPlaylist(request): request.name
        case let .rename(_, name): name
        case .organize, .tagChangeSet: ""
        }
    }
}

// MARK: - The misses a lookup reported

private extension LibraryChatMessageRow {
    /// One lookup's misses, carrying THIS turn's append target so a song downloaded from
    /// them lands where the conversation said it should.
    ///
    /// One function rather than the same six arguments at each place the list is drawn:
    /// a turn draws its misses from more than one position depending on whether it filed
    /// a proposal, and a target threaded at only one of them is the bug this prevents.
    func suggestionList(_ activity: AssistantChatActivity, offset: Int) -> some View {
        LibraryChatSuggestionList(
            suggestions: activity.suggestions,
            identifierPrefix: "assistant.chat.suggestions.\(index).\(offset)",
            appendTarget: message.appendTarget,
            appendProfileId: message.appendProfileId,
            onDownloadSelected: onDownloadSelected,
            isImportConfigured: isImportConfigured,
            hooks: hooks
        )
    }
}
