// KaraokeReadyListView — the sidebar `.karaoke` detail: the active profile's list
// of tracks that have a cached karaoke instrumental ready to play. Windowed via
// `KaraokeReadyListViewModel` (keyset pages over `KaraokeReadyStore.readyPaths`),
// re-queried on ready-set (`version`), library-root, and profile changes through `.task(id:)`.
// Double-click (or context-menu Play) plays the whole list from the clicked row and
// engages karaoke mode for that queue (unlike the library/favourites lists).
import DesignSystem
import Persistence
import Services
import SwiftUI
import ViewModels

struct KaraokeReadyListView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    @State private var model: KaraokeReadyListViewModel?
    @State private var selection = Set<Int64>()

    var body: some View {
        content
            .task(id: loadKey) { await load() }
    }

    private var activeProfileId: Int64 {
        environment.profileService.activeProfile.id ?? ProfileRecord.guestID
    }

    private var loadKey: KaraokeReadyLoadKey {
        KaraokeReadyLoadKey(
            profileId: activeProfileId,
            version: environment.karaokeReadyStore.version,
            libraryRevision: environment.libraryFolders.revision
        )
    }
}

/// Re-keys `.task` when profile scope, library roots, or the ready set changes.
/// `version` never changes for progress ticks, so the window reloads only when
/// its resolved contents can differ.
struct KaraokeReadyLoadKey: Equatable {
    let profileId: Int64
    let version: Int
    let libraryRevision: Int
}

// MARK: - Content

private extension KaraokeReadyListView {
    @ViewBuilder
    var content: some View {
        if let model, !model.tracks.isEmpty {
            loadedContent(model)
        } else if model == nil || model?.isLoading == true {
            StateView.loading()
                .synthwaveEmptyBackground()
        } else {
            StateView(
                systemImage: "music.mic",
                title: MacAMPStrings.karaokeReadyEmptyTitle,
                message: MacAMPStrings.karaokeReadyEmptyMessage
            )
            .synthwaveEmptyBackground()
        }
    }

    func loadedContent(_ model: KaraokeReadyListViewModel) -> some View {
        @Bindable var model = model
        return VStack(spacing: 0) {
            searchField(query: $model.searchQuery)
            Divider()
            if model.filteredRows.isEmpty {
                StateView(
                    systemImage: "magnifyingglass",
                    title: MacAMPStrings.karaokeReadyNoResultsTitle,
                    message: MacAMPStrings.karaokeReadyNoResultsMessage
                )
                .synthwaveEmptyBackground()
            } else {
                trackList(model)
            }
        }
    }

    func searchField(query: Binding<String>) -> some View {
        HStack(spacing: tokens.spacing.xSmall) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
                .font(tokens.typography.caption.font)
            TextField(String(localized: MacAMPStrings.karaokeReadySearchPrompt), text: query)
                .textFieldStyle(.plain)
                .font(tokens.typography.callout.font)
                .accessibilityIdentifier("karaokeReadyList.searchField")
            if !query.wrappedValue.isEmpty {
                Button { query.wrappedValue = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .help(Text(MacAMPStrings.searchClear))
                .accessibilityLabel(Text(MacAMPStrings.searchClear))
                .pointingHandCursor()
            }
        }
        .padding(.horizontal, tokens.spacing.small)
        .padding(.vertical, tokens.spacing.xxSmall)
        .background(
            Capsule(style: .continuous)
                .fill(tokens.colors.surfaceRaised.resolve(scheme))
        )
        .padding(.horizontal, tokens.spacing.medium)
        .padding(.vertical, tokens.spacing.xSmall)
    }

    func trackList(_ model: KaraokeReadyListViewModel) -> some View {
        List(selection: $selection) {
            ForEach(Array(model.filteredRows.enumerated()), id: \.element.track.id) { index, item in
                row(item.track, position: index + 1)
                    .tag(item.track.id ?? 0)
                    .onAppear { paginate(at: index, model: model) }
            }
        }
        .scrollContentBackground(.hidden)
        .background(tokens.colors.canvas.resolve(scheme).opacity(0.25))
        .contextMenu(forSelectionType: Int64.self) { ids in
            Button { play(ids, model: model) } label: {
                Label { Text(MacAMPStrings.menuPlay) } icon: { Image(systemName: "play.fill") }
            }
            if !ids.isEmpty {
                Button(role: .destructive) { removeKaraokeVersions(ids, model: model) } label: {
                    Label {
                        Text(MacAMPStrings.karaokeReadyRemove(ids.count))
                    } icon: {
                        Image(systemName: "trash")
                    }
                }
            }
        } primaryAction: { ids in
            play(ids, model: model)
        }
    }

    func row(_ track: TrackRecord, position: Int) -> some View {
        TrackListRow(
            number: position,
            title: track.title ?? track.filePath,
            artist: track.artistName,
            artistId: track.artistId,
            duration: track.duration,
            isPlaying: isPlaying(track),
            availability: track.availability,
            karaokeState: .ready
        )
    }

    func isPlaying(_ track: TrackRecord) -> Bool {
        guard let trackID = track.id else { return false }
        return trackID == environment.player.currentTrack?.trackID
    }
}

// MARK: - Loading + actions

private extension KaraokeReadyListView {
    func load() async {
        let paths = Array(environment.karaokeReadyStore.readyPaths)
        if model == nil {
            model = KaraokeReadyListViewModel(
                repository: TrackRepository(environment.database),
                activeProfileId: activeProfileId
            )
        }
        model?.activeProfileId = activeProfileId
        try? await model?.loadInitial(paths: paths)
    }

    func paginate(at index: Int, model: KaraokeReadyListViewModel) {
        guard index == model.filteredRows.count - 1 else { return }
        Task { try? await model.loadMore() }
    }

    /// The single play entry point for this list — both the context-menu Play and the
    /// double-click `primaryAction` call here. It is the ONLY macOS surface that uses
    /// `engagingKaraoke: true`: karaoke engages atomically against the new queue (race-free)
    /// and a resolution miss is silent (no spurious auto-deactivate toast). Other lists keep
    /// the default overload.
    func play(_ ids: Set<Int64>, model: KaraokeReadyListViewModel) {
        let refs = model.filteredRows.map { TrackRef(record: $0.track) }
        guard !refs.isEmpty else { return }
        let clickedId = ids.first
        let startIndex = refs.firstIndex { $0.trackID == clickedId } ?? 0
        environment.coordinator.setQueue(
            refs,
            startingAt: startIndex,
            engagingKaraoke: true,
            source: .karaokeReady
        )
        environment.queue.refresh()
    }

    /// Deletes the cached instrumentals for every selected row, leaving the SOURCE tracks,
    /// their library rows, play stats and the render queue untouched.
    ///
    /// The rows vanish through the cache change-seam (which re-keys `.task(id:)` and
    /// re-derives the window), so nothing is spliced out of the list by hand. A pinned —
    /// i.e. currently playing or pre-scheduled — instrumental is skipped by the cache, and
    /// the shortfall between requested and removed is what the toast reports.
    func removeKaraokeVersions(_ ids: Set<Int64>, model: KaraokeReadyListViewModel) {
        guard let cache = environment.karaokeCache else { return }
        let paths = model.filteredRows
            .filter { ids.contains($0.track.id ?? 0) }
            .map(\.track.filePath)
        guard !paths.isEmpty else { return }
        let toast = environment.toast
        Task {
            let removed = await (try? cache.remove(sourcePaths: paths)) ?? 0
            toast.show(text: removalToastText(removed: removed, requested: paths.count), icon: "trash")
        }
    }

    func removalToastText(removed: Int, requested: Int) -> String {
        if removed == 0 {
            return String(localized: MacAMPStrings.karaokeReadyKeptInUseToast)
        }
        return removed < requested
            ? MacAMPStrings.karaokeReadyRemovedKeptInUseToast(removed)
            : MacAMPStrings.karaokeReadyRemovedToast(removed)
    }
}

#Preview {
    KaraokeReadyListView()
        .environment(AppEnvironment.preview())
        .designTokens(.standard)
        .frame(width: 720, height: 480)
}
