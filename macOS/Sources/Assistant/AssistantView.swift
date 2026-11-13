// AssistantView — the `.assistant` sidebar destination.
//
// Two regions: a request field that turns a sentence into a reviewable proposal, and
// a suggestion feed of auto-mix / rediscovery / library-health cards.
//
// GATING, in the order it is enforced:
//   1. `SidebarView` only renders the Assistant SECTION while the Intelligence
//      master toggle is on, so with it off there is normally no way to get here.
//   2. `NavigationModel.reconcileAssistant` drops a restored or live `.assistant`
//      selection to All Tracks when the toggle is off, closing the persisted-
//      selection route in.
//   3. This view still checks the toggle itself. Belt and braces on purpose: (1) and
//      (2) both act on the NEXT runloop pass, so a pane that trusted them would flash
//      its request field for a frame after the toggle flips.
//
// TIER-DEPENDENT AFFORDANCES ARE HIDDEN, NEVER ERROR-BADGED. Only the provider
// caption depends on a tier (see `AssistantView+ProviderLabel.swift`); with no tier
// ready the caption simply is not there. The request field STAYS live, because
// `AssistantViewModel` falls back to the heuristic parser tier on exactly those
// machines — badging it as broken would be a lie about a feature that still works.
import DesignSystem
import Persistence
import Services
import SwiftUI
import ViewModels

struct AssistantView: View {
    @Environment(AppEnvironment.self) var environment
    @Environment(AppSettings.self) var settings
    @Environment(NavigationModel.self) private var nav
    @Environment(\.designTokens) var tokens
    @Environment(\.colorScheme) var scheme

    @State var requestText = ""
    @State private var feed = AssistantFeedModel()

    /// Internal, not private, because `AssistantView+Chat.swift` drives them: the
    /// conversation wiring lives in a sibling extension so this file stays inside
    /// SwiftLint's 400-line `file_length` ceiling. Do not fold it back in.
    @State var presented: AssistantSheet?
    /// The provider whose library-browsing disclosure was declined while this pane
    /// has been open, so the sheet is offered once rather than on every send.
    @State var chatDeclinedProviderID: String?
    /// Whether a conversation has actually been asked for. The "no conversation
    /// here" notice stays hidden until then — see ``LibraryChatNoticeView``.
    @State var hasAttemptedChat = false
    /// The on-device model's readiness, read on appear and on every toggle flip and
    /// NEVER in `body`: the reading crosses into the system's language-model
    /// service, which is the same rule `IntelligenceEnableSection` follows.
    @State var appleIntelligence: AssistantAvailability = .unavailable(reason: .modelNotReady)
    /// Whether the on-device web-suggestions pointer has been dismissed this launch.
    @State var webPointer = LibraryChatWebPointer()

    var body: some View {
        Group {
            if settings.intelligenceEnabled {
                enabledBody
            } else {
                StateView(
                    systemImage: LibrarySection.assistant.systemImage,
                    title: AssistantPaneStrings.disabledTitle,
                    message: AssistantPaneStrings.disabledMessage
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(tokens.colors.canvas.resolve(scheme).opacity(0.25))
        .sheet(item: $presented, onDismiss: reloadFeed) { sheet in
            switch sheet {
            case let .proposal(proposal): ProposalPreviewSheet(proposal: proposal)
            case .hygiene: HygieneDetailView(hygiene: hygieneService, profileId: activeProfileId)
            case let .browsingConsent(disclosure): browsingConsentSheet(disclosure)
            }
        }
    }
}

/// The two things the pane can put on top of itself.
///
/// ONE `.sheet` modifier, switched — never two stacked on the same view. Measured:
/// adding a second `.sheet` to this view stopped the FIRST one from presenting its
/// content at all, which took `AssistantFlowTests`' two apply-path cases down with
/// it. SwiftUI honours one sheet presentation per view; the second silently wins.
enum AssistantSheet: Identifiable {
    case proposal(AIProposal)
    case hygiene
    /// The library-browsing disclosure, offered before a cloud provider's FIRST
    /// conversation turn. A third case on the one sheet enum rather than a second
    /// `.sheet` modifier, for the reason above.
    case browsingConsent(LibraryBrowsingDisclosure)

    var id: String {
        switch self {
        case let .proposal(proposal): proposal.id.uuidString
        case .hygiene: "hygiene"
        case let .browsingConsent(disclosure): "browsingConsent.\(disclosure.id)"
        }
    }
}

// MARK: - Enabled body

private extension AssistantView {
    /// The feed takes every point the bar does not, which is what holds the field on
    /// the bottom edge in BOTH pane states — empty suggestion feed and running
    /// transcript. Status / notice / caption sit INSIDE `requestBar` ABOVE the field,
    /// so a reported failure grows the bar upward rather than pushing the field the
    /// listener is about to retype into off the bottom of the pane.
    var enabledBody: some View {
        VStack(spacing: 0) {
            feedContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            requestBar
        }
        .task(id: activeProfileId) {
            await feed.load(
                profileId: activeProfileId,
                generated: environment.intelligence?.generatedPlaylists,
                hygiene: hygieneService
            )
        }
        .task(id: settings.intelligenceEnabled) {
            appleIntelligence = AssistantAvailabilityProbe.current(
                intelligenceEnabled: settings.isEnabled(.nlCreation)
            )
        }
    }

    var requestBar: some View {
        VStack(alignment: .leading, spacing: tokens.spacing.xSmall) {
            AssistantStatusView(error: assistantError, diagnostic: assistantDiagnostic)
            webPointerRow
            if hasAttemptedChat {
                LibraryChatNoticeView(availability: chatAvailability)
            }
            providerLabel
            HStack(spacing: tokens.spacing.small) {
                requestField
                submitButton
                if !isChatEmpty { resetButton }
            }
        }
        .padding(.horizontal, tokens.spacing.large)
        .padding(.vertical, tokens.spacing.small)
    }

    var requestField: some View {
        TextField(text: $requestText, prompt: Text(AssistantPaneStrings.promptPlaceholder)) { EmptyView() }
            .textFieldStyle(.plain)
            .font(tokens.typography.body.font)
            .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
            .padding(.horizontal, tokens.spacing.small)
            .padding(.vertical, tokens.spacing.xSmall)
            .background(
                Capsule().fill(tokens.colors.surfaceRaised.resolve(scheme))
            )
            .overlay(
                Capsule().strokeBorder(
                    tokens.colors.separator.resolve(scheme),
                    lineWidth: tokens.spacing.hairline
                )
            )
            .onSubmit(submit)
            // The prewarm trigger the W3 contract asks the shell to own: a listener
            // who has started typing is much stronger evidence a request is coming
            // than a pane that merely opened. Idempotent after the first call.
            .onChange(of: requestText) { _, _ in prewarmChat() }
            .accessibilityLabel(Text(AssistantPaneStrings.promptLabel))
            .accessibilityIdentifier("assistant.promptField")
    }

    @ViewBuilder
    var submitButton: some View {
        let button = Button(action: submit) {
            Text(AssistantPaneStrings.submit)
                .font(tokens.typography.callout.font)
                .foregroundStyle(tokens.colors.onAccent.resolve(scheme))
                .padding(.horizontal, tokens.spacing.small)
                .padding(.vertical, tokens.spacing.xSmall)
                .background(Capsule().fill(tokens.colors.accent.resolve(scheme)))
        }
        .buttonStyle(.plain)
        .disabled(!canSubmit)
        .help(AssistantPaneStrings.submitHelp)
        .accessibilityIdentifier("assistant.submitButton")

        if canSubmit {
            button.pointingHandCursor()
        } else {
            button.opacity(disabledOpacity)
        }
    }
}

// MARK: - Feed

private extension AssistantView {
    @ViewBuilder
    var feedContent: some View {
        if !isChatEmpty {
            // The transcript takes the feed's place only once there is one. With no
            // messages the pane is exactly what it was, and "New Conversation" puts
            // it back — Auto Mixes, Rediscover and Library Health are never removed.
            LibraryChatTranscriptView(
                messages: chatMessages,
                isResponding: isChatResponding,
                proposal: chatProposal,
                openProposal: openChatProposal,
                onDownloadSelected: { environment.handleChatDownloadRequest($0) },
                isImportConfigured: { environment.isChatDownloadImportConfigured(downloads: settings.downloads) },
                hooks: environment.chatSuggestionHooks
            )
        } else if feed.isEmpty, pendingProposals.isEmpty {
            StateView(
                systemImage: feed.isLoading ? nil : LibrarySection.assistant.systemImage,
                showsProgress: feed.isLoading,
                title: feed.isLoading ? AssistantPaneStrings.loading : AssistantPaneStrings.emptyTitle,
                message: feed.isLoading ? nil : AssistantPaneStrings.emptyMessage
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: tokens.spacing.medium) {
                    pendingSection
                    section(
                        AssistantPaneStrings.autoMixesTitle,
                        feed.autoMixes,
                        subtitle: AssistantPaneStrings.autoMixSubtitle
                    )
                    section(
                        AssistantPaneStrings.rediscoveryTitle,
                        feed.rediscovery,
                        subtitle: AssistantPaneStrings.rediscoverySubtitle
                    )
                    hygieneSection
                }
                .padding(tokens.spacing.large)
            }
            .accessibilityIdentifier("assistant.suggestionFeed")
        }
    }

    @ViewBuilder
    func section(
        _ title: LocalizedStringResource,
        _ summaries: [GeneratedPlaylistSummary],
        subtitle: LocalizedStringResource
    ) -> some View {
        if !summaries.isEmpty {
            VStack(alignment: .leading, spacing: tokens.spacing.xSmall) {
                sectionHeader(title)
                ForEach(summaries, id: \.playlistId) { summary in
                    AssistantSuggestionCard(
                        systemImage: "wand.and.stars",
                        title: Text(verbatim: summary.name),
                        subtitle: Text(subtitle),
                        action: { nav.sidebar = .playlist(id: summary.playlistId) }
                    )
                    .accessibilityIdentifier("assistant.card.mix.\(summary.playlistId)")
                }
            }
        }
    }

    @ViewBuilder
    var hygieneSection: some View {
        if let count = feed.hygieneFindingCount {
            VStack(alignment: .leading, spacing: tokens.spacing.xSmall) {
                sectionHeader(AssistantPaneStrings.hygieneTitle)
                AssistantSuggestionCard(
                    systemImage: "sparkles.rectangle.stack",
                    title: Text(count == 0 ? AssistantPaneStrings.hygieneClean : AssistantPaneStrings.hygieneIssues),
                    subtitle: Text(AssistantPaneStrings.hygieneIssuesSubtitle),
                    count: count == 0 ? nil : count,
                    actionHint: HygieneDetailStrings.openCard,
                    action: { presented = .hygiene }
                )
                .accessibilityIdentifier("assistant.card.hygiene")
            }
        }
    }

    func sectionHeader(_ title: LocalizedStringResource) -> some View {
        Text(title)
            .font(tokens.typography.caption.font)
            .textCase(.uppercase)
            .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
    }
}

// MARK: - Wiring

extension AssistantView {
    /// Dimming for the inert submit button — `.disabled` alone leaves a plain-styled
    /// button at full strength because it draws its own capsule.
    var disabledOpacity: Double {
        0.4
    }

    var activeProfileId: Int64 {
        environment.profileService.activeProfile.id ?? ProfileRecord.guestID
    }

    /// Built here rather than injected: the hygiene pass is a stateless read over the
    /// application database, so there is nothing to keep alive between visits, and
    /// `AppEnvironment.AIStack` deliberately holds only the services that DO carry
    /// state. Gated on the hygiene bundle so a switched-off analyzer never scans.
    var hygieneService: (any LibraryHygieneProviding)? {
        guard settings.isEnabled(.hygiene) else { return nil }
        return LibraryHygieneService(environment.database)
    }

    var canSubmit: Bool {
        guard let intelligence = environment.intelligence else { return false }
        guard !intelligence.assistant.isBusy, !intelligence.chat.isResponding else { return false }
        return !requestText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Re-counts the feed after the hygiene sheet closes, so a finding the listener
    /// just applied stops being counted on the card that opened it.
    func reloadFeed() {
        Task { @MainActor in
            await feed.load(
                profileId: activeProfileId,
                generated: environment.intelligence?.generatedPlaylists,
                hygiene: hygieneService
            )
        }
    }

    /// Why the last request produced nothing, or `nil` when it produced a playlist.
    ///
    /// Read straight off the view model rather than mirrored into `@State`: `submit`
    /// clears it at the start of every request, so a local copy would need its own
    /// reset and could disagree with the model it is describing.
    var assistantError: AssistantProposalError? {
        environment.intelligence?.assistant.lastError
    }

    /// Which tier went quiet on the last request. Set independently of
    /// ``assistantError`` — see ``AssistantStatusView``.
    var assistantDiagnostic: AssistantTierDiagnostic? {
        environment.intelligence?.assistant.lastTierDiagnostic
    }

    /// The same field sends both kinds of request; there is no mode switch.
    ///
    /// A conversation when one is possible, and otherwise the UNCHANGED single-shot
    /// ladder — which is what keeps a Mac with no chat-capable tier working exactly as
    /// it did. See `AssistantView+Chat.swift` for the routing.
    func submit() {
        guard canSubmit else { return }
        submitRouted()
    }

    /// The original single-shot path, byte-for-byte. A produced proposal opens the
    /// preview sheet, which is the ONLY surface that can apply it.
    func submitOneShot() {
        guard let assistant = environment.intelligence?.assistant else { return }
        let request = requestText
        let profileId = activeProfileId
        #if DEBUG
            if let staged = AssistantUITestSeam.stagedProposal(profileId: profileId) {
                assistant.proposals.add(staged)
                requestText = ""
                presented = .proposal(staged)
                return
            }
        #endif
        Task { @MainActor in
            guard let proposal = await assistant.submit(text: request, profileId: profileId) else { return }
            requestText = ""
            presented = .proposal(proposal)
        }
    }
}

#Preview {
    AssistantView()
        .environment(AppEnvironment.preview())
        .environment(AppSettings.preview)
        .environment(NavigationModel())
        .designTokens(.standard)
        .frame(width: 720, height: 480)
}
