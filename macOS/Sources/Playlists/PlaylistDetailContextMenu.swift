// PlaylistDetailContextMenu — the right-click / primary-action menu for a
// selection of rows in ``PlaylistDetailView`` (play, play-next, enqueue,
// add-to-playlist, remove).
//
// EVERY ITEM HERE ACTS ON THE SELECTED ROWS. "Organize…" used to be listed among
// them and did not: all four of its actions rewrite the WHOLE playlist, so offering
// them from a song's own menu described the wrong subject. They now live on the
// playlist-level surfaces — see ``PlaylistOrganizeMenu``.
//
// Split out of the view file purely to keep each source under the SwiftLint
// file-length limit; the members are internal (not private) because the view's
// `trackList` in the parent file invokes `contextMenu(for:)`. The mutations it
// triggers live in ``PlaylistDetailActions``.
import Persistence
import SwiftUI

extension PlaylistDetailView {
    var addTargets: [PlaylistWithTrackCount] {
        environment.playlists.playlists.filter {
            $0.playlist.id != playlist.id
        }
    }

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
            filePaths: displayRows.filter { ids.contains($0.id) }.map(\.track.filePath),
            enabled: settings.karaokeEnabled
        )
        addToMenu(ids)
        Divider()
        Button(role: .destructive) { remove(ids) } label: {
            Label { Text(MacAMPStrings.playlistRemove) } icon: { Image(systemName: "minus.circle") }
        }
    }

    func addToMenu(_ ids: Set<Int64>) -> some View {
        Menu {
            Button {
                let resolved = Set(displayRows.filter { ids.contains($0.id) }.compactMap(\.track.id))
                newPlaylistRequest = NewPlaylistRequest(trackIds: resolved)
            } label: {
                Label { Text(MacAMPStrings.menuNewPlaylist) } icon: { Image(systemName: "plus") }
            }
            let targets = addTargets
            if !targets.isEmpty {
                Divider()
                ForEach(targets, id: \.playlist.id) { item in
                    if let targetId = item.playlist.id {
                        Button { addToPlaylist(targetId, ids: ids) } label: {
                            Text(verbatim: item.playlist.name)
                        }
                    }
                }
            }
        } label: {
            Label { Text(MacAMPStrings.playlistAddTo) } icon: { Image(systemName: "text.badge.plus") }
        }
    }
}
