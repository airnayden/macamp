// PlaylistDetailActions — the playback + membership mutations behind
// ``PlaylistDetailView``'s context menu, double-click and drag-reorder.
//
// Split out of the view file purely to keep each source under the SwiftLint
// file-length limit; the methods are internal (not private) because the view's
// rows/menu/header in the sibling file invoke them. Every database touch routes
// through the shared ``PlaylistViewModel`` (off the main actor). Removing a track
// drops it from THIS playlist only; reorder rewrites the COMPLETE order the
// view's drain step prepared.
import Foundation
import Persistence
import Services

extension PlaylistDetailView {
    func refs(for ids: Set<Int64>) -> [TrackRef] {
        displayRows.filter { ids.contains($0.id) }.map { TrackRef(record: $0.track) }
    }

    func primaryPlay(_ ids: Set<Int64>) {
        guard !isEditingOrder else { return }
        if ids.count == 1, let rowId = ids.first {
            playFromList(startingAt: rowId)
        } else {
            play(ids)
        }
    }

    func playFromList(startingAt rowId: Int64) {
        let allRefs = displayRows.map { TrackRef(record: $0.track) }
        guard let playlistId = playlist.id,
              let index = displayRows.firstIndex(where: { $0.id == rowId })
        else { return }
        environment.coordinator.setQueue(allRefs, startingAt: index, source: .playlist(id: playlistId))
        environment.queue.refresh()
    }

    func play(_ ids: Set<Int64>) {
        let selected = refs(for: ids)
        guard let playlistId = playlist.id, !selected.isEmpty else { return }
        environment.coordinator.setQueue(selected, startingAt: 0, source: .playlist(id: playlistId))
        environment.queue.refresh()
    }

    func play(_ tracks: [TrackRecord], shuffled: Bool) {
        let trackRefs = tracks.map { TrackRef(record: $0) }
        guard let playlistId = playlist.id, !trackRefs.isEmpty else { return }
        environment.coordinator.setQueue(
            shuffled ? trackRefs.shuffled() : trackRefs,
            startingAt: 0,
            source: .playlist(id: playlistId)
        )
        environment.queue.refresh()
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

    func addToPlaylist(_ targetId: Int64, ids: Set<Int64>) {
        let trackIds = displayRows.filter { ids.contains($0.id) }.compactMap(\.track.id)
        Task {
            for trackId in trackIds {
                try? await environment.playlists.addTrack(trackId, toPlaylist: targetId)
            }
        }
    }

    func createPlaylistAndAdd(named name: String, trackIds: Set<Int64>) {
        Task {
            guard let created = try? await environment.playlists.createPlaylist(named: name),
                  let playlistId = created.id
            else { return }
            for trackId in trackIds {
                try? await environment.playlists.addTrack(trackId, toPlaylist: playlistId)
            }
            try? await environment.playlists.loadInitialPlaylists()
            environment.toast.show(
                text: "\(String(localized: MacAMPStrings.menuAddToPlaylist)) \(name)",
                icon: "music.note.list"
            )
        }
    }

    func remove(_ ids: Set<Int64>) {
        guard let playlistId = playlist.id else { return }
        let removedTrackIds = displayRows.filter { ids.contains($0.id) }.compactMap(\.track.id)
        orderedRows.removeAll { ids.contains($0.id ?? 0) }
        selection.subtract(ids)
        Task {
            for trackId in removedTrackIds {
                try? await environment.playlists.removeTrack(trackId, fromPlaylist: playlistId)
            }
        }
    }

    func move(from source: IndexSet, to destination: Int) {
        orderedRows.move(fromOffsets: source, toOffset: destination)
        environment.coordinator.reorderQueue(orderedRows.map { TrackRef(record: $0.track) })
        environment.queue.refresh()
        guard let playlistId = playlist.id else { return }
        let ids = orderedRows.compactMap(\.track.id)
        Task { try? await environment.playlists.reorderTracks(in: playlistId, orderedTrackIds: ids) }
    }
}
