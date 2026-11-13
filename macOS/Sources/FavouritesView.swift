// FavouritesView — the user's favourited tracks, drag-reorderable with DB
// persistence (via the active profile's custom order in profileTrackState, same
// as the folder browser), filterable by genre, and wired to the bottom play bar
// through the reusable `PlayShuffleBar`.
//
// Favourites are a small, user-curated subset, so the whole set is loaded once
// (bounded `TrackRepository.favouriteTracks`) into a local array — the genre
// facets are derived client-side and reorder rewrites every row's position.
import DesignSystem
import Persistence
import Services
import SwiftUI
import ViewModels

struct FavouritesView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(AppSettings.self) private var settings
    @Environment(PlayIntent.self) private var playIntent
    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    @State private var favourites: [TrackRecord] = []
    @State private var selection = Set<Int64>()
    @State private var selectedGenre: GenreFilter = .all
    @State private var genreOptions: [GenreFilter] = [.all]
    @State private var isLoading = false
    @State private var localFilter = ""

    var body: some View {
        VStack(spacing: 0) {
            if genreOptions.count > 1 {
                GenreFilterChipBar(options: genreOptions, selection: $selectedGenre)
                Divider()
            }
            content
        }
        .task(id: activeProfileId) { await load() }
        .onChange(of: playIntent.idlePlayToken) { _, _ in playSelectionOrFirst() }
    }

    var displayTracks: [TrackRecord] {
        var result = favourites
        if !selectedGenre.isAll {
            result = result.filter { track in
                switch selectedGenre {
                case .all: true
                case .untagged: (track.genre ?? "").isEmpty
                case let .genre(name): track.genre == name
                }
            }
        }
        if !localFilter.isEmpty {
            result = result.filter { $0.matchesFilter(localFilter) }
        }
        return result
    }
}

// MARK: - Content

private extension FavouritesView {
    @ViewBuilder
    var content: some View {
        if displayTracks.isEmpty {
            emptyOrLoading
        } else {
            VStack(spacing: 0) {
                PlayShuffleBar(
                    tracks: displayTracks,
                    source: .favourites,
                    filterText: $localFilter
                )
                Divider()
                trackList
            }
        }
    }

    @ViewBuilder
    var emptyOrLoading: some View {
        if isLoading {
            StateView.loading()
                .synthwaveEmptyBackground()
        } else {
            StateView(
                systemImage: "heart",
                title: FavouritesStrings.emptyTitle,
                message: FavouritesStrings.emptyMessage
            )
            .synthwaveEmptyBackground()
        }
    }

    var trackList: some View {
        List(selection: $selection) {
            ForEach(Array(displayTracks.enumerated()), id: \.element.id) { index, track in
                row(track, position: index + 1)
                    .tag(track.id ?? 0)
                    .moveDisabled(!selectedGenre.isAll)
            }
            .onMove(perform: move)
        }
        .scrollContentBackground(.hidden)
        .background(tokens.colors.canvas.resolve(scheme).opacity(0.25))
        .contextMenu(forSelectionType: Int64.self) { ids in
            contextMenu(for: ids)
        } primaryAction: { ids in
            play(ids)
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
            isFavourite: true,
            onToggleFavourite: { removeFavourite(track) },
            karaokeState: environment.karaokeRowState(
                filePath: track.filePath,
                enabled: settings.karaokeEnabled
            ),
            onRequestKaraokeRender: environment.karaokeRenderAction(
                filePath: track.filePath,
                enabled: settings.karaokeEnabled
            ),
            onDequeueKaraoke: environment.karaokeDequeueAction(
                filePath: track.filePath,
                enabled: settings.karaokeEnabled
            )
        )
    }
}

// MARK: - Context menu

private extension FavouritesView {
    @ViewBuilder
    func contextMenu(for ids: Set<Int64>) -> some View {
        Button { play(ids) } label: {
            Label { Text(MacAMPStrings.menuPlay) } icon: { Image(systemName: "play.fill") }
        }
        Button { playNext(ids) } label: {
            Label { Text(MacAMPStrings.menuPlayNext) } icon: { Image(systemName: "text.insert") }
        }
        Button { enqueue(ids) } label: {
            Label { Text(MacAMPStrings.menuAddToQueue) } icon: { Image(systemName: "text.append") }
        }
        KaraokeRenderMenuButton(
            filePaths: refs(for: ids).map(\.filePath),
            enabled: settings.karaokeEnabled
        )
        Divider()
        Button(role: .destructive) { removeFavourites(ids) } label: {
            Label { Text(FavouritesStrings.remove) } icon: { Image(systemName: "heart.slash") }
        }
    }
}

// MARK: - Loading + helpers

private extension FavouritesView {
    var activeProfileId: Int64 {
        environment.profileService.activeProfile.id ?? ProfileRecord.guestID
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        let repository = TrackRepository(environment.database)
        let profileId = activeProfileId
        let loaded = await (try? Task.detached {
            try repository.favouriteTracks(profileId: profileId).map(\.track)
        }.value) ?? []
        favourites = loaded
        computeGenreOptions()
    }

    func computeGenreOptions() {
        let genres = Set(favourites.compactMap { track -> String? in
            guard let value = track.genre, !value.isEmpty else { return nil }
            return value
        })
        let includesUntagged = favourites.contains { ($0.genre ?? "").isEmpty }
        let facets = LibraryGenreFacets(genres: genres.sorted(), includesUntagged: includesUntagged)
        genreOptions = GenreFilter.options(from: facets)
        if !genreOptions.contains(selectedGenre) { selectedGenre = .all }
    }

    func isPlaying(_ track: TrackRecord) -> Bool {
        guard let trackID = track.id else { return false }
        return trackID == environment.player.currentTrack?.trackID
    }
}

// MARK: - Actions

private extension FavouritesView {
    func move(from source: IndexSet, to destination: Int) {
        favourites.move(fromOffsets: source, toOffset: destination)
        environment.coordinator.reorderQueue(favourites.map { TrackRef(record: $0) })
        environment.queue.refresh()
        let updates = favourites.enumerated().compactMap { offset, track -> (trackId: Int64, position: Int)? in
            guard let trackId = track.id else { return nil }
            return (trackId: trackId, position: offset)
        }
        let repository = TrackRepository(environment.database)
        let profileId = activeProfileId
        Task { try? await repository.updateCustomPositions(profileId: profileId, updates) }
    }

    func refs(for ids: Set<Int64>) -> [TrackRef] {
        displayTracks.filter { ids.contains($0.id ?? 0) }.map { TrackRef(record: $0) }
    }

    func play(_ ids: Set<Int64>) {
        let allRefs = displayTracks.map { TrackRef(record: $0) }
        guard !allRefs.isEmpty else { return }
        let clickedId = ids.first
        let startIndex = allRefs.firstIndex(where: { $0.trackID == clickedId }) ?? 0
        environment.coordinator.setQueue(allRefs, startingAt: startIndex, source: .favourites)
        environment.queue.refresh()
    }

    func playSelectionOrFirst() {
        if !selection.isEmpty { play(selection) }
        else if let first = displayTracks.first?.id { play([first]) }
    }

    func enqueue(_ ids: Set<Int64>) {
        let selected = refs(for: ids)
        guard !selected.isEmpty else { return }
        environment.coordinator.enqueueManual(contentsOf: selected)
        environment.queue.refresh()
    }

    func playNext(_ ids: Set<Int64>) {
        let selected = refs(for: ids)
        guard !selected.isEmpty else { return }
        environment.coordinator.playNextManual(contentsOf: selected)
        environment.queue.refresh()
    }

    func removeFavourite(_ track: TrackRecord) {
        guard let trackId = track.id else { return }
        let name = track.title ?? track.filePath
        favourites.removeAll { $0.id == trackId }
        computeGenreOptions()
        let repository = TrackRepository(environment.database)
        let profileId = activeProfileId
        Task { try? await repository.setFavourite(profileId: profileId, trackId: trackId, isFavourite: false) }
        environment.toast.show(
            text: "\(String(localized: FavouritesStrings.removedToast)) \"\(name)\"",
            icon: "heart.slash"
        )
    }

    func removeFavourites(_ ids: Set<Int64>) {
        favourites.removeAll { ids.contains($0.id ?? 0) }
        computeGenreOptions()
        let count = ids.count
        let repository = TrackRepository(environment.database)
        let profileId = activeProfileId
        Task {
            for trackId in ids {
                try? await repository.setFavourite(profileId: profileId, trackId: trackId, isFavourite: false)
            }
        }
        environment.toast.show(
            text: "\(String(localized: FavouritesStrings.removedToast)) (\(count))",
            icon: "heart.slash"
        )
    }
}

#Preview {
    FavouritesView()
        .environment(AppEnvironment.preview())
        .environment(AppSettings.preview)
        .environment(PlayIntent())
        .designTokens(.standard)
        .frame(width: 720, height: 480)
}
