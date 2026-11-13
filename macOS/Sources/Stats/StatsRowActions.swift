// StatsRowActions — the ONE definition of "this history row is still playable".
//
// Every list on the stats page renders from the SURVIVABLE history: `playEvent`
// snapshots, monthly rollups and `playSegmentHeat`, none of which join the library.
// A row therefore always has text to show, but only sometimes has a live track
// behind it — the file may have been deleted, or moved out of the active profile's
// roots, since the play was recorded.
//
// That single fact decides the row's entire interaction surface, so it is expressed
// once here rather than three times across the top lists, the most-replayed list and
// the recent-plays list:
//
//   * **Resolved** → double-click plays it, a context menu offers Play and Add to
//     Queue, and the pointer turns into a hand over the whole row rectangle.
//   * **Unresolved** → nothing. No hand cursor, no double-click, no menu.
//
// The unresolved branch is not an oversight but the SKILL's disabled-state cursor
// rule: the hand cursor promises interactivity, so a row that cannot act must never
// show it. The row still renders its snapshot text — a deleted track keeps its place
// in your history.
//
// Play deliberately queues the ONE track rather than the whole list. A statistics
// list is a ranking, not a running order, and silently replacing the queue with ten
// ranked songs would be a side effect the user never asked for.
import DesignSystem
import Persistence
import Services
import SwiftUI

extension View {
    /// Makes a statistics row playable when its history entry still resolves to a
    /// live library row, and completely inert when it does not.
    ///
    /// Pass the `resolved` track a row already carries — `RecentPlay.resolved`,
    /// `ReplayedRow.resolved`, or `ListeningStatsViewModel.resolvedTopTrack(_:in:)`.
    /// `nil` leaves the row untouched.
    func statsRowActions(for resolved: ProfileScopedTrack?) -> some View {
        modifier(StatsRowActions(resolved: resolved))
    }
}

/// The playable-row affordances shared by every list on the stats page.
struct StatsRowActions: ViewModifier {
    /// The live library row behind this history entry, or `nil` when it is gone.
    let resolved: ProfileScopedTrack?

    @Environment(AppEnvironment.self) private var environment

    func body(content: Content) -> some View {
        if let resolved {
            content
                .contentShape(Rectangle())
                .pointingHandCursor()
                .onTapGesture(count: 2) { play(resolved) }
                .contextMenu { menu(for: resolved) }
        } else {
            content
        }
    }
}

// MARK: - Actions

private extension StatsRowActions {
    @ViewBuilder
    func menu(for track: ProfileScopedTrack) -> some View {
        Button { play(track) } label: {
            Label { Text(MacAMPStrings.menuPlay) } icon: { Image(systemName: "play.fill") }
        }
        Button { enqueue(track) } label: {
            Label { Text(MacAMPStrings.menuAddToQueue) } icon: { Image(systemName: "text.append") }
        }
    }

    /// Plays just this track. See the file note on why the surrounding ranking is
    /// not queued with it.
    func play(_ track: ProfileScopedTrack) {
        environment.coordinator.setQueue([TrackRef(record: track.track)], startingAt: 0, source: .stats)
        environment.queue.refresh()
    }

    func enqueue(_ track: ProfileScopedTrack) {
        environment.coordinator.enqueueManual(TrackRef(record: track.track))
        environment.queue.refresh()
    }
}
