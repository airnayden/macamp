// TrackRowActions — the library's row actions, once, for every surface that offers
// them.
//
// ── WHY THIS EXISTS ───────────────────────────────────────────────────────────
//
// Play / Play Next / Add to Queue / Add to Playlist / Edit Tags / favourite were
// written out longhand inside `LibraryBrowserView`'s extension, and every other
// screen that wanted the same menu re-rolled its own bodies against the same
// coordinator. That was survivable while the only full menu lived on one screen. The
// chat transcript now draws real library rows too, and a SECOND longhand copy of
// "enqueue then refresh the queue view model" is the point at which the two drift:
// one surface gets a bug fix, the other keeps the bug.
//
// So the BODIES live here and `LibraryBrowserView` delegates to them unchanged. This
// is a pure extraction — every guard, every ordering, every toast is the one that
// shipped (`LibraryRowDerivationTests` and the composition suites are the fence).
//
// ── THE SURFACE TAKES RESOLVED VALUES, NOT ids ────────────────────────────────
//
// The browser's own methods are id-set-shaped because a `Table` selection is a
// `Set<Int64>` — but turning ids into `TrackRef`s means consulting THAT screen's
// rendered order (`derivedRows`, `displayedTracks`), which is exactly the knowledge
// this helper must not have. So the caller resolves and this helper acts:
// `[TrackRef]` for the transport, `TrackRecord` for the favourite toggle (the shape
// `LibraryBrowserActions.toggleFavourite(_:)` already had — a favourite needs a name
// for its toast, which an id does not carry).
//
// Nothing here reads the database on the main thread: `toggleFavourite` hands the
// write to a `Task`, exactly as before.
import Persistence
import Services
import SwiftUI

/// The library's per-row actions, shared by every list that offers them.
@MainActor
struct TrackRowActions {
    let environment: AppEnvironment

    /// The profile every write is attributed to.
    var activeProfileId: Int64 {
        environment.profileService.activeProfile.id ?? ProfileRecord.guestID
    }

    /// Replaces the queue with `refs` and starts at the clicked track.
    ///
    /// `clickedId` is the row the listener acted on; a `nil` (or absent) id starts at
    /// the top, which is what "Play" on a whole list means.
    func play(_ refs: [TrackRef], startingAt clickedId: Int64?, source: PlaybackSource) {
        guard !refs.isEmpty else { return }
        let startIndex = refs.firstIndex(where: { $0.trackID == clickedId }) ?? 0
        environment.coordinator.setQueue(refs, startingAt: startIndex, source: source)
        environment.queue.refresh()
    }

    /// Appends to the manual queue.
    func enqueue(_ refs: [TrackRef]) {
        guard !refs.isEmpty else { return }
        environment.coordinator.enqueueManual(contentsOf: refs)
        environment.queue.refresh()
    }

    /// Inserts at the front of the manual queue.
    func playNext(_ refs: [TrackRef]) {
        guard !refs.isEmpty else { return }
        environment.coordinator.playNextManual(contentsOf: refs)
        environment.queue.refresh()
    }

    /// Adds every id to `playlist`, then names the playlist in a toast.
    func addTracks(_ ids: some Sequence<Int64>, toPlaylist playlist: PlaylistRecord) {
        guard let playlistId = playlist.id else { return }
        let name = playlist.name
        let trackIds = Array(ids)
        Task {
            for trackId in trackIds {
                try? await environment.playlists.addTrack(trackId, toPlaylist: playlistId)
            }
            environment.toast.show(
                text: "\(String(localized: MacAMPStrings.menuAddToPlaylist)) \(name)",
                icon: "music.note.list"
            )
        }
    }

    /// Flips this profile's favourite flag and reports it.
    ///
    /// `wasFavourite` is the caller's own optimistic reading (the browser keeps a
    /// per-row override so the heart flips before the write lands), so the toast and
    /// the write agree with what the listener just saw.
    func toggleFavourite(_ track: TrackRecord, wasFavourite: Bool) {
        guard let trackId = track.id else { return }
        let profileId = activeProfileId
        let repository = TrackRepository(environment.database)
        let name = track.title ?? track.filePath
        Task { try? await repository.toggleFavourite(profileId: profileId, trackId: trackId) }
        environment.toast.show(
            text: wasFavourite
                ? "\(String(localized: FavouritesStrings.removedToast)) \"\(name)\""
                : "\(String(localized: FavouritesStrings.addedToast)) \"\(name)\"",
            icon: wasFavourite ? "heart.slash" : "heart.fill"
        )
    }

    /// The tag-editor sheet request for `records`, or `nil` when there is nothing to
    /// edit. The REQUEST rather than the presentation: which `@State` it lands in is
    /// the calling screen's business.
    static func tagEditRequest(for records: [TrackRecord]) -> TagEditorRequest? {
        records.isEmpty ? nil : TagEditorRequest(records: records)
    }
}
