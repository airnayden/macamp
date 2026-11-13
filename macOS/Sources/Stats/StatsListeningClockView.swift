// StatsListeningClockView — when during the day and the week this profile listens.
//
// Two static bar charts over the selected period's histograms, plus the one-line
// verdict ("Most active: Evening").
//
// **The view computes no statistics.** `hourHistogram` and `weekdayHistogram` arrive
// fully binned from `ListeningDigestBuilder`, and the visible claim is
// `ListeningStatsViewModel.mostActiveDaypart` — a computed property its own suite
// covers. The one derivation here is `peakBin`, which picks the tallest already-binned
// bar so VoiceOver has something to announce; that is a spoken-summary concern, not a
// figure the page renders as text.
//
// Both histograms are RAW EVENTS ONLY (see `ListeningWindowDigest`). That is precisely
// why the all-time raw-horizon caption lives at the Group 1 header in `StatsView` — it
// governs this section, so there is deliberately no second caption here.
import Charts
import DesignSystem
import Foundation
import Services
import SwiftUI

/// The hour-of-day and day-of-week charts for one ``ListeningWindowDigest``.
struct StatsListeningClockView: View {
    /// The selected period's facets, or `nil` before the first load.
    let window: ListeningWindowDigest?

    /// The same period's busiest daypart, from `ListeningStatsViewModel`.
    let mostActiveDaypart: ListeningDaypartDigest?

    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    /// Tall enough to read a 24-bar histogram, short enough that both charts and the
    /// four overview cards above them stay on one screen.
    private static let chartHeight: CGFloat = 120

    /// Narrower than this and the two charts stack instead of sitting side by side.
    private static let sideBySideMinimumWidth: CGFloat = 520

    /// Sparse enough to stay legible at 24 bars; the quarters of the day.
    private static let hourAxisValues = [0, 6, 12, 18]

    var body: some View {
        if let window, window.totalPlays > 0 {
            VStack(alignment: .leading, spacing: tokens.spacing.small) {
                Text(StatsStrings.listeningClock)
                    .font(tokens.typography.headline.font)
                    .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
                charts(for: window)
                caption
            }
        }
    }
}

// MARK: - Layout

private extension StatsListeningClockView {
    /// Side by side while there is room for both, stacked once there is not.
    func charts(for window: ListeningWindowDigest) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: tokens.spacing.medium) {
                hourChart(window.hourHistogram)
                weekdayChart(window.weekdayHistogram)
            }
            .frame(minWidth: Self.sideBySideMinimumWidth)
            VStack(alignment: .leading, spacing: tokens.spacing.medium) {
                hourChart(window.hourHistogram)
                weekdayChart(window.weekdayHistogram)
            }
        }
    }

    @ViewBuilder
    var caption: some View {
        if let mostActiveDaypart, mostActiveDaypart.plays > 0 {
            let name = String(localized: StatsStrings.daypartName(mostActiveDaypart.daypart))
            Text(StatsStrings.mostActive(daypartName: name))
                .font(tokens.typography.caption.font)
                .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The shared chrome around either chart: a caption-sized title over a fixed-height
    /// plot on a raised card, matching `StatsOverviewCards`.
    func chartCard(
        title: LocalizedStringResource,
        summary: LocalizedStringResource,
        identifier: String,
        @ViewBuilder chart: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: tokens.spacing.xSmall) {
            Text(title)
                .font(tokens.typography.caption.font)
                .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
            chart()
                .frame(height: Self.chartHeight)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(Text(summary))
                .accessibilityIdentifier(identifier)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(tokens.spacing.small)
        .background(tokens.colors.surfaceRaised.resolve(scheme))
        .clipShape(RoundedRectangle(cornerRadius: tokens.radii.medium, style: .continuous))
    }
}

// MARK: - Charts

private extension StatsListeningClockView {
    func hourChart(_ histogram: [Int]) -> some View {
        chartCard(
            title: StatsStrings.clockHourTitle,
            summary: hourSummary(histogram),
            identifier: "stats.hourChart"
        ) {
            Chart(bars(histogram, count: ListeningLocalTime.hoursPerDay)) { bar in
                BarMark(
                    x: .value(String(localized: StatsStrings.clockHourAxis), bar.id),
                    y: .value(String(localized: StatsStrings.cardPlays), bar.plays)
                )
                .foregroundStyle(tokens.colors.accent.resolve(scheme))
            }
            .chartXScale(domain: 0 ... (ListeningLocalTime.hoursPerDay - 1))
            .chartXAxis {
                AxisMarks(values: Self.hourAxisValues) { value in
                    AxisValueLabel {
                        if let hour = value.as(Int.self) {
                            Text(verbatim: "\(hour)")
                        }
                    }
                }
            }
            .chartYAxis { AxisMarks(position: .leading) }
        }
    }

    func weekdayChart(_ histogram: [Int]) -> some View {
        let weekdays = bars(histogram, count: ListeningLocalTime.daysPerWeek)
        return chartCard(
            title: StatsStrings.clockWeekdayTitle,
            summary: weekdaySummary(histogram),
            identifier: "stats.weekdayChart"
        ) {
            Chart(weekdays) { bar in
                BarMark(
                    x: .value(String(localized: StatsStrings.clockWeekdayAxis), weekdayLabel(bar.id)),
                    y: .value(String(localized: StatsStrings.cardPlays), bar.plays)
                )
                .foregroundStyle(tokens.colors.accent.resolve(scheme))
            }
            .chartXScale(domain: weekdays.map { weekdayLabel($0.id) })
            .chartYAxis { AxisMarks(position: .leading) }
        }
    }
}

// MARK: - Bins

/// One already-binned bar: a local hour `0 ... 23`, or a weekday `0 ... 6`.
private struct ClockBar: Identifiable {
    let id: Int
    let plays: Int
}

private extension StatsListeningClockView {
    /// Always emits the full run of bins, so a period whose plays survive only as
    /// monthly rollups draws an honest flat chart rather than a ragged partial one.
    func bars(_ histogram: [Int], count: Int) -> [ClockBar] {
        (0 ..< count).map { index in
            ClockBar(id: index, plays: histogram.indices.contains(index) ? histogram[index] : 0)
        }
    }

    /// The locale's short name for a weekday bin.
    ///
    /// index 0 = Sunday, matches ListeningWindowDigest.weekdayHistogram; hours are
    /// capture-local via stored utcOffsetSeconds — do NOT 'fix' with Calendar/TimeZone.
    /// `Calendar.current.shortWeekdaySymbols` is index-0-Sunday as well, so the two line
    /// up with no conversion: the calendar supplies LABELS only, in a fixed Sunday →
    /// Saturday display order, and never touches a bin index.
    func weekdayLabel(_ index: Int) -> String {
        let symbols = Calendar.current.shortWeekdaySymbols
        return symbols.indices.contains(index) ? symbols[index] : String(index)
    }

    /// The tallest bin, for the chart's spoken summary alone — `ListeningDigestBuilder`
    /// already counted every bin, so this derives no new figure. Ties resolve to the
    /// earliest bin, exactly as `ListeningStatsViewModel.mostActiveDaypart` does.
    func peakBin(_ histogram: [Int]) -> ClockBar? {
        var best: ClockBar?
        for (index, plays) in histogram.enumerated() where plays > (best?.plays ?? 0) {
            best = ClockBar(id: index, plays: plays)
        }
        return best
    }

    func hourSummary(_ histogram: [Int]) -> LocalizedStringResource {
        guard let peak = peakBin(histogram) else { return StatsStrings.clockHourTitle }
        return StatsStrings.clockHourPeak(hour: peak.id, plays: peak.plays)
    }

    func weekdaySummary(_ histogram: [Int]) -> LocalizedStringResource {
        guard let peak = peakBin(histogram) else { return StatsStrings.clockWeekdayTitle }
        return StatsStrings.clockWeekdayPeak(day: weekdayLabel(peak.id), plays: peak.plays)
    }
}

#Preview {
    StatsListeningClockView(
        window: ListeningWindowDigest(
            window: .last30Days,
            totalPlays: 120,
            hourHistogram: (0 ..< 24).map { max(0, 12 - abs($0 - 20)) },
            weekdayHistogram: [4, 12, 9, 15, 11, 22, 18]
        ),
        mostActiveDaypart: ListeningDaypartDigest(daypart: .evening, plays: 61)
    )
    .designTokens(.standard)
    .padding()
    .frame(width: 720)
}
