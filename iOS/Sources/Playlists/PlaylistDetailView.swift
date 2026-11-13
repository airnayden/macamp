// PlaylistDetailView — one playlist's tracks, with play/enqueue and (for plain
// lists) swipe-to-remove + drag-reorder.
//
// Driven by the shared ``PlaylistViewModel`` (Task 9). A playlist pages its
// ordered membership (`tracks`) keyset-paginated — only the loaded window lives in
// memory; the last row's `onAppear` pulls the next page.
//
// Editing respects iOS edit mode: reorder handles appear in edit mode, swipe-to-
// remove outside it. Removing a track removes it from THIS playlist only — never
// from the library. Reorder rewrites the whole order, so edit mode first drains
// any unloaded pages (``handleEditModeChange``) before a move can persist a
// truncated list. A local `orderedRows` mirror gives instant move/remove feedback
// because the view model's `tracks` is `private(set)`.
import DesignSystem
import Persistence
import Services
import SwiftUI

/// A single playlist's track list (editable membership).
struct PlaylistDetailView: View {
    let playlist: PlaylistRecord

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    @State private var orderedRows: [PlaylistTrackItem] = []
    @State private var editMode: EditMode = .inactive

    var body: some View {
        content
            .navigationTitle(Text(verbatim: playlist.name))
            .navigationBarTitleDisplayMode(.inline)
            .environment(\.editMode, $editMode)
            .toolbar { toolbarContent }
            .task(id: playlist.id) { await load() }
            .onChange(of: loadedRowIds) { _, _ in syncRowsFromModel() }
            .onChange(of: editMode) { _, mode in Task { await handleEditModeChange(mode) } }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if !orderedRows.isEmpty {
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
        }
    }
}

// MARK: - Content

private extension PlaylistDetailView {
    @ViewBuilder
    var content: some View {
        if orderedRows.isEmpty {
            emptyOrLoading
        } else {
            VStack(spacing: 0) {
                playHeader(for: orderedRows.map(\.track))
                trackList
            }
        }
    }

    var trackList: some View {
        List {
            ForEach(orderedRows, id: \.id) { item in
                Button { play(item) } label: { row(item.track) }
                    .buttonStyle(.plain)
                    .disabled(editMode == .active)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .onAppear { paginate(item) }
                    .swipeActions(edge: .trailing) { removeButton(item) }
            }
            .onMove(perform: move)
        }
        .listStyle(.plain)
    }

    @ViewBuilder
    var emptyOrLoading: some View {
        if environment.playlists.isLoadingTracks {
            StateView.loading()
        } else {
            StateView(
                systemImage: "music.note",
                title: MacAMPStrings.playlistTracksEmptyTitle,
                message: MacAMPStrings.playlistTracksEmptyMessage
            )
        }
    }
}

// MARK: - Rows + header

private extension PlaylistDetailView {
    func row(_ track: TrackRecord) -> some View {
        TrackRow(
            title: track.title ?? track.filePath,
            subtitle: track.artistName,
            duration: durationToken(track),
            isPlaying: isPlaying(track)
        )
        .opacity(track.availability == .present ? 1 : 0.55)
        .overlay(alignment: .trailing) { badge(track) }
        .padding(.horizontal, tokens.spacing.small)
    }

    @ViewBuilder
    func badge(_ track: TrackRecord) -> some View {
        switch track.availability {
        case .present:
            EmptyView()
        case .missing:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(tokens.colors.warning.resolve(scheme))
                .padding(.trailing, tokens.spacing.medium)
                .accessibilityLabel(Text(MacAMPStrings.badgeMissing))
        case .externalOffline:
            Image(systemName: "externaldrive.badge.xmark")
                .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
                .padding(.trailing, tokens.spacing.medium)
                .accessibilityLabel(Text(MacAMPStrings.badgeOffline))
        }
    }

    func removeButton(_ item: PlaylistTrackItem) -> some View {
        Button(role: .destructive) { remove(item) } label: {
            Label { Text(MacAMPStrings.playlistRemove) } icon: { Image(systemName: "minus.circle") }
        }
    }

    func playHeader(for tracks: [TrackRecord]) -> some View {
        VStack(spacing: tokens.spacing.small) {
            DetailPlayBar(
                playTitle: MacAMPStrings.playlistPlayAll,
                shuffleTitle: MacAMPStrings.playlistShuffle,
                onPlay: { play(tracks, shuffled: false) },
                onShuffle: { play(tracks, shuffled: true) }
            )
        }
        .padding(.horizontal, tokens.spacing.large)
        .padding(.vertical, tokens.spacing.small)
    }

    func durationToken(_ track: TrackRecord) -> Duration? {
        guard track.availability == .present, let seconds = track.duration else { return nil }
        return .seconds(seconds)
    }

    func isPlaying(_ track: TrackRecord) -> Bool {
        guard let trackID = track.id else { return false }
        return trackID == environment.player.currentTrack?.trackID
    }
}

// MARK: - Loading + edit-mode draining

private extension PlaylistDetailView {
    /// Membership-row identities of the loaded window — an `Equatable` key that
    /// fires `onChange` as pages append (`PlaylistTrackItem` is not `Equatable`).
    var loadedRowIds: [Int64] {
        environment.playlists.tracks.compactMap(\.id)
    }

    func load() async {
        try? await environment.playlists.loadTracks(for: playlist)
        syncRowsFromModel()
    }

    /// Mirrors the view model's loaded window into `orderedRows`, except while the
    /// user is actively reordering (a paginated append must not clobber a move).
    func syncRowsFromModel() {
        guard editMode != .active else { return }
        orderedRows = environment.playlists.tracks
    }

    func paginate(_ item: PlaylistTrackItem) {
        guard item.id == environment.playlists.tracks.last?.id, let playlistId = playlist.id else { return }
        Task { try? await environment.playlists.loadMoreTracks(in: playlistId) }
    }

    /// Enters/leaves reorder mode: entering drains every unloaded page (a reorder
    /// rewrites the COMPLETE order, never a truncated window); leaving refetches the
    /// canonical order the reorder persisted to the database.
    func handleEditModeChange(_ mode: EditMode) async {
        guard let playlistId = playlist.id else { return }
        if mode == .active {
            while environment.playlists.hasMoreTracks {
                try? await environment.playlists.loadMoreTracks(in: playlistId)
            }
            orderedRows = environment.playlists.tracks
        } else {
            try? await environment.playlists.loadInitialTracks(in: playlistId)
            orderedRows = environment.playlists.tracks
        }
    }
}

// MARK: - Playback + mutations

private extension PlaylistDetailView {
    func play(_ item: PlaylistTrackItem) {
        guard editMode != .active else { return }
        let refs = orderedRows.map { TrackRef(record: $0.track) }
        guard let index = orderedRows.firstIndex(where: { $0.id == item.id }) else { return }
        environment.coordinator.setQueue(refs, startingAt: index)
        environment.queue.refresh()
    }

    func play(_ tracks: [TrackRecord], shuffled: Bool) {
        let refs = tracks.map { TrackRef(record: $0) }
        guard !refs.isEmpty else { return }
        environment.coordinator.setQueue(shuffled ? refs.shuffled() : refs, startingAt: 0)
        environment.queue.refresh()
    }

    /// Removes the track from THIS playlist only (its library row is untouched).
    func remove(_ item: PlaylistTrackItem) {
        guard let trackId = item.track.id, let playlistId = playlist.id else { return }
        orderedRows.removeAll { $0.id == item.id }
        Task { try? await environment.playlists.removeTrack(trackId, fromPlaylist: playlistId) }
    }

    func move(from source: IndexSet, to destination: Int) {
        orderedRows.move(fromOffsets: source, toOffset: destination)
        guard let playlistId = playlist.id else { return }
        let ids = orderedRows.compactMap(\.track.id)
        Task { try? await environment.playlists.reorderTracks(in: playlistId, orderedTrackIds: ids) }
    }
}

#Preview {
    NavigationStack {
        PlaylistDetailView(playlist: PlaylistRecord(id: 1, name: "My Mix"))
            .environment(AppEnvironment.preview())
            .designTokens(.standard)
    }
}
