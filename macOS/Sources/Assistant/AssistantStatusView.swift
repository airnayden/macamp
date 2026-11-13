// AssistantStatusView — the request field's answer when there is no playlist to show,
// and its footnote when the playlist did not come from the provider the listener chose.
//
// WHY A PERSISTENT ROW AND NOT A TOAST. `AssistantViewModel.submit` reports every
// failure through ``AssistantViewModel/lastError`` and returns `nil`; the pane used to
// discard that `nil` silently, so a request that matched nothing looked exactly like a
// request that was never sent. A toast is the wrong repair for that: it is gone in
// 2.5 seconds, and the listener's next action is to re-read what they typed and try
// again — which needs the reason still on screen. The row therefore stays until the
// next submit clears it, and the toast (if any) is additive.
//
// TWO INDEPENDENT SIGNALS, ONE ROW. `lastError` says "there is no proposal";
// ``AssistantTierDiagnostic`` says "the tier you picked went quiet". They are
// orthogonal and can both be set, so the strongest form of this view is a failure
// banner with the provider note beneath it. With a proposal produced, only the note
// shows — subdued, non-blocking, informational.
import DesignSystem
import SwiftUI
import ViewModels

struct AssistantStatusView: View {
    let error: AssistantProposalError?
    let diagnostic: AssistantTierDiagnostic?

    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let error {
            failureBanner(error)
        } else if let notice = AssistantErrorCopy.notice(for: diagnostic) {
            noticeRow(notice)
        }
    }
}

// MARK: - Regions

private extension AssistantStatusView {
    func failureBanner(_ error: AssistantProposalError) -> some View {
        HStack(alignment: .top, spacing: tokens.spacing.xSmall) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(tokens.colors.danger.resolve(scheme))
            VStack(alignment: .leading, spacing: tokens.spacing.xxSmall) {
                Text(AssistantErrorCopy.message(for: error))
                    .font(tokens.typography.caption.font)
                    .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
                    .fixedSize(horizontal: false, vertical: true)
                if let notice = AssistantErrorCopy.notice(for: diagnostic) {
                    Text(notice)
                        .font(tokens.typography.caption.font)
                        .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(tokens.spacing.xSmall)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: tokens.radii.small, style: .continuous)
                .fill(tokens.colors.danger.resolve(scheme).opacity(bannerFillOpacity))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(bannerLabel(error))
        .accessibilityIdentifier("assistant.errorBanner")
    }

    /// Every line the banner draws, spoken as one label.
    ///
    /// The provider note is a SECOND child `Text`, and a composed label must carry it
    /// too — dropping it would leave VoiceOver saying only that the request failed,
    /// on exactly the request where the interesting fact is WHICH tier went quiet.
    func bannerLabel(_ error: AssistantProposalError) -> Text {
        let spoken = Self.spoken(AssistantPaneStrings.errorBannerLabel, AssistantErrorCopy.message(for: error))
        guard let notice = AssistantErrorCopy.notice(for: diagnostic) else { return spoken }
        return spoken + Text(verbatim: " ") + Text(notice)
    }

    func noticeRow(_ notice: LocalizedStringResource) -> some View {
        HStack(alignment: .top, spacing: tokens.spacing.xSmall) {
            Image(systemName: "info.circle")
                .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
            Text(notice)
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
        .accessibilityLabel(Self.spoken(AssistantPaneStrings.noticeLabel, notice))
        .accessibilityIdentifier("assistant.providerNotice")
    }

    var bannerFillOpacity: Double {
        0.12
    }

    /// "<role>: <message>" as one accessibility label.
    ///
    /// `.accessibilityElement(children: .combine)` builds a label out of the child
    /// text, and a bare `.accessibilityLabel` REPLACES it — which silently reduced
    /// VoiceOver to announcing "Request problem" with no reason attached. Composing
    /// keeps the role prefix AND the sentence the sighted user reads.
    static func spoken(_ role: LocalizedStringResource, _ message: LocalizedStringResource) -> Text {
        Text(role) + Text(verbatim: ": ") + Text(message)
    }
}

// MARK: - Copy

/// The pane's side of the two diagnostics, both exhaustive with no `default:` —
/// ``AssistantProposalError`` and ``AssistantTierDiagnostic`` are repo-internal, so a
/// new case must be given copy here before the shell compiles.
enum AssistantErrorCopy {
    static func message(for error: AssistantProposalError) -> LocalizedStringResource {
        switch error {
        case .noMatchingTracks: AssistantPaneStrings.errorNoMatchingTracks
        case .generationFailed: AssistantPaneStrings.errorGenerationFailed
        case let .assistantUnavailable(reason): reason.message
        case .batchNotConfirmed: ProposalPreviewStrings.failureBatchNotConfirmed
        case .unknownProposal: ProposalPreviewStrings.failureUnknownProposal
        case .playlistNotCreated: ProposalPreviewStrings.failurePlaylistNotCreated
        case .playlistNotFound: ProposalPreviewStrings.failurePlaylistNotFound
        case .playlistChanged: ProposalPreviewStrings.failurePlaylistChanged
        case .metadataWriterUnavailable: ProposalPreviewStrings.failureWriterUnavailable
        case .tagWriteFailed: ProposalPreviewStrings.failureTagWrite
        }
    }

    static func notice(for diagnostic: AssistantTierDiagnostic?) -> LocalizedStringResource? {
        switch diagnostic {
        case .none: nil
        case .connectorUnavailable: AssistantPaneStrings.noticeConnectorUnavailable
        case .connectorTimedOut: AssistantPaneStrings.noticeConnectorTimedOut
        case .connectorFailed: AssistantPaneStrings.noticeConnectorFailed
        case .modelFailed: AssistantPaneStrings.noticeModelFailed
        }
    }
}

#Preview {
    VStack(spacing: 12) {
        AssistantStatusView(error: .noMatchingTracks, diagnostic: .connectorTimedOut)
        AssistantStatusView(error: nil, diagnostic: .connectorUnavailable)
    }
    .padding()
    .frame(width: 420)
    .designTokens(.standard)
}
