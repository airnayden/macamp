// AssistantView+PendingProposals — a route back to a proposal nobody is holding.
//
// ── THE GAP THIS CLOSES ──────────────────────────────────────────────────────
//
// `ProposalStore` outlives whatever produced a proposal, but until now every route
// to one was owned by its PRODUCER: `submit` presents its sheet immediately, the
// hygiene sheet presents its own, and W4's transcript renders a card keyed to the
// chat message that filed it. A proposal with no producer on screen — a chat that
// was reset, a sheet dismissed without applying, and now one filed over MCP by a
// program outside this app — was unreachable while still sitting in the store.
//
// So the feed grows one section that reads the STORE, which is the only surface
// that can honestly claim to list everything awaiting a decision. It opens the
// existing ``ProposalPreviewSheet`` through the existing `AssistantSheet.proposal`
// case; nothing about review or apply changes, and this file adds no write path.
//
// A sibling extension, not more lines in `AssistantView.swift`: that file is at 383
// of SwiftLint's 400-line ceiling, the same reason `AssistantView+Chat.swift` exists.
import DesignSystem
import SwiftUI
import ViewModels

extension AssistantView {
    /// Everything awaiting a decision, newest last — the store's own order.
    var pendingProposals: [AIProposal] {
        environment.intelligence?.proposals.proposals ?? []
    }

    @ViewBuilder
    var pendingSection: some View {
        if !pendingProposals.isEmpty {
            VStack(alignment: .leading, spacing: tokens.spacing.xSmall) {
                // Restated, not reused: `sectionHeader` is `private` to
                // `AssistantView.swift`, and widening it for three lines would open
                // the whole feed implementation to every future sibling.
                Text(AssistantPaneStrings.pendingTitle)
                    .font(tokens.typography.caption.font)
                    .textCase(.uppercase)
                    .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
                ForEach(pendingProposals) { proposal in
                    AssistantSuggestionCard(
                        systemImage: "tray.full",
                        title: title(for: proposal),
                        subtitle: Text(AssistantPaneStrings.pendingSubtitle),
                        count: proposal.affectedCount,
                        actionHint: AssistantPaneStrings.pendingOpen,
                        action: { presented = .proposal(proposal) }
                    )
                    .accessibilityIdentifier("assistant.card.pending.\(proposal.id.uuidString)")
                }
            }
        }
    }

    /// A proposal's own name is GENERATED CONTENT and therefore DATA — rendered
    /// verbatim, never composed into a localized sentence. The two kinds that carry
    /// no name fall back to catalog copy.
    private func title(for proposal: AIProposal) -> Text {
        switch proposal.kind {
        case let .createPlaylist(request): Text(verbatim: request.name)
        case let .rename(_, name): Text(verbatim: name)
        case .organize, .tagChangeSet: Text(AssistantPaneStrings.pendingUnnamed)
        }
    }
}
