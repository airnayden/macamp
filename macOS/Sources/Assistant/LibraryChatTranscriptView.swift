// LibraryChatTranscriptView — the conversation, and the notice that explains why
// there is not one.
//
// The transcript REPLACES the suggestion feed only once a conversation has started.
// Auto-mixes, Rediscover and Library Health are not removed and not moved: with no
// messages the pane is byte-for-byte what it was, and "New Conversation" puts it
// back. Nothing about the one-shot request path changes either — the same field
// sends both, which is why there is no mode switch to get wrong.
import DesignSystem
import SwiftUI
import ViewModels

/// The conversation so far.
struct LibraryChatTranscriptView: View {
    let messages: [LibraryChatMessage]
    let isResponding: Bool
    let proposal: (UUID) -> AIProposal?
    let openProposal: (AIProposal) -> Void
    /// THE injection point for the download surface: `AssistantView.feedContent` builds
    /// this view where the composition root is in scope, and assigns these two there.
    /// Defaulted, so a transcript that says nothing about downloads shows none of it.
    var onDownloadSelected: ((ChatDownloadRequest) -> Void)?
    var isImportConfigured: () -> Bool = { true }
    /// The third of the same kind: what each suggestion row's download is doing, and
    /// the seam that primes it. Defaulted, so a transcript that says nothing about
    /// downloads reports no status either.
    var hooks: ChatSuggestionHooks = .inert

    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: tokens.spacing.small) {
                    ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                        LibraryChatMessageRow(
                            message: message,
                            index: index,
                            proposal: proposal,
                            openProposal: openProposal,
                            onDownloadSelected: onDownloadSelected,
                            isImportConfigured: isImportConfigured,
                            hooks: hooks
                        )
                        .id(message.id)
                    }
                    if isResponding {
                        respondingRow
                    }
                }
                .padding(tokens.spacing.large)
            }
            .accessibilityIdentifier("assistant.chat.transcript")
            // The transcript is append-only between resets, so the count changing is
            // exactly "a row arrived" — and the row scrolled to is resolved by
            // IDENTITY, which is what keeps the anchor correct as a row grows.
            .onChange(of: messages.count) { _, _ in
                guard let id = messages.last?.id else { return }
                withAnimation(.easeInOut(duration: tokens.motion.standard)) {
                    proxy.scrollTo(id, anchor: .bottom)
                }
            }
        }
    }
}

private extension LibraryChatTranscriptView {
    var respondingRow: some View {
        HStack(spacing: tokens.spacing.xSmall) {
            ProgressView()
                .controlSize(.small)
                .accessibilityHidden(true)
            Text(LibraryChatStrings.respondingLabel)
                .font(tokens.typography.caption.font)
                .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(LibraryChatStrings.respondingLabel))
        .accessibilityIdentifier("assistant.chat.responding")
    }
}

// MARK: - Why there is no conversation

/// The honest explanation, shown only after the listener has actually asked for one.
///
/// Never on launch: a Mac that cannot run Apple Intelligence still answers single
/// requests perfectly well through the heuristic tier, and badging that pane as
/// broken on sight would be a lie about a feature that works — the rule
/// `AssistantView`'s own header already states for the Apple Intelligence caption.
struct LibraryChatNoticeView: View {
    let availability: LibraryChatAvailability

    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let message = Self.message(for: availability) {
            HStack(alignment: .top, spacing: tokens.spacing.xSmall) {
                Image(systemName: "bubble.left.and.exclamationmark.bubble.right")
                    .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: tokens.spacing.xxSmall) {
                    Text(LibraryChatStrings.unavailableTitle)
                        .font(tokens.typography.caption.font)
                        .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
                    Text(message)
                        .font(tokens.typography.caption.font)
                        .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(tokens.spacing.xSmall)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: tokens.radii.small, style: .continuous)
                    .fill(tokens.colors.surfaceRaised.resolve(scheme))
            )
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(LibraryChatStrings.unavailableTitle) + Text(verbatim: ": ") + Text(message))
            .accessibilityIdentifier("assistant.chat.unavailable")
        }
    }

    /// Exhaustive with no `default:` — ``LibraryChatAvailability`` is repo-internal,
    /// so a new state must be given copy here before the shell compiles.
    static func message(for availability: LibraryChatAvailability) -> LocalizedStringResource? {
        switch availability {
        case .ready, .intelligenceOff, .consentRequired:
            // `.intelligenceOff` is the pane's existing disabled StateView, and
            // `.consentRequired` is answered by offering the sheet, not by prose.
            nil
        case .appleIntelligenceUnavailable:
            LibraryChatStrings.unavailableOnDevice
        case .providerCannotChat:
            LibraryChatStrings.unavailableProviderCannotChat
        case .providerNeedsModel:
            LibraryChatStrings.unavailableNeedsModel
        case .consentDeclined:
            LibraryChatStrings.unavailableConsentDeclined
        }
    }
}
