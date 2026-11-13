// IntegrityReportSheet — the file-verification report.
//
// Read-only end to end: it decodes the selected files and says what it found.
// Nothing is written — not a tag, not a database row, not a settings key — so
// unlike ``ReplayGainWriteSheet`` there is no confirm step to stand between the
// listener and their files, and the pass starts as soon as the sheet appears.
//
// The pass is driven by this sheet's own `.task`, which is also what bounds it:
// dismissing the sheet cancels that task, the run loop stops at the next file,
// and every row already produced is simply discarded with the view. The awaits
// inside ``IntegrityReportViewModel/run()`` never occupy the main actor, so the
// progress bar below keeps moving while a 40-minute FLAC decodes.
import DesignSystem
import SwiftUI
import ViewModels

/// A pending verification, shaped for `.sheet(item:)`.
struct IntegrityReportRequest: Identifiable {
    let id = UUID()
    let targets: [IntegrityCheckTarget]
}

/// Verifies a selection and reports what each file's checksum and spectrum show.
struct IntegrityReportSheet: View {
    let targets: [IntegrityCheckTarget]

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss

    @State private var model: IntegrityReportViewModel?

    var body: some View {
        VStack(alignment: .leading, spacing: tokens.spacing.medium) {
            Text(IntegrityStrings.sheetTitle)
                .font(tokens.typography.headline.font)
                .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
            status
            reportList
            Text(IntegrityStrings.caveat)
                .font(tokens.typography.caption.font)
                .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
                .fixedSize(horizontal: false, vertical: true)
            actions
        }
        .padding(tokens.spacing.large)
        .frame(width: 560, height: 520)
        .accessibilityIdentifier("integrity.reportSheet")
        .task { await verify() }
    }
}

// MARK: - Progress and summary

private extension IntegrityReportSheet {
    @ViewBuilder
    var status: some View {
        if let model {
            VStack(alignment: .leading, spacing: tokens.spacing.xxSmall) {
                if model.isRunning {
                    ProgressView(value: model.progressFraction)
                        .accessibilityIdentifier("integrity.report.progress")
                    Text(IntegrityStrings.progress(completed: model.completedCount, total: model.totalCount))
                        .font(tokens.typography.caption.font)
                        .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
                    currentTitle(model)
                } else {
                    Text(Self.summary(checked: model.rows.count, concerns: model.concernCount))
                        .font(tokens.typography.body.font)
                        .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("integrity.report.summary")
                }
            }
        }
    }

    /// The file being decoded right now. Selected as a `Text` value rather than
    /// behind an `if` so the row keeps its identity — and its height — for the
    /// whole pass, instead of the layout jumping on every file boundary.
    func currentTitle(_ model: IntegrityReportViewModel) -> some View {
        Text(verbatim: model.currentTitle ?? "")
            .font(tokens.typography.caption.font)
            .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
            .lineLimit(1)
    }

    static func summary(checked: Int, concerns: Int) -> LocalizedStringResource {
        concerns == 0
            ? IntegrityStrings.summaryClean(checked)
            : IntegrityStrings.summaryConcerns(checked: checked, concerns: concerns)
    }
}

// MARK: - Rows

private extension IntegrityReportSheet {
    var reportList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                let rows = model?.rows ?? []
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    IntegrityReportRowView(row: row)
                    if index < rows.count - 1 {
                        Divider()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(tokens.colors.surface.resolve(scheme).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: tokens.radii.small, style: .continuous))
        .accessibilityIdentifier("integrity.report.list")
    }
}

// MARK: - Actions

private extension IntegrityReportSheet {
    var actions: some View {
        HStack(spacing: tokens.spacing.small) {
            Spacer()
            if let model, model.isRunning {
                Button { model.cancel() } label: { Text(IntegrityStrings.stop) }
                    .help(IntegrityStrings.stopHelp)
                    .pointingHandCursor()
                    .accessibilityIdentifier("integrity.report.stop")
            }
            Button { dismiss() } label: { Text(IntegrityStrings.done) }
                .keyboardShortcut(.defaultAction)
                .pointingHandCursor()
                .accessibilityIdentifier("integrity.report.done")
        }
    }

    /// Builds the run on first appearance and drives it.
    ///
    /// `run()` refuses re-entry, so a second `.task` firing (a re-appearance that
    /// keeps the same view identity) resumes nothing and repeats nothing.
    func verify() async {
        let report = model ?? IntegrityReportViewModel(
            targets: targets,
            verifier: environment.integrity.verifier,
            spectral: environment.integrity.spectral
        )
        model = report
        await report.run()
    }
}
