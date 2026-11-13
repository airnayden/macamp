// IntegrityReportRowView — one file's line in the verification report.
//
// Every row carries BOTH readings, always, even when one of them says nothing was
// established. A row that simply omitted the checksum line for an MP3 would read
// as "checked and fine"; saying "not a FLAC stream" out loud is the whole point.
//
// The leading marker is keyed off the row's readings rather than off
// `needsAttention` alone, so a definite checksum mismatch and a merely suspicious
// spectrum are not drawn in the same register — see ``IntegrityRowCopy``.
import DesignSystem
import Persistence
import SwiftUI
import ViewModels

struct IntegrityReportRowView: View {
    let row: IntegrityReportRow

    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(alignment: .top, spacing: tokens.spacing.small) {
            marker
            VStack(alignment: .leading, spacing: tokens.spacing.xxSmall) {
                titleLine
                reading(
                    label: IntegrityStrings.columnChecksum,
                    value: IntegrityRowCopy.text(for: row.checksum),
                    severity: IntegrityRowCopy.severity(for: row.checksum)
                )
                reading(
                    label: IntegrityStrings.columnSpectrum,
                    value: IntegrityRowCopy.text(for: row.spectral),
                    severity: IntegrityRowCopy.severity(for: row.spectral)
                )
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, tokens.spacing.xSmall)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("integrity.report.row")
    }
}

// MARK: - Parts

private extension IntegrityReportRowView {
    var titleLine: some View {
        HStack(spacing: tokens.spacing.xxSmall) {
            Text(verbatim: row.title)
                .font(tokens.typography.body.font)
                .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
                .lineLimit(1)
            availabilityBadge
        }
    }

    @ViewBuilder
    var availabilityBadge: some View {
        switch row.availability {
        case .present:
            EmptyView()
        case .missing:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(tokens.colors.warning.resolve(scheme))
                .accessibilityLabel(Text(MacAMPStrings.badgeMissing))
        case .externalOffline:
            Image(systemName: "externaldrive.badge.xmark")
                .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
                .accessibilityLabel(Text(MacAMPStrings.badgeOffline))
        }
    }

    /// One reading: its heading and its verdict, as two independently localized
    /// `Text`s. Never concatenated — a translator must be free to reorder them.
    func reading(
        label: LocalizedStringResource,
        value: LocalizedStringResource,
        severity: IntegritySeverity
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: tokens.spacing.xxSmall) {
            Text(label)
                .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
            Text(value)
                .foregroundStyle(color(for: severity))
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(tokens.typography.caption.font)
    }

    @ViewBuilder
    var marker: some View {
        switch severity {
        case .bad:
            markerImage("exclamationmark.octagon.fill", tint: tokens.colors.danger.resolve(scheme))
        case .caution:
            markerImage("exclamationmark.triangle.fill", tint: tokens.colors.warning.resolve(scheme))
        case .good:
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(tokens.colors.success.resolve(scheme))
                .accessibilityHidden(true)
        case .neutral:
            Image(systemName: "minus.circle")
                .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
                .accessibilityHidden(true)
        }
    }

    func markerImage(_ symbol: String, tint: Color) -> some View {
        Image(systemName: symbol)
            .foregroundStyle(tint)
            .accessibilityLabel(Text(IntegrityStrings.rowAttention))
    }
}

// MARK: - Emphasis

private extension IntegrityReportRowView {
    /// The row's overall emphasis: a definite checksum finding outranks a merely
    /// suspicious spectrum, and a clean checksum is only "good" when the spectral
    /// reading raised nothing either.
    var severity: IntegritySeverity {
        let checksum = IntegrityRowCopy.severity(for: row.checksum)
        let spectrum = IntegrityRowCopy.severity(for: row.spectral)
        if checksum == .bad { return .bad }
        if checksum == .caution || spectrum == .caution { return .caution }
        return checksum
    }

    func color(for severity: IntegritySeverity) -> Color {
        switch severity {
        case .good: tokens.colors.success.resolve(scheme)
        case .neutral: tokens.colors.textSecondary.resolve(scheme)
        case .caution: tokens.colors.warning.resolve(scheme)
        case .bad: tokens.colors.danger.resolve(scheme)
        }
    }
}
