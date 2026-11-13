// AutoMixListViewModel — the READ-ONLY projection of one profile's
// generator-backed playlists (Task 26).
//
// A surface that shows auto-mixes needs exactly two things from
// ``GeneratedPlaylistProviding``, in this order: bring the stale kinds up to date,
// then list what exists. Both are per profile, so both take the profile this view
// model is scoped to — which is what makes "profile A never sees profile B's
// mixes" a property of the view model rather than of each shell's call site.
//
// Three deliberate properties:
//
//  * NOTHING runs on its own. There is no timer and no observation; ``load()`` is
//    called when a surface APPEARS. `refreshIfStale` is a documented no-op inside
//    its TTL (it returns before touching the generator or the repository), so
//    calling it on every appearance costs one bounded read when the mixes are
//    fresh.
//  * ``load()`` is RE-ENTRANCY GUARDED. A second call while the first is in
//    flight returns immediately instead of stacking a second refresh — the
//    service has its own per-profile latch, but the guard is what keeps a shell
//    that re-renders mid-load from queueing work at all.
//  * It is READ-ONLY. There is no create, rename, delete or reorder here: a mix
//    materialises into an ordinary `playlist` row, so every edit a listener could
//    want already exists on the ordinary playlist surface. Adding one here would
//    be a second way to write the same rows.
//
// Failures are SWALLOWED and the previous listing is kept. A generated playlist is
// ambient, not requested: a listener who opened a playlists screen did not ask for
// a mix, so a transient database error must not replace their list with an error
// state. The refresh simply runs again the next time the surface appears.
import Foundation
import Observation
import Persistence
import Services

/// Lists a profile's generator-backed playlists, refreshing the stale ones when a
/// surface that shows them appears.
@MainActor
@Observable
public final class AutoMixListViewModel {
    /// The profile's generator-backed playlists, ordered by the service (kind,
    /// then id) — stable across loads, so rows never re-order under the listener.
    public private(set) var mixes: [GeneratedPlaylistSummary] = []

    /// `true` while ``load()`` is in flight. A surface can show progress on the
    /// first launch, when the mixes are being materialised for the first time.
    public private(set) var isLoading = false

    /// The profile whose mixes are listed. Set at construction from the active
    /// profile; assignable so a profile-switch seam can retarget the view model.
    @ObservationIgnored public var activeProfileId: Int64

    @ObservationIgnored private let service: any GeneratedPlaylistProviding

    /// - Parameters:
    ///   - service: The generated-playlist service to refresh and list through.
    ///   - activeProfileId: The profile to scope both calls to (Guest by default).
    public init(service: any GeneratedPlaylistProviding, activeProfileId: Int64 = ProfileRecord.guestID) {
        self.service = service
        self.activeProfileId = activeProfileId
    }

    /// The `playlist` rows the listed mixes materialise into.
    ///
    /// A generated playlist is an ORDINARY playlist, so a surface that lists both
    /// needs this to tell them apart — without it the same row would appear twice.
    public var playlistIds: Set<Int64> {
        Set(mixes.map(\.playlistId))
    }

    /// Refreshes the profile's stale mixes, then reloads the listing.
    ///
    /// - Returns: `true` when the refresh actually created or rewrote a mix, so
    ///   the caller can reload whatever list it renders these rows from. `false`
    ///   when everything was fresh (the common case) or when a call was already in
    ///   flight.
    @discardableResult
    public func load() async -> Bool {
        guard !isLoading else { return false }
        isLoading = true
        defer { isLoading = false }
        let profileId = activeProfileId
        let applied = await (try? service.refreshIfStale(profileId: profileId)) ?? []
        if let summaries = try? await service.generatedPlaylists(profileId: profileId), summaries != mixes {
            // Observation notifies on a same-value write, and this runs on every
            // appearance — the guard keeps an unchanged listing from invalidating
            // every observing view.
            mixes = summaries
        }
        return !applied.isEmpty
    }
}
