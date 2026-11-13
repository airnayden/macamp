// StatsPanelView — the right panel's Stats tab, for the track that is playing now.
//
// Three stacked blocks, each independently gated so the panel never claims to know
// something it does not:
//   * Now Playing — the LIFETIME per-profile counters (`playCount`/`listenedCount`
//     out of `profileTrackState`). Predates v15; semantics untouched here.
//   * History — the v15 `playEvent` aggregate. It deliberately carries NO play-count
//     row: the block above already answers "how many plays", and two competing
//     "plays" numbers on one screen is a defect, not extra detail.
//   * Replay map — the same per-track heatmap the scrubbers paint, at panel scale.
//
// Cost note: `RightPanelView.tabContent` instantiates ONLY the active tab, so every
// read below fires exclusively while the Stats tab is the active tab on screen.
// That is why there is no additional visibility gate in this file — one would just
// duplicate that switch, and go stale the moment a tab is added.
import DesignSystem
import Persistence
import Services
import SwiftUI
import ViewModels

struct StatsPanelView: View {
    /// Height of the panel-scale replay curve. Tall enough to read the shape,
    /// short enough to stay a caption-weight accessory rather than a chart.
    private static let replayMapHeight: CGFloat = 24

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    @State private var currentPlayCount: Int?
    @State private var currentListenedCount: Int?
    @State private var trackHistory: TrackPlayStats?
    @State private var heatModel: ScrubberHeatViewModel?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: tokens.spacing.large) {
                currentTrackStats
                historySection
                replayMapSection
            }
            .padding(tokens.spacing.medium)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: environment.player.currentTrack?.trackID) { await loadStats() }
        .task(id: environment.profileService.activeProfile.id) { await loadStats() }
    }

    @ViewBuilder
    private var currentTrackStats: some View {
        if let track = environment.player.currentTrack {
            VStack(alignment: .leading, spacing: tokens.spacing.xSmall) {
                Text(StatsPanelStrings.nowPlaying)
                    .font(tokens.typography.headline.font)
                    .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
                HStack(spacing: tokens.spacing.small) {
                    Image(systemName: "play.circle.fill")
                        .foregroundStyle(tokens.colors.accent.resolve(scheme))
                    Text(verbatim: track.title ?? track.filePath)
                        .font(tokens.typography.callout.font)
                        .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
                        .lineLimit(1)
                }
                if let count = currentPlayCount {
                    Text(StatsPanelStrings.playCount(count))
                        .font(tokens.typography.body.font)
                        .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
                }
                if let count = currentListenedCount, count > 0 {
                    Text(StatsPanelStrings.listenedCount(count))
                        .font(tokens.typography.body.font)
                        .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
                }
            }
        } else {
            StateView(
                systemImage: "chart.bar",
                title: StatsPanelStrings.emptyTitle,
                message: StatsPanelStrings.emptyMessage
            )
            .frame(maxWidth: .infinity)
        }
    }

    /// ABSENT, never zeroed, when this profile has no `playEvent` rows for the track.
    ///
    /// The honesty rule: a library that predates the v15 event log still has real
    /// lifetime counters but no events behind them, and rendering "never played,
    /// 0 skips" over that would be a fabrication. No data ⇒ no block.
    @ViewBuilder
    private var historySection: some View {
        if let history = trackHistory {
            VStack(alignment: .leading, spacing: tokens.spacing.xSmall) {
                Text(StatsPanelStrings.history)
                    .font(tokens.typography.headline.font)
                    .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
                historyRow(StatsPanelStrings.lastPlayed, value: Self.relativeDate(history.lastPlayedAt))
                historyRow(StatsPanelStrings.firstPlayed, value: Self.calendarDate(history.firstPlayedAt))
                historyRow(StatsPanelStrings.timeListened, value: Self.listened(history.secondsListened))
                Text(StatsPanelStrings.skipCount(count: history.skips))
                    .font(tokens.typography.body.font)
                    .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
            }
        }
    }

    private func historyRow(_ label: LocalizedStringResource, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: tokens.spacing.small) {
            Text(label)
                .font(tokens.typography.body.font)
                .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
            Spacer(minLength: tokens.spacing.small)
            Text(verbatim: value)
                .font(tokens.typography.body.font)
                .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
                .lineLimit(1)
        }
        // Display-only pair: one spoken sentence, not two elements to visit.
        .accessibilityElement(children: .combine)
    }

    /// The noise floor is `ReplayHeatAnalysis.hasTrustworthyShape` — three committed
    /// passes OR one 1% slice heard three times — applied inside the model, so a
    /// thinner history publishes `heat == nil` and this block simply does not appear.
    /// No threshold is re-derived at this call site.
    @ViewBuilder
    private var replayMapSection: some View {
        if let intensities = heatModel?.heat {
            VStack(alignment: .leading, spacing: tokens.spacing.xSmall) {
                Text(StatsPanelStrings.replayMap)
                    .font(tokens.typography.caption.font)
                    .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
                ReplayHeatCurve(intensities: intensities, isRevealed: true)
                    .frame(height: Self.replayMapHeight)
                    .background(tokens.colors.surface.resolve(scheme).opacity(0.35))
                    .clipShape(RoundedRectangle(cornerRadius: tokens.radii.small, style: .continuous))
            }
        }
    }

    private func loadStats() async {
        guard let trackID = environment.player.currentTrack?.trackID else {
            currentPlayCount = nil
            currentListenedCount = nil
            trackHistory = nil
            heatModel?.clear()
            return
        }
        let profileId = environment.profileService.activeProfile.id ?? ProfileRecord.guestID
        let repo = TrackRepository(environment.database)
        let resolved = await Task.detached {
            try? repo.resolvedTrack(profileId: profileId, trackId: trackID)
        }.value
        currentPlayCount = resolved?.playCount
        currentListenedCount = resolved?.listenedCount
        trackHistory = try? await PlayEventRepository(environment.database)
            .trackPlayStats(profileId: profileId, trackId: trackID)
        await loadHeat(profileId: profileId, trackId: trackID)
    }

    private func loadHeat(profileId: Int64, trackId: Int64) async {
        if heatModel == nil {
            heatModel = ScrubberHeatViewModel(repository: PlaySegmentHeatRepository(environment.database))
        }
        await heatModel?.load(profileId: profileId, trackId: trackId)
    }

    private static func relativeDate(_ timestamp: TimeInterval) -> String {
        Date(timeIntervalSince1970: timestamp).formatted(.relative(presentation: .named))
    }

    private static func calendarDate(_ timestamp: TimeInterval) -> String {
        Date(timeIntervalSince1970: timestamp).formatted(date: .abbreviated, time: .omitted)
    }

    /// Already localized by `Duration.UnitsFormatStyle`, which is why callers render it
    /// `verbatim` — routing it back through the catalog would translate it twice.
    private static func listened(_ seconds: Double) -> String {
        let clamped = max(0, seconds)
        guard clamped >= 60 else {
            return Duration.seconds(clamped)
                .formatted(.units(allowed: [.seconds], width: .abbreviated, zeroValueUnits: .show(length: 1)))
        }
        return Duration.seconds(clamped)
            .formatted(.units(allowed: [.hours, .minutes], width: .abbreviated, maximumUnitCount: 2))
    }
}

enum StatsPanelStrings {
    static let title = LocalizedStringResource(
        "app.panel.stats.title",
        defaultValue: "Stats",
        comment: "Right panel tab title for playback statistics"
    )
    static let nowPlaying = LocalizedStringResource(
        "app.panel.stats.nowPlaying",
        defaultValue: "Now Playing",
        comment: "Section heading for the current track's play count"
    )
    static let overview = LocalizedStringResource(
        "app.panel.stats.overview",
        defaultValue: "Overview",
        comment: "Section heading for overall play statistics"
    )
    static let topPlayed = LocalizedStringResource(
        "app.panel.stats.topPlayed",
        defaultValue: "Most Played",
        comment: "Section heading for the top played tracks list"
    )
    static func playCount(_ count: Int) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.panel.stats.playCount",
            defaultValue: "Played ^[\(count) time](inflect: true)",
            comment: "Play count for the current track"
        )
    }

    static func totalPlays(_ count: Int) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.panel.stats.totalPlays",
            defaultValue: "^[\(count) play](inflect: true) total",
            comment: "Total number of plays across all tracks"
        )
    }

    static let refresh = LocalizedStringResource(
        "app.panel.stats.refresh",
        defaultValue: "Refresh",
        comment: "Tooltip for the refresh button on the stats panel"
    )
    static let refreshed = LocalizedStringResource(
        "app.panel.stats.refreshed",
        defaultValue: "Stats updated",
        comment: "Toast shown after stats are refreshed"
    )
    static func listenedCount(_ count: Int) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.panel.stats.listenedCount",
            defaultValue: "Listened fully ^[\(count) time](inflect: true)",
            comment: "Number of times a track was listened to for more than 1 minute"
        )
    }

    static let history = LocalizedStringResource(
        "app.panel.stats.history",
        defaultValue: "History",
        comment: "Section heading for the current track's recorded listening history"
    )
    static let lastPlayed = LocalizedStringResource(
        "app.panel.stats.lastPlayed",
        defaultValue: "Last played",
        comment: "Row label for when the current track was most recently played"
    )
    static let firstPlayed = LocalizedStringResource(
        "app.panel.stats.firstPlayed",
        defaultValue: "First played",
        comment: "Row label for when the current track was played for the first time"
    )
    static let timeListened = LocalizedStringResource(
        "app.panel.stats.timeListened",
        defaultValue: "Time listened",
        comment: "Row label for the total time spent listening to the current track"
    )
    static func skipCount(count: Int) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.panel.stats.skipCount",
            defaultValue: "Skipped ^[\(count) time](inflect: true)",
            comment: "How many plays of the current track the listener cut short"
        )
    }

    static let replayMap = LocalizedStringResource(
        "app.panel.stats.replayMap",
        defaultValue: "Replay Map",
        comment: "Caption above the curve showing which parts of the track are replayed most"
    )
    static let emptyTitle = LocalizedStringResource(
        "app.panel.stats.emptyTitle",
        defaultValue: "No Stats Yet",
        comment: "Empty-state title when there is nothing to show statistics for"
    )
    static let emptyMessage = LocalizedStringResource(
        "app.panel.stats.emptyMessage",
        defaultValue: "Play some music to start collecting statistics.",
        comment: "Empty-state message explaining how statistics get collected"
    )
}
