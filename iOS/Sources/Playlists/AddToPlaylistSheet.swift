// AddToPlaylistSheet — picks an existing (plain) playlist to append a track to,
// or creates a new one on the spot.
//
// Presented from a ``PlayableTrackList`` row's context menu. Lists the shared
// ``PlaylistViewModel``'s playlists (keyset-paginated — only the loaded window
// lives in memory). Tapping a playlist appends the track through the view model's
// off-actor `addTrack`; the "New Playlist…" row seeds a ``PlaylistNameSheet`` that
// creates the list then adds the track. All data operations go through the view
// model; nothing blocks the main actor.
import DesignSystem
import Persistence
import SwiftUI

/// A modal that adds one track to a chosen (or freshly created) playlist.
struct AddToPlaylistSheet: View {
    let track: TrackRecord

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss

    @State private var isCreating = false

    var body: some View {
        NavigationStack {
            List {
                Button { isCreating = true } label: { newPlaylistRow }
                    .buttonStyle(.plain)
                ForEach(targets, id: \.playlist.id) { item in
                    Button { add(to: item.playlist) } label: { row(item) }
                        .buttonStyle(.plain)
                        .onAppear { paginate(item) }
                }
            }
            .listStyle(.plain)
            .navigationTitle(Text(MacAMPStrings.playlistAddToTitle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) { dismiss() } label: {
                        Text(MacAMPStrings.playlistsCancel)
                    }
                }
            }
            .task { await loadIfNeeded() }
            .sheet(isPresented: $isCreating) {
                PlaylistNameSheet(
                    title: MacAMPStrings.playlistsNew,
                    confirmLabel: MacAMPStrings.playlistsCreate,
                    onCommit: createAndAdd
                )
            }
        }
    }
}

// MARK: - Rows

private extension AddToPlaylistSheet {
    /// Playlists a track can be added to.
    var targets: [PlaylistWithTrackCount] {
        environment.playlists.playlists
    }

    var newPlaylistRow: some View {
        HStack(spacing: tokens.spacing.medium) {
            Image(systemName: "plus.circle.fill")
                .font(tokens.typography.titleMedium.font)
                .foregroundStyle(tokens.colors.accent.resolve(scheme))
                .frame(width: 36)
            Text(MacAMPStrings.playlistAddToNew)
                .font(tokens.typography.headline.font)
                .foregroundStyle(tokens.colors.accent.resolve(scheme))
            Spacer(minLength: 0)
        }
        .padding(.vertical, tokens.spacing.xSmall)
    }

    func row(_ item: PlaylistWithTrackCount) -> some View {
        HStack(spacing: tokens.spacing.medium) {
            Image(systemName: "music.note.list")
                .font(tokens.typography.headline.font)
                .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
                .frame(width: 36)
            Text(verbatim: item.playlist.name)
                .font(tokens.typography.headline.font)
                .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
                .lineLimit(1)
            Spacer(minLength: tokens.spacing.small)
            Text(verbatim: "\(item.trackCount)")
                .font(tokens.typography.timecode.font)
                .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
        }
        .padding(.vertical, tokens.spacing.xSmall)
    }
}

// MARK: - Data

private extension AddToPlaylistSheet {
    func loadIfNeeded() async {
        guard environment.playlists.playlists.isEmpty else { return }
        try? await environment.playlists.loadInitialPlaylists()
    }

    func paginate(_ item: PlaylistWithTrackCount) {
        guard item.playlist.id == targets.last?.playlist.id else { return }
        Task { try? await environment.playlists.loadMorePlaylists() }
    }

    func add(to playlist: PlaylistRecord) {
        guard let trackId = track.id, let playlistId = playlist.id else { dismiss(); return }
        Task {
            try? await environment.playlists.addTrack(trackId, toPlaylist: playlistId)
            dismiss()
        }
    }

    func createAndAdd(named name: String) {
        guard let trackId = track.id else { dismiss(); return }
        Task {
            let playlist = try? await environment.playlists.createPlaylist(named: name)
            if let playlistId = playlist?.id {
                try? await environment.playlists.addTrack(trackId, toPlaylist: playlistId)
            }
            dismiss()
        }
    }
}

#Preview {
    let sampleTitle = "Song"
    return AddToPlaylistSheet(track: TrackRecord(filePath: "/music/song.flac", title: sampleTitle))
        .environment(AppEnvironment.preview())
        .designTokens(.standard)
}
