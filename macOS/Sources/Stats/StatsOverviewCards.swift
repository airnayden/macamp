// StatsOverviewCards — the four headline figures of the selected period.
//
// Plays, Listening Time, Completion and Skip Rate, laid out in an adaptive grid so
// the row reflows from four columns down to one as the window narrows. Every value
// is rendered `verbatim`: `Int.formatted()`, `Duration.UnitsFormatStyle` and
// `.percent` all resolve the locale themselves, so routing them back through the
// String Catalog would translate them twice. Only the card LABELS are localized.
//
// A card shows an em dash rather than a zero when the period has no plays at all —
// "0%" completion over zero plays would be a fabricated figure, not a measurement.
import DesignSystem
import Foundation
import Services
import SwiftUI

/// The adaptive four-card summary of one ``ListeningWindowDigest``.
struct StatsOverviewCards: View {
    /// The selected period's facets, or `nil` before the first load.
    let window: ListeningWindowDigest?

    /// Completions over plays for the same period. Passed in rather than derived
    /// because the view model computes it over raw ∪ rollups — see
    /// `ListeningStatsViewModel.completionRate(for:)`.
    let completionRate: Double

    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    /// Narrow enough that four cards fit a wide window and one fits a narrow one.
    private static let minimumCardWidth: CGFloat = 150

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: Self.minimumCardWidth), spacing: tokens.spacing.small)],
            alignment: .leading,
            spacing: tokens.spacing.small
        ) {
            card(StatsStrings.cardPlays, value: playsValue)
            card(StatsStrings.cardListeningTime, value: listeningTimeValue)
            card(StatsStrings.cardCompletion, value: completionValue)
            card(StatsStrings.cardSkipRate, value: skipRateValue)
        }
    }

    private func card(_ label: LocalizedStringResource, value: String) -> some View {
        VStack(alignment: .leading, spacing: tokens.spacing.xxSmall) {
            Text(label)
                .font(tokens.typography.caption.font)
                .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
                .lineLimit(1)
            Text(verbatim: value)
                .font(tokens.typography.titleMedium.font.monospacedDigit())
                .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(tokens.spacing.small)
        .background(tokens.colors.surfaceRaised.resolve(scheme))
        .clipShape(RoundedRectangle(cornerRadius: tokens.radii.medium, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Values

private extension StatsOverviewCards {
    /// `true` only when the period actually recorded something. Every card falls
    /// back to a placeholder otherwise.
    var hasPlays: Bool {
        (window?.totalPlays ?? 0) > 0
    }

    var playsValue: String {
        guard hasPlays, let window else { return StatsValueFormat.placeholder }
        return window.totalPlays.formatted()
    }

    var listeningTimeValue: String {
        guard hasPlays, let window else { return StatsValueFormat.placeholder }
        return StatsValueFormat.abbreviatedDuration(window.totalListenedSeconds)
    }

    var completionValue: String {
        guard hasPlays else { return StatsValueFormat.placeholder }
        return StatsValueFormat.percent(completionRate)
    }

    var skipRateValue: String {
        guard hasPlays, let window else { return StatsValueFormat.placeholder }
        return StatsValueFormat.percent(window.skipRate)
    }
}

// MARK: - Shared value formatting

/// The ONE place the stats page turns numbers into display strings, so every
/// surface on it renders a duration or a ratio identically. Reused by the section
/// views (top lists, most replayed, recent plays) rather than re-derived there.
///
/// Everything it returns is already locale-resolved and MUST be rendered with
/// `Text(verbatim:)`.
enum StatsValueFormat {
    /// Shown instead of a zero when there is genuinely nothing to measure.
    static let placeholder = "—"

    /// An abbreviated duration that can never come back empty.
    ///
    /// `Duration.UnitsFormatStyle` hides zero-valued units by default, so
    /// `[.hours, .minutes]` renders an EMPTY string for anything under a minute.
    /// Sub-minute totals therefore fall back to seconds with zero units shown.
    static func abbreviatedDuration(_ seconds: Double) -> String {
        let clamped = max(0, seconds)
        guard clamped >= 60 else {
            return Duration.seconds(clamped)
                .formatted(.units(allowed: [.seconds], width: .abbreviated, zeroValueUnits: .show(length: 1)))
        }
        return Duration.seconds(clamped)
            .formatted(.units(allowed: [.hours, .minutes], width: .abbreviated, maximumUnitCount: 2))
    }

    /// A whole-number percentage from a `0…1` ratio.
    static func percent(_ ratio: Double) -> String {
        ratio.formatted(.percent.precision(.fractionLength(0)))
    }
}
