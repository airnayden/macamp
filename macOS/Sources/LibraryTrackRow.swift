// LibraryTrackRow — the row view-model backing the macOS library table.
//
// A thin, `Identifiable` projection of a ``TrackRecord`` exposing the exact
// sort keys (`titleText`, `artistText`, `albumText`, `trackNumber`,
// `durationSeconds`) the `SwiftUI.Table` columns sort over, plus their
// display strings. Extracted from `LibraryBrowserView` so the view file stays
// within the design-system line budget; both live in the macOS app module.
import Persistence

/// One library track projected for the sortable, virtualized `SwiftUI.Table`.
struct LibraryTrackRow: Identifiable {
    let track: TrackRecord

    var id: Int64 {
        track.id ?? 0
    }

    var titleText: String {
        track.displayTitle
    }

    var artistText: String {
        track.artistName ?? ""
    }

    var albumText: String {
        track.albumTitle ?? ""
    }

    var trackNumber: Int {
        track.trackNumber ?? 0
    }

    var trackNumberText: String {
        trackNumber == 0 ? "" : String(trackNumber)
    }

    var durationSeconds: Double {
        track.duration ?? 0
    }

    var durationText: String {
        Self.format(durationSeconds)
    }

    static func format(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
