// HygieneDetailView — the surface the "Things worth reviewing" card opens.
//
// The card used to be a dead teaser: it counted findings and offered no way to see
// them. This sheet is that way. It READS ONLY — the hygiene pass is a read, the
// findings are inert values, and the one thing a button here can do is hand a
// proposal to ``ProposalPreviewSheet``, which is still the only surface in the shell
// that calls `apply`.
//
// ── WHY A SHEET, NOT A SIDEBAR DESTINATION ─────────────────────────────────────
//
// The assistant pane already presents `ProposalPreviewSheet` this way, so a second
// sheet is the shape the pane is already built for. A `SidebarDestination` case
// would ripple through `NavigationModel`, its Codable persistence, the restore
// reconciler and the dangle guards — for a list the listener opens, acts on, and
// closes.
//
// ── ONE PROPOSAL AT A TIME ─────────────────────────────────────────────────────
//
// A single finding can be actionable as SEVERAL proposals (one duplicate recording
// listed twice in three playlists is three membership rewrites), and Review All is
// a whole section at once. They are queued and presented one after another through
// `onDismiss:` — the documented way to chain sheets — rather than merged, because
// merging would produce one proposal whose headline could not say what it changes.
import DesignSystem
import Services
import SwiftUI
import ViewModels

struct HygieneDetailView: View {
    /// The pass to run. `nil` when the hygiene bundle is off — the sheet then shows
    /// its empty state rather than an error, because the card that opens it is gated
    /// on the same switch.
    let hygiene: (any LibraryHygieneProviding)?
    let profileId: Int64

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss

    @State private var model = HygieneDetailModel()
    @State private var presentedProposal: AIProposal?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: Self.sheetWidth, height: Self.sheetHeight)
        .background(tokens.colors.surface.resolve(scheme))
        .task { await model.load(profileId: profileId, hygiene: hygiene) }
        .sheet(item: $presentedProposal, onDismiss: advance) { proposal in
            ProposalPreviewSheet(proposal: proposal)
        }
    }
}

// MARK: - Chrome

private extension HygieneDetailView {
    static let sheetWidth: CGFloat = 620
    static let sheetHeight: CGFloat = 560

    var header: some View {
        HStack(alignment: .top, spacing: tokens.spacing.small) {
            RoundedRectangle(cornerRadius: tokens.radii.small, style: .continuous)
                .fill(tokens.colors.accentMuted.resolve(scheme))
                .frame(width: iconChipSide, height: iconChipSide)
                .overlay {
                    Image(systemName: "sparkles.rectangle.stack")
                        .font(tokens.typography.titleMedium.font)
                        .foregroundStyle(tokens.colors.accent.resolve(scheme))
                }
            VStack(alignment: .leading, spacing: tokens.spacing.xxSmall) {
                // The identifier sits on this LEAF rather than on the enclosing
                // stack: SwiftUI propagates a container's identifier down over its
                // children's own, which is how the Intelligence pane's status row
                // came to hide two buttons from the accessibility API.
                Text(HygieneDetailStrings.title)
                    .font(tokens.typography.titleMedium.font)
                    .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
                    .accessibilityIdentifier("assistant.hygiene.sheet")
                Text(HygieneDetailStrings.subtitle)
                    .font(tokens.typography.caption.font)
                    .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: tokens.spacing.xSmall)
        }
        .padding(.horizontal, tokens.spacing.large)
        .padding(.vertical, tokens.spacing.small)
    }

    @ViewBuilder
    var content: some View {
        if model.isEmpty {
            StateView(
                systemImage: model.didLoad ? "checkmark.seal" : nil,
                showsProgress: !model.didLoad,
                title: model.didLoad ? HygieneDetailStrings.emptyTitle : AssistantPaneStrings.loading,
                message: model.didLoad ? HygieneDetailStrings.emptyMessage : nil
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: tokens.spacing.medium) {
                    ForEach(model.sections) { section in
                        sectionView(section)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(tokens.spacing.large)
            }
            .accessibilityIdentifier("assistant.hygiene.list")
        }
    }

    var footer: some View {
        HStack(spacing: tokens.spacing.small) {
            Spacer(minLength: tokens.spacing.xSmall)
            Button { dismiss() } label: {
                Text(HygieneDetailStrings.close)
                    .font(tokens.typography.callout.font)
                    .foregroundStyle(tokens.colors.onAccent.resolve(scheme))
                    .padding(.horizontal, tokens.spacing.small)
                    .padding(.vertical, tokens.spacing.xSmall)
                    .background(Capsule().fill(tokens.colors.accent.resolve(scheme)))
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help(HygieneDetailStrings.closeHelp)
            .accessibilityLabel(Text(HygieneDetailStrings.close))
            .accessibilityIdentifier("assistant.hygiene.closeButton")
        }
        .padding(.horizontal, tokens.spacing.large)
        .padding(.vertical, tokens.spacing.small)
    }

    var iconChipSide: CGFloat {
        tokens.spacing.large + tokens.spacing.xSmall
    }
}

// MARK: - Sections

private extension HygieneDetailView {
    func sectionView(_ section: HygieneDetailModel.Section) -> some View {
        VStack(alignment: .leading, spacing: tokens.spacing.xSmall) {
            HStack(spacing: tokens.spacing.xSmall) {
                Text(section.kind.title)
                    .font(tokens.typography.caption.font)
                    .textCase(.uppercase)
                    .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
                countBadge(section.rows.count)
                Spacer(minLength: tokens.spacing.xxSmall)
                if section.isActionable {
                    reviewAllButton(section)
                }
            }
            ForEach(section.rows) { row in
                HygieneFindingRow(row: row) { review(row.proposals) }
            }
        }
    }

    func countBadge(_ count: Int) -> some View {
        Text(verbatim: "\(count)")
            .font(tokens.typography.caption.font)
            .monospacedDigit()
            .foregroundStyle(tokens.colors.accent.resolve(scheme))
            .padding(.horizontal, tokens.spacing.xSmall)
            .padding(.vertical, tokens.spacing.xxSmall)
            .background(Capsule().fill(tokens.colors.accentMuted.resolve(scheme)))
    }

    func reviewAllButton(_ section: HygieneDetailModel.Section) -> some View {
        Button { review(section.batch) } label: {
            Text(HygieneDetailStrings.reviewAll)
                .font(tokens.typography.caption.font)
                .foregroundStyle(tokens.colors.accent.resolve(scheme))
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .help(HygieneDetailStrings.reviewAllHelp)
        .accessibilityLabel(Text(HygieneDetailStrings.reviewAll))
        .accessibilityIdentifier("assistant.hygiene.reviewAll.\(section.kind.rawValue)")
    }
}

// MARK: - Review queue

private extension HygieneDetailView {
    /// Files the batch and shows its first proposal. The rest follow as each sheet
    /// closes — see ``advance``.
    func review(_ proposals: [AIProposal]) {
        guard let assistant = environment.intelligence?.assistant else { return }
        model.enqueue(proposals, into: assistant.proposals)
        advance()
    }

    /// Presents the next queued proposal, or — once the batch is exhausted — re-runs
    /// the pass if anything was applied, so an accepted fix stops being listed.
    ///
    /// Nothing clears ``presentedProposal`` here: on the `onDismiss` path SwiftUI has
    /// already written `nil` through the binding, and on the `review` path it was
    /// never set.
    func advance() {
        if let next = model.dequeue() {
            presentedProposal = next
            return
        }
        guard let assistant = environment.intelligence?.assistant,
              model.consumeDidApply(from: assistant.proposals)
        else { return }
        Task { @MainActor in
            await model.load(profileId: profileId, hygiene: hygiene)
        }
    }
}

#Preview {
    HygieneDetailView(hygiene: nil, profileId: 1)
        .environment(AppEnvironment.preview())
        .designTokens(.standard)
}
