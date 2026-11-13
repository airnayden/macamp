// StatsInsightsCard — a short prose reading of the SELECTED listening period.
//
// Every other section on the Stats page states figures; this one states what the
// figures mean. It sits directly under the period picker because it narrates that
// period and nothing else — the lifetime "All Time & History" group below has no
// narrative of its own.
//
// ── WHAT THE VIEW IS AND IS NOT RESPONSIBLE FOR ───────────────────────────────
//
// The regenerate-only-on-refresh rule lives entirely in ``StatsInsightsModel``, so
// this file is presentation only: the model decides WHEN a narrative exists, the
// card decides how it looks. The card is also NOT responsible for the gate — the
// insights bundle is checked at the call site in `StatsView`, so a switched-off
// bundle leaves this type absent from the view tree rather than merely hidden.
//
// ── LOCALIZATION SPLIT ────────────────────────────────────────────────────────
//
// The narrative is rendered `Text(verbatim:)` and the chrome around it is
// catalog-localized. Both tiers that can produce the narrative — the on-device
// model and the deterministic templates — emit finished text in the requested
// language, so it is DATA by the time it reaches here; passing it through the
// catalog would try to translate a sentence that was already translated.
//
// ── NO COMBINED ACCESSIBILITY ELEMENT ─────────────────────────────────────────
//
// Deliberately no `.accessibilityElement(children: .combine)`, for the same reason
// `StatsView.statsTrackRow` omits it: the card wraps a live control, and combining
// would erase the refresh button from the VoiceOver tree.
import DesignSystem
import Foundation
import Services
import SwiftUI

/// The narrative card for one ``ListeningWindowDigest``.
struct StatsInsightsCard: View {
    /// The selected period's facets, or `nil` before the first load.
    let digest: ListeningWindowDigest?

    @State private var model: StatsInsightsModel

    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    /// - Parameter narrator: the composition root's narrator. Always a
    ///   `FallbackInsightNarrating`, so an unavailable model degrades to a template
    ///   narrative with nothing surfaced to the listener.
    init(digest: ListeningWindowDigest?, narrator: any InsightNarrating) {
        self.digest = digest
        _model = State(wrappedValue: StatsInsightsModel(narrator: narrator))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: tokens.spacing.xSmall) {
            header
            narrativeBody
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(tokens.spacing.small)
        .background(tokens.colors.surfaceRaised.resolve(scheme))
        .clipShape(RoundedRectangle(cornerRadius: tokens.radii.medium, style: .continuous))
        .task { await model.loadIfNeeded(for: digest) }
    }
}

// MARK: - Chrome

private extension StatsInsightsCard {
    var header: some View {
        HStack(spacing: tokens.spacing.xSmall) {
            Text(StatsInsightsStrings.cardTitle)
                .font(tokens.typography.headline.font)
                .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
                .accessibilityIdentifier("stats.insightsCard")
            Spacer(minLength: tokens.spacing.xSmall)
            refreshButton
        }
    }

    var refreshButton: some View {
        Button {
            Task { await model.refresh(for: digest) }
        } label: {
            Image(systemName: "arrow.clockwise")
                .foregroundStyle(tokens.colors.accent.resolve(scheme))
        }
        .buttonStyle(.plain)
        .disabled(model.isGenerating)
        .pointingHandCursor()
        .help(Text(StatsInsightsStrings.refresh))
        .accessibilityLabel(Text(StatsInsightsStrings.refresh))
        .accessibilityIdentifier("stats.insights.refreshButton")
    }

    @ViewBuilder
    var narrativeBody: some View {
        if let narrative = model.narrative, !narrative.isEmpty {
            Text(verbatim: narrative)
                .font(tokens.typography.body.font)
                .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
                .fixedSize(horizontal: false, vertical: true)
        } else if model.isGenerating {
            Text(StatsInsightsStrings.generating)
                .font(tokens.typography.callout.font)
                .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
        } else {
            Text(StatsInsightsStrings.empty)
                .font(tokens.typography.callout.font)
                .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Copy

/// Localized chrome for the insights card. The narrative itself never passes
/// through here — see this file's header.
enum StatsInsightsStrings {
    static let cardTitle = LocalizedStringResource(
        "app.stats.insights.title",
        defaultValue: "Listening Insights",
        comment: "Title of the card that summarises the selected statistics period in prose"
    )
    static let refresh = LocalizedStringResource(
        "app.stats.insights.refresh",
        defaultValue: "Rewrite insights for this period",
        comment: "Tooltip and accessibility label for the button that regenerates the listening insights text"
    )
    static let generating = LocalizedStringResource(
        "app.stats.insights.generating",
        defaultValue: "Writing your insights…",
        comment: "Placeholder shown while the listening insights text is being generated"
    )
    static let empty = LocalizedStringResource(
        "app.stats.insights.empty",
        defaultValue: "No insights for this period yet.",
        comment: "Placeholder shown when there is nothing to say about the selected statistics period"
    )
}
