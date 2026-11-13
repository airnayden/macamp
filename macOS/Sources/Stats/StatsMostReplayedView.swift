// StatsMostReplayedView — the songs whose INSIDES you keep going back to.
//
// Every other list on this page ranks whole plays. This one ranks *within* a song:
// `playSegmentHeat` records where the playhead actually spent its time, so a track
// earns its place here by having a part people rewind to, not by being played a lot.
// A 4-pass track with one obsessively repeated chorus outranks a 50-pass track played
// evenly front to back, which is why the affinity percentage — not the pass count —
// is the emphasized figure in the row.
//
// **The curve is the point of the section.** `ReplayHeatCurve` is reused verbatim
// from the scrubber overlay, so the shape under a row is the SAME shape that appears
// behind the seek bar when that track plays: peaks sit at the positions in the song
// they describe. It is intentionally not a new "mini" component — a second renderer
// would be free to drift from the one the scrubber draws, and then the page would be
// quietly lying about where the replays are.
//
// `intensities` is optional and is ALWAYS optional-bound: a heatmap whose bucket blob
// failed to decode still produces a ranked row with real numbers, and that row must
// render its text rather than trap.
//
// The view computes no statistics. Ranking, the noise floor
// (`ReplayHeatAnalysis.hasTrustworthyShape`) and the 0…1 normalization all happen
// in `ListeningStatsViewModel`; the only derivation here is the display `.prefix`.
import DesignSystem
import Foundation
import Services
import SwiftUI
import ViewModels

/// The all-time Most Replayed section: ranked rows, each with its own replay curve.
struct StatsMostReplayedView: View {
    /// Rows ordered exactly as ``ListeningDigest/mostReplayed`` orders them, already
    /// filtered and capped by the view model. An empty array hides the section.
    let rows: [ReplayedRow]

    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    /// Tall enough to read a shape in, short enough that ten stacked rows still scan
    /// as a list rather than as a column of charts.
    private static let curveHeight: CGFloat = 16

    var body: some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: tokens.spacing.small) {
                header
                LazyVStack(spacing: 0) {
                    ForEach(displaySlice) { row in
                        replayRow(row)
                    }
                }
            }
        }
    }

    /// The view model already caps the ranking at the digest's own entity limit;
    /// this is the display slice over it, mirroring `StatsTopListsView`.
    private var displaySlice: [ReplayedRow] {
        Array(rows.prefix(ListeningStatsViewModel.replayedDisplayLimit))
    }
}

// MARK: - Chrome

private extension StatsMostReplayedView {
    var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(StatsStrings.mostReplayed)
                .font(tokens.typography.headline.font)
                .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
            // The caption states `ReplayHeatAnalysis.hasTrustworthyShape` in words:
            // three full listens OR one passage heard three times. It is applied once,
            // when the view model ranks the rows — never re-checked here.
            Text(StatsStrings.replayedCaption)
                .font(tokens.typography.caption.font)
                .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Rows

private extension StatsMostReplayedView {
    /// Playable only while the snapshot still resolves to a live library row —
    /// `statsRowActions(for:)` adds nothing at all for `nil`, so a row whose track
    /// was deleted keeps its numbers and its curve and simply stops being clickable.
    func replayRow(_ row: ReplayedRow) -> some View {
        VStack(alignment: .leading, spacing: tokens.spacing.xxSmall) {
            HStack(spacing: tokens.spacing.small) {
                VStack(alignment: .leading, spacing: 0) {
                    primaryText(displayName(row.identity.title))
                    secondaryText(displayName(row.identity.artistName))
                }
                Spacer(minLength: tokens.spacing.small)
                metrics(passes: row.totalPasses, affinity: row.replayAffinity)
            }
            curve(row.intensities)
        }
        .padding(.vertical, tokens.spacing.xxSmall)
        .accessibilityElement(children: .combine)
        .statsRowActions(for: row.resolved)
    }

    /// Draws nothing at all when the heatmap could not be decoded, rather than
    /// reserving an empty strip — the row above simply closes up.
    @ViewBuilder
    func curve(_ intensities: [Float]?) -> some View {
        if let intensities {
            ReplayHeatCurve(intensities: intensities, isRevealed: true)
                .frame(maxWidth: .infinity)
                .frame(height: Self.curveHeight)
                .allowsHitTesting(false)
                // A shape VoiceOver cannot describe, next to numbers that already say
                // it: kept out of the row's combined spoken text.
                .accessibilityHidden(true)
        }
    }
}

// MARK: - Row parts

private extension StatsMostReplayedView {
    func primaryText(_ value: String) -> some View {
        Text(verbatim: value)
            .font(tokens.typography.body.font)
            .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
            .lineLimit(1)
    }

    func secondaryText(_ value: String) -> some View {
        Text(verbatim: value)
            .font(tokens.typography.caption.font)
            .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
            .lineLimit(1)
    }

    /// Passes read plainly; affinity is emphasized because it is what the ranking is
    /// actually sorted on. The percentage carries no visible label of its own, so it
    /// names itself through a tooltip and an accessibility label/value pair.
    func metrics(passes: Int, affinity: Double) -> some View {
        let affinityValue = StatsValueFormat.percent(affinity)
        return HStack(spacing: tokens.spacing.small) {
            Text(StatsStrings.passes(count: passes))
                .font(tokens.typography.caption.font.monospacedDigit())
                .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
                .lineLimit(1)
            Text(verbatim: affinityValue)
                .font(tokens.typography.caption.font.monospacedDigit().bold())
                .foregroundStyle(tokens.colors.accent.resolve(scheme))
                .help(Text(StatsStrings.replayAffinity))
                .accessibilityLabel(Text(StatsStrings.replayAffinity))
                .accessibilityValue(Text(verbatim: affinityValue))
        }
    }

    /// The one fallback for a name the history never captured — `nil` snapshot text,
    /// or the empty-string sentinel unknowns are grouped under.
    func displayName(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return String(localized: StatsStrings.unknown) }
        return value
    }
}

#Preview {
    // Sample names are bound to locals because `title:` is one of the argument labels
    // the hardcoded-text guard scans; preview fixtures are not translatable copy.
    let curvedTitle = "Roygbiv"
    let flatTitle = "Olson"
    let artist = "Boards of Canada"
    let curve: [Float] = (0 ..< ReplayHeatGeometry.bucketCount).map { index in
        let position = Double(index) / Double(ReplayHeatGeometry.bucketCount - 1)
        return Float(0.2 + 0.8 * pow(sin(position * .pi * 3), 2))
    }

    StatsMostReplayedView(rows: [
        ReplayedRow(
            identity: ListeningTrackIdentity(artistName: artist, title: curvedTitle, albumTitle: nil),
            trackId: 1,
            resolved: nil,
            intensities: curve,
            totalPasses: 12,
            replayAffinity: 0.62
        ),
        // The undecodable-heatmap path: a ranked row with no curve to draw.
        ReplayedRow(
            identity: ListeningTrackIdentity(artistName: nil, title: flatTitle, albumTitle: nil),
            trackId: 2,
            resolved: nil,
            intensities: nil,
            totalPasses: 3,
            replayAffinity: 0.18
        ),
    ])
    .environment(AppEnvironment.preview())
    .designTokens(.standard)
    .padding()
    .frame(width: 720)
}
