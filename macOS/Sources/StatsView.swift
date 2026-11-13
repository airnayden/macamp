// StatsView — the library-wide listening-statistics dashboard (the Stats sidebar
// destination). The right panel's Stats tab shows only the CURRENT track's
// numbers; everything library-wide lives here.
//
// The page is deliberately split into TWO groups, because mixing them is how a
// statistics screen starts lying:
//
//  * **Group 1 — window-scoped.** Everything under the period filter answers
//    "in the last N days". Switching the filter costs NO database work: the view
//    model loaded every window in one pass, so `selectedWindow` is a pure re-read
//    (see `ListeningStatsViewModel`). Never add an `.onChange` that reloads on a
//    window change — that would defeat the contract its tests lock.
//  * **Group 2 — "All Time & History".** Figures that ignore the filter entirely:
//    the library's lifetime play counters, and (once todos 7-8 land) the replay
//    and recent-play lists. Its heading is unconditional so those sections have a
//    stable home.
//
// The all-time raw-horizon caption renders at the GROUP 1 HEADER, not beside one
// section, because it governs every raw-only facet below it — the listening clock
// and the top lists alike.
import DesignSystem
import Persistence
import Services
import SwiftUI
import ViewModels

struct StatsView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(AppSettings.self) private var settings
    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    /// Built lazily on the first load and re-keyed by profile, mirroring
    /// `ScrubberHeatOverlay` — a `@State` default initialiser would construct GRDB
    /// repositories on every view re-init.
    @State private var model: ListeningStatsViewModel?

    /// Lifetime counters, read straight from the library rows. Deliberately NOT
    /// from the digest: they predate the v15 event log and count plays it never saw.
    @State private var totalPlays = 0
    @State private var topTracks: [ProfileScopedTrack] = []

    /// Rows the lifetime Most Played list keeps — unchanged from the pre-dashboard
    /// page so its behavior is preserved exactly.
    private static let lifetimeTrackLimit = 25

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: tokens.spacing.xLarge) {
                content
            }
            .padding(tokens.spacing.large)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(tokens.colors.canvas.resolve(scheme).opacity(0.25))
        .task(id: environment.profileService.activeProfile.id) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if isInitialLoading {
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .padding(tokens.spacing.xxLarge)
        } else if isEmpty {
            StateView(
                systemImage: "chart.bar",
                title: StatsPanelStrings.emptyTitle,
                message: StatsPanelStrings.emptyMessage
            )
            .frame(maxWidth: .infinity)
        } else {
            windowGroup
            historyGroup
        }
    }
}

// MARK: - State gates

private extension StatsView {
    /// The spinner covers the very first pass only; a refresh over already-loaded
    /// data leaves the page in place rather than blanking it.
    var isInitialLoading: Bool {
        guard let model else { return true }
        return model.digest == nil && model.isLoading
    }

    /// Nothing recorded anywhere — neither the detailed history nor the lifetime
    /// counters. Either one alone still deserves a page.
    var isEmpty: Bool {
        let recordedPlays = model?.digest?.window(.allTime)?.totalPlays ?? 0
        return recordedPlays == 0 && totalPlays == 0 && topTracks.isEmpty
    }

    /// Assigning through this binding performs NO repository work by design.
    var windowSelection: Binding<ListeningWindowKind> {
        Binding(
            get: { model?.selectedWindow ?? .last30Days },
            set: { model?.selectedWindow = $0 }
        )
    }
}

// MARK: - Group 1: the selected period

private extension StatsView {
    var windowGroup: some View {
        VStack(alignment: .leading, spacing: tokens.spacing.medium) {
            windowHeader
            rawHorizonNotice
            insightsCard
            StatsOverviewCards(
                window: model?.selectedWindowDigest,
                completionRate: model.map { $0.completionRate(for: $0.selectedWindow) } ?? 0
            )
            StatsListeningClockView(
                window: model?.selectedWindowDigest,
                mostActiveDaypart: model?.mostActiveDaypart
            )
            StatsTopListsView(model: model)
        }
    }

    var windowHeader: some View {
        VStack(alignment: .leading, spacing: tokens.spacing.small) {
            HStack(spacing: tokens.spacing.small) {
                Text(StatsStrings.pageTitle)
                    .font(tokens.typography.titleLarge.font)
                    .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
                Spacer(minLength: tokens.spacing.small)
                refreshButton
            }
            windowPicker
        }
    }

    var windowPicker: some View {
        Picker(selection: windowSelection) {
            ForEach(ListeningWindowKind.allCases, id: \.self) { kind in
                Text(StatsStrings.windowName(kind)).tag(kind)
            }
        } label: {
            Text(StatsStrings.windowFilterLabel)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 420)
        .pointingHandCursor()
        .help(Text(StatsStrings.windowFilterHelp))
        .accessibilityLabel(Text(StatsStrings.windowFilterLabel))
        .accessibilityIdentifier("stats.windowFilter")
    }

    var refreshButton: some View {
        Button {
            Task { await load() }
            environment.toast.show(
                text: String(localized: StatsPanelStrings.refreshed),
                icon: "arrow.clockwise"
            )
        } label: {
            Image(systemName: "arrow.clockwise")
                .foregroundStyle(tokens.colors.accent.resolve(scheme))
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .help(Text(StatsPanelStrings.refresh))
        .accessibilityLabel(Text(StatsPanelStrings.refresh))
    }

    /// Absent — not disabled — whenever the insights bundle or the Intelligence
    /// master toggle is off: `isEnabled(_:)` ANDs the two, and the graph itself is
    /// `nil` while the master toggle is off, so neither switch can leave a dead
    /// affordance behind.
    ///
    /// Keyed by profile so a switch rebuilds the card with a fresh model. Without the
    /// `id`, the card would keep narrating the profile the listener just left — the
    /// one case where a stale narrative is wrong rather than merely old.
    @ViewBuilder
    var insightsCard: some View {
        if settings.isEnabled(.insights), let narrator = environment.intelligence?.narrator {
            StatsInsightsCard(digest: model?.selectedWindowDigest, narrator: narrator)
                .id(environment.profileService.activeProfile.id ?? ProfileRecord.guestID)
        }
    }

    /// Governs EVERY raw-only facet of the all-time view, which is why it sits at
    /// the group header instead of beside a single section.
    @ViewBuilder
    var rawHorizonNotice: some View {
        if let model, model.selectedWindow == .allTime,
           let month = model.digest?.rawHorizonYearMonth, !month.isEmpty
        {
            Text(StatsStrings.rawHorizonCaption(month: month))
                .font(tokens.typography.caption.font)
                .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Group 2: all time and history

private extension StatsView {
    var historyGroup: some View {
        VStack(alignment: .leading, spacing: tokens.spacing.medium) {
            VStack(alignment: .leading, spacing: tokens.spacing.xSmall) {
                Text(StatsStrings.historyGroupTitle)
                    .font(tokens.typography.titleLarge.font)
                    .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
                Divider()
            }
            StatsMostReplayedView(rows: model?.replayedRows ?? [])
            StatsRecentPlaysView(rows: model?.recentPlays ?? [])
            lifetimeMostPlayedSection
        }
    }

    @ViewBuilder
    var lifetimeMostPlayedSection: some View {
        if !topTracks.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text(StatsStrings.lifetimeMostPlayed)
                    .font(tokens.typography.headline.font)
                    .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
                Text(StatsStrings.lifetimeCaption)
                    .font(tokens.typography.caption.font)
                    .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, tokens.spacing.xSmall)
                LazyVStack(spacing: 0) {
                    ForEach(Array(topTracks.enumerated()), id: \.element.track.id) { index, track in
                        statsTrackRow(index: index, track: track)
                    }
                }
            }
        }
    }

    func statsTrackRow(index: Int, track: ProfileScopedTrack) -> some View {
        HStack(spacing: tokens.spacing.small) {
            TrackListRow(
                number: index + 1,
                title: track.track.title ?? track.track.filePath,
                artist: track.track.artistName,
                artistId: track.track.artistId,
                duration: track.track.duration,
                isPlaying: track.track.id == environment.player.currentTrack?.trackID,
                availability: track.track.availability,
                isFavourite: track.isFavourite,
                onToggleFavourite: {
                    guard let trackId = track.track.id else { return }
                    let profileId = environment.profileService.activeProfile.id ?? ProfileRecord.guestID
                    let repo = TrackRepository(environment.database)
                    Task { try? await repo.toggleFavourite(profileId: profileId, trackId: trackId) }
                },
                karaokeState: environment.karaokeRowState(
                    filePath: track.track.filePath,
                    enabled: settings.karaokeEnabled
                ),
                onRequestKaraokeRender: environment.karaokeRenderAction(
                    filePath: track.track.filePath,
                    enabled: settings.karaokeEnabled
                ),
                onDequeueKaraoke: environment.karaokeDequeueAction(
                    filePath: track.track.filePath,
                    enabled: settings.karaokeEnabled
                )
            )
            Text(verbatim: "\(track.playCount)×")
                .font(tokens.typography.caption.font.monospacedDigit().bold())
                .foregroundStyle(tokens.colors.accent.resolve(scheme))
        }
        .contentShape(Rectangle())
        // No `.accessibilityElement(children: .combine)` here, unlike every other
        // stats row: this one wraps live controls (favourite toggle, karaoke render
        // icon) that combining would erase from the VoiceOver tree.
        .pointingHandCursor()
        .onTapGesture(count: 2) { playTrack(track) }
        .contextMenu { rowMenu(for: track) }
    }

    @ViewBuilder
    func rowMenu(for track: ProfileScopedTrack) -> some View {
        Button { playTrack(track) } label: {
            Label { Text(MacAMPStrings.menuPlay) } icon: { Image(systemName: "play.fill") }
        }
        Button {
            environment.coordinator.enqueueManual(TrackRef(record: track.track))
            environment.queue.refresh()
        } label: {
            Label { Text(MacAMPStrings.menuAddToQueue) } icon: { Image(systemName: "text.append") }
        }
        KaraokeRenderMenuButton(
            filePaths: [track.track.filePath],
            enabled: settings.karaokeEnabled
        )
    }

    func playTrack(_ track: ProfileScopedTrack) {
        let refs = topTracks.map { TrackRef(record: $0.track) }
        let startIndex = topTracks.firstIndex(where: { $0.track.id == track.track.id }) ?? 0
        environment.coordinator.setQueue(refs, startingAt: startIndex, source: .stats)
        environment.queue.refresh()
    }
}

// MARK: - Loading

private extension StatsView {
    /// One pass for the whole page: the view model reads every window at once, and
    /// the lifetime counters come straight off the library rows.
    func load() async {
        let profileId = environment.profileService.activeProfile.id ?? ProfileRecord.guestID
        if model == nil {
            model = ListeningStatsViewModel(
                digestBuilder: ListeningDigestBuilder(environment.database),
                events: PlayEventRepository(environment.database),
                heat: PlaySegmentHeatRepository(environment.database),
                tracks: TrackRepository(environment.database)
            )
        }
        await model?.refresh(profileId: profileId)
        let repo = TrackRepository(environment.database)
        totalPlays = await (try? repo.totalPlayCount(profileId: profileId)) ?? 0
        topTracks = await (try? repo.topPlayedTracks(
            profileId: profileId,
            limit: Self.lifetimeTrackLimit
        )) ?? []
    }
}

#Preview {
    StatsView()
        .environment(AppEnvironment.preview())
        .environment(AppSettings.preview)
        .designTokens(.standard)
        .frame(width: 720, height: 560)
}
