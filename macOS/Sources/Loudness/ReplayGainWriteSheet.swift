// ReplayGainWriteSheet — the confirmation standing between a selection and a write
// to the listener's own audio files.
//
// It is presented with a ``ReplayGainTagWritePlan`` that was already partitioned, so
// the file count it names is the count that will actually be rewritten and the
// refusal lines are per-reason rather than one lump "skipped" figure. Writing tags
// modifies files MacAMP does not own; nothing here happens until Write Tags is
// pressed, and a plan with nothing eligible disables that button outright.
import DesignSystem
import SwiftUI
import ViewModels

/// A pending tag-write confirmation, shaped for `.sheet(item:)`.
struct ReplayGainWriteRequest: Identifiable {
    let id = UUID()
    let plan: ReplayGainTagWritePlan
}

/// Names what a confirmed ReplayGain tag write would change, and performs it.
struct ReplayGainWriteSheet: View {
    let plan: ReplayGainTagWritePlan

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss

    @State private var isWriting = false

    var body: some View {
        VStack(alignment: .leading, spacing: tokens.spacing.medium) {
            Text(ReplayGainTagStrings.sheetTitle)
                .font(tokens.typography.headline.font)
                .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
            summary
            skipLines
            Text(ReplayGainTagStrings.unmeasuredNote)
                .font(tokens.typography.caption.font)
                .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
                .fixedSize(horizontal: false, vertical: true)
            actions
        }
        .padding(tokens.spacing.large)
        .frame(width: 420)
        .accessibilityIdentifier("loudness.writeTagsSheet")
    }
}

// MARK: - Content

private extension ReplayGainWriteSheet {
    var summary: some View {
        Text(plan.canConfirm
            ? ReplayGainTagStrings.fileCount(plan.eligibleCount)
            : ReplayGainTagStrings.nothingEligible)
            .font(tokens.typography.body.font)
            .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("loudness.writeTagsSummary")
    }

    @ViewBuilder
    var skipLines: some View {
        if !plan.skipped.isEmpty {
            VStack(alignment: .leading, spacing: tokens.spacing.xxSmall) {
                ForEach(plan.skipped, id: \.reason) { skip in
                    Text(Self.message(for: skip))
                        .font(tokens.typography.caption.font)
                        .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityIdentifier("loudness.writeTagsSkipped")
        }
    }

    /// One line per refusal reason. Exhaustive by construction: a new
    /// ``ReplayGainTagUnsupportedReason`` fails this switch to compile rather than
    /// reaching a listener as an unexplained skip.
    static func message(for skip: ReplayGainTagSkip) -> LocalizedStringResource {
        switch skip.reason {
        case .oggFamilyMayCarryR128:
            ReplayGainTagStrings.skipOggFamily(skip.count)
        case .mp4BackendDiscardsTags:
            ReplayGainTagStrings.skipMP4Family(skip.count)
        case .formatNotVerified:
            ReplayGainTagStrings.skipUnverified(skip.count)
        }
    }

    var actions: some View {
        HStack(spacing: tokens.spacing.small) {
            Spacer()
            Button(role: .cancel) { dismiss() } label: {
                Text(ReplayGainTagStrings.cancel)
            }
            .pointingHandCursor()
            .accessibilityIdentifier("loudness.writeTagsCancel")
            Button(action: write) { Text(ReplayGainTagStrings.confirm) }
                .keyboardShortcut(.defaultAction)
                .disabled(!plan.canConfirm || isWriting)
                .pointingHandCursor()
                .accessibilityIdentifier("loudness.writeTagsConfirm")
        }
    }
}

// MARK: - The confirmed write

private extension ReplayGainWriteSheet {
    func write() {
        guard plan.canConfirm, !isWriting else { return }
        isWriting = true
        let plan = plan
        Task {
            let outcome = await environment.loudness.tagWriter.write(plan)
            isWriting = false
            announce(outcome)
            dismiss()
        }
    }

    func announce(_ outcome: ReplayGainTagWriteOutcome) {
        if outcome.failed > 0 {
            environment.toast.show(
                text: String(localized: ReplayGainTagStrings.failedToast(outcome.failed)),
                icon: "exclamationmark.triangle"
            )
        } else if outcome.written > 0 {
            environment.toast.show(
                text: String(localized: ReplayGainTagStrings.writtenToast(outcome.written)),
                icon: "tag"
            )
        } else {
            environment.toast.show(
                text: String(localized: ReplayGainTagStrings.nothingWrittenToast),
                icon: "waveform.badge.magnifyingglass"
            )
        }
    }
}
