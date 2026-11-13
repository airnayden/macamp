// ProposalPreviewSheet — the review step every AI write in MacAMP passes through.
//
// `AssistantViewModel.submit` files a proposal and writes nothing; this sheet is the
// only surface in the shell that calls `apply`. Closing it, discarding, or quitting
// all leave the library exactly as it was.
//
// ── THE TAG GATE ───────────────────────────────────────────────────────────────
//
// `confirmedBatch: true` appears EXACTLY ONCE in this shell — inside the confirmation
// dialog's own confirming button. The sheet's primary Apply button routes a
// `requiresBatchConfirmation` proposal into ``pendingTagConfirmation`` instead of
// applying it, so there is no code path where pressing Apply once rewrites files on
// disk. Cancelling clears the latch and nothing is attempted; the proposal stays in
// the store, still listed, for the listener to reconsider.
//
// Every other kind applies straight from Apply with the default `confirmedBatch:
// false`, which `AssistantViewModel.apply` ignores for them.
//
// ── WHAT IS DATA AND WHAT IS CHROME ────────────────────────────────────────────
//
// Generated names, summaries, file names and proposed tag values are `Text(verbatim:)`
// — they were written in the listener's language at generation time, or read off
// disk, and re-localizing them would be a lie. Every label, button, dialog title and
// failure line is a `LocalizedStringResource` from ``ProposalPreviewStrings``.
import DesignSystem
import Persistence
import SwiftUI
import ViewModels

struct ProposalPreviewSheet: View {
    let proposal: AIProposal

    @Environment(AppEnvironment.self) private var environment
    @Environment(NavigationModel.self) private var nav
    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss

    @State private var model = ProposalPreviewModel()
    @State private var pendingTagConfirmation = false

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
        .task { await model.load(proposal, database: environment.database) }
        .confirmationDialog(
            Text(ProposalPreviewStrings.confirmTitle),
            isPresented: $pendingTagConfirmation,
            titleVisibility: .visible
        ) {
            Button(String(localized: ProposalPreviewStrings.confirmApply)) {
                performApply(confirmedBatch: true)
            }
            .accessibilityIdentifier("assistant.confirmTagsButton")
            Button(String(localized: ProposalPreviewStrings.confirmCancel), role: .cancel) {
                pendingTagConfirmation = false
            }
            .accessibilityIdentifier("assistant.cancelTagsButton")
        } message: {
            Text(ProposalPreviewStrings.confirmMessage(count: proposal.affectedCount))
        }
    }
}

// MARK: - Chrome

private extension ProposalPreviewSheet {
    static let sheetWidth: CGFloat = 540
    static let sheetHeight: CGFloat = 520

    var header: some View {
        HStack(spacing: tokens.spacing.small) {
            RoundedRectangle(cornerRadius: tokens.radii.small, style: .continuous)
                .fill(tokens.colors.accentMuted.resolve(scheme))
                .frame(width: iconChipSide, height: iconChipSide)
                .overlay {
                    Image(systemName: "wand.and.stars")
                        .font(tokens.typography.titleMedium.font)
                        .foregroundStyle(tokens.colors.accent.resolve(scheme))
                }
            Text(ProposalPreviewStrings.title)
                .font(tokens.typography.titleMedium.font)
                .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
            Spacer(minLength: tokens.spacing.xSmall)
            affectedBadge
        }
        .padding(.horizontal, tokens.spacing.large)
        .padding(.vertical, tokens.spacing.small)
    }

    /// "Tracks selected 2/3" once anything is unticked, "Tracks affected 3" before.
    ///
    /// The count is a raw number pair, so it is `Text(verbatim:)`; only the label
    /// beside it is translated. Switching the LABEL rather than interpolating a
    /// sentence keeps the badge out of the interpolated-resource exception the sheet's
    /// strings file documents.
    var affectedBadge: some View {
        HStack(spacing: tokens.spacing.xxSmall) {
            Text(hasExclusions ? ProposalPreviewStrings.selectedLabel : ProposalPreviewStrings.affectedLabel)
                .font(tokens.typography.caption.font)
                .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
            Text(verbatim: badgeCount)
                .font(tokens.typography.caption.font)
                .monospacedDigit()
                .foregroundStyle(tokens.colors.accent.resolve(scheme))
                .padding(.horizontal, tokens.spacing.xSmall)
                .padding(.vertical, tokens.spacing.xxSmall)
                .background(Capsule().fill(tokens.colors.accentMuted.resolve(scheme)))
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("assistant.proposalSelectionCount")
    }

    var hasExclusions: Bool {
        !model.excludedTrackIds.isEmpty
    }

    var badgeCount: String {
        guard hasExclusions else { return "\(proposal.affectedCount)" }
        return "\(model.includedCount(in: proposal))/\(proposal.affectedCount)"
    }

    var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: tokens.spacing.medium) {
                ProposalPreviewSections(proposal: proposal, model: model)
                if model.isTruncated {
                    caption(ProposalPreviewStrings.truncated)
                    caption(ProposalPreviewStrings.truncatedAlwaysIncluded)
                }
                if model.isLoading {
                    caption(ProposalPreviewStrings.loading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(tokens.spacing.large)
        }
        .accessibilityIdentifier("assistant.proposalList")
    }

    var footer: some View {
        VStack(alignment: .leading, spacing: tokens.spacing.xSmall) {
            if let failure = model.failure {
                failureBanner(failure)
            }
            if !isActionable {
                caption(ProposalPreviewStrings.nothingSelected)
                    .accessibilityIdentifier("assistant.nothingSelected")
            }
            HStack(spacing: tokens.spacing.small) {
                discardButton
                Spacer(minLength: tokens.spacing.xSmall)
                applyButton
            }
        }
        .padding(.horizontal, tokens.spacing.large)
        .padding(.vertical, tokens.spacing.small)
    }

    /// The apply-failure banner, published as ONE labelled accessibility element.
    ///
    /// The identifier used to sit on this layout-only `HStack` with nothing collapsing
    /// it, so it propagated to BOTH children and `descendants(...).firstMatch` resolved
    /// to the SF Symbol — a lookup for the banner returned an element whose entire copy
    /// was the word "Warning". Combining first gives the identifier exactly one element
    /// to land on, and naming that element with the failure copy is what a screen reader
    /// should hear anyway: the glyph is decoration, the sentence is the message.
    func failureBanner(_ message: LocalizedStringResource) -> some View {
        HStack(alignment: .top, spacing: tokens.spacing.xSmall) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(tokens.colors.danger.resolve(scheme))
            Text(message)
                .font(tokens.typography.caption.font)
                .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(tokens.spacing.xSmall)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: tokens.radii.small, style: .continuous)
                .fill(tokens.colors.danger.resolve(scheme).opacity(failureBannerOpacity))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(message))
        .accessibilityIdentifier("assistant.applyError")
    }

    func caption(_ text: LocalizedStringResource) -> some View {
        Text(text)
            .font(tokens.typography.caption.font)
            .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
            .fixedSize(horizontal: false, vertical: true)
    }

    var iconChipSide: CGFloat {
        tokens.spacing.large + tokens.spacing.xSmall
    }

    var failureBannerOpacity: Double {
        0.12
    }
}

// MARK: - Actions

private extension ProposalPreviewSheet {
    var discardButton: some View {
        Button {
            // Recorded BEFORE the drop so the card that opened this sheet can offer it
            // again — see ``DiscardedProposalStore``. Applying records nothing.
            environment.discardedProposals.record(proposal)
            environment.intelligence?.assistant.discard(proposal)
            dismiss()
        } label: {
            Text(ProposalPreviewStrings.discard)
                .font(tokens.typography.callout.font)
                .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
                .padding(.horizontal, tokens.spacing.small)
                .padding(.vertical, tokens.spacing.xSmall)
                .background(Capsule().fill(tokens.colors.surfaceRaised.resolve(scheme)))
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .help(ProposalPreviewStrings.discardHelp)
        .accessibilityLabel(Text(ProposalPreviewStrings.discard))
        .accessibilityIdentifier("assistant.discardButton")
    }

    @ViewBuilder
    var applyButton: some View {
        let button = Button(action: primaryApply) {
            Text(ProposalPreviewStrings.apply)
                .font(tokens.typography.callout.font)
                .foregroundStyle(tokens.colors.onAccent.resolve(scheme))
                .padding(.horizontal, tokens.spacing.small)
                .padding(.vertical, tokens.spacing.xSmall)
                .background(Capsule().fill(tokens.colors.accent.resolve(scheme)))
        }
        .buttonStyle(.plain)
        .disabled(!canApply)
        .help(ProposalPreviewStrings.applyHelp)
        .accessibilityLabel(Text(ProposalPreviewStrings.apply))
        .accessibilityIdentifier("assistant.applyButton")

        if canApply {
            button.pointingHandCursor()
        } else {
            button.opacity(disabledOpacity)
        }
    }

    var canApply: Bool {
        environment.intelligence != nil && !model.isApplying && isActionable
    }

    /// Whether the proposal, narrowed to the ticked tracks, would still do anything.
    ///
    /// Unticking the last row leaves a proposal that writes nothing; Apply is disabled
    /// rather than turned into a no-op write, so the sheet never reports success for a
    /// change it did not make.
    var isActionable: Bool {
        ProposalPreviewModel.isActionable(model.filtered(proposal))
    }

    /// The ONLY thing this does for a tag batch is raise the confirmation. It never
    /// passes `confirmedBatch: true` — see the file header.
    func primaryApply() {
        guard canApply else { return }
        if proposal.requiresBatchConfirmation {
            pendingTagConfirmation = true
            return
        }
        performApply(confirmedBatch: false)
    }

    func performApply(confirmedBatch: Bool) {
        guard let assistant = environment.intelligence?.assistant else { return }
        Task { @MainActor in
            let applied = await model.apply(
                proposal,
                using: assistant,
                confirmedBatch: confirmedBatch
            )
            guard applied else { return }
            try? await environment.playlists.loadInitialPlaylists()
            if let playlistId = Self.playlistNeedingTrackReload(after: proposal, openDestination: nav.sidebar) {
                try? await environment.playlists.loadInitialTracks(in: playlistId)
            }
            dismiss()
        }
    }

    var disabledOpacity: Double {
        0.4
    }
}

// MARK: - Post-apply refresh

extension ProposalPreviewSheet {
    /// The playlist whose OPEN track list `proposal` invalidated, or `nil`.
    ///
    /// THE MATCH IS LOAD-BEARING, NOT HYGIENE. ``AppEnvironment`` holds ONE shared
    /// ``PlaylistViewModel`` whose single `tracks` array feeds whichever playlist
    /// detail is on screen, so reloading unconditionally for playlist B while
    /// playlist A is open would repaint A with B's rows. Applying from the assistant
    /// pane reaches here with `.fixed(.assistant)` and correctly reloads nothing —
    /// navigating to the playlist re-runs its `.task(id:)` and loads fresh anyway.
    ///
    /// This extension is internal, unlike the rest of this file: a `private` one
    /// would put the decision out of reach of `@testable import MacAMP`.
    static func playlistNeedingTrackReload(
        after proposal: AIProposal,
        openDestination: SidebarDestination
    ) -> Int64? {
        guard case let .playlist(openPlaylistId) = openDestination,
              let rewritten = rewrittenPlaylistId(in: proposal.kind),
              rewritten == openPlaylistId
        else { return nil }
        return rewritten
    }

    /// The existing playlist whose MEMBERSHIP applying `kind` rewrites, or `nil`.
    ///
    /// Exhaustive with no `default:` — a fifth kind must decide whether it moves rows
    /// in a playlist before the build succeeds.
    static func rewrittenPlaylistId(in kind: AIProposal.Kind) -> Int64? {
        switch kind {
        // A playlist created by the apply itself cannot be the one already open.
        case .createPlaylist: nil
        case let .organize(playlistId, _): playlistId
        // The NAME changes; the membership does not. The list reload above covers it.
        case .rename: nil
        // Tags on disk. No playlist membership moves.
        case .tagChangeSet: nil
        }
    }
}
