// TagEditContextMenu — the shared pieces the row context menu uses to open the
// tag editor.
//
// SwiftUI allows only ONE `.contextMenu` per view, so the row's menu items live
// in ``PlayableTrackList/trackContextMenu(_:)`` (the single extension point its
// header documents) and concurrent surfaces add their buttons there. This file
// supplies the tag-editor side of that button: the multi-selection environment
// value, the `.sheet(item:)` request wrapper, and the pure rule that turns the
// pressed row + an optional selection into the set of records to edit.
//
// `tagEditSelection` defaults to empty, so without any multi-select host the menu
// edits the single pressed track. AppKit-free.
import Persistence
import SwiftUI

// MARK: - Selection environment

public extension EnvironmentValues {
    /// The ids of tracks currently multi-selected in a host list. Empty (default)
    /// means no multi-selection — the tag context menu acts on the single row.
    @Entry var tagEditSelection: Set<Int64> = []
}

// MARK: - Editor request

/// A request to open ``TagEditorSheet`` for a concrete set of records, shaped for
/// `.sheet(item:)` (`TrackRecord` is not itself `Identifiable`).
///
/// `autoFill` asks the editor to run online metadata auto-fill as soon as it opens
/// (the "Auto-fill Tags" context-menu entry point); it stays `false` for the plain
/// "Edit Tags" entry.
struct TagEditorRequest: Identifiable {
    let id = UUID()
    let records: [TrackRecord]
    var autoFill = false
}

// MARK: - Selection resolution (pure)

/// Resolves which records an "Edit Tags" action targets: the multi-selection when
/// the pressed row is part of a selection of two or more, otherwise just the
/// pressed track. Pure so the single/batch decision is trivially reviewable.
func tagEditRecords(
    for track: TrackRecord,
    in tracks: [TrackRecord],
    selection: Set<Int64>
) -> [TrackRecord] {
    guard selection.count > 1, let id = track.id, selection.contains(id) else {
        return [track]
    }
    let chosen = tracks.filter { record in record.id.map(selection.contains) ?? false }
    return chosen.isEmpty ? [track] : chosen
}
