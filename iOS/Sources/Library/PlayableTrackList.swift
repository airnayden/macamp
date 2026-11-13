// PlayableTrackList — a reusable, paginated list of playable library tracks.
//
// Shared by the Library browser (Songs scope + inline search) and the Search
// screen. Renders DesignSystem ``TrackRow``s, marks the currently-playing track,
// dims + badges unavailable files, and on tap replaces the play queue with the
// list and starts at the tapped row (the coordinator is the single source of
// truth). Pagination is driven by the LAST row's `onAppear` — only the loaded
// window ever lives in memory, never the whole 100k-row table.
//
// Each row carries a context menu whose items live in ``trackContextMenu`` so
// concurrent surfaces extend ONE place: Task 19 adds "Add to Playlist…" (presents
// ``AddToPlaylistSheet``); Task 17 adds "Edit Tags…".
import DesignSystem
import Persistence
import Services
import SwiftUI

/// A `List` of tracks that plays the queue from the tapped row and paginates as
/// the user scrolls to the end.
struct PlayableTrackList: View {
    let tracks: [TrackRecord]
    var onReachEnd: () -> Void = {}

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    @Environment(\.tagEditSelection) private var tagEditSelection

    @State private var addTarget: AddToPlaylistTarget?
    @State private var tagEditRequest: TagEditorRequest?

    var body: some View {
        List {
            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                Button { play(at: index) } label: { row(track) }
                    .buttonStyle(.plain)
                    .accessibilityHint(Text(MacAMPStrings.a11yHintPlayTrack))
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .onAppear { paginate(track) }
                    .contextMenu { trackContextMenu(track) }
            }
        }
        .listStyle(.plain)
        .sheet(item: $addTarget) { AddToPlaylistSheet(track: $0.track) }
        .sheet(item: $tagEditRequest) { request in
            TagEditorSheet(records: request.records, autoFillOnOpen: request.autoFill)
                .environment(environment)
                .designTokens(tokens)
        }
    }
}

/// A track wrapped for `.sheet(item:)`, keyed by its unique file path (the record
/// itself is not `Identifiable`).
private struct AddToPlaylistTarget: Identifiable {
    let track: TrackRecord
    var id: String {
        track.filePath
    }
}

// MARK: - Rows

private extension PlayableTrackList {
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

    func durationToken(_ track: TrackRecord) -> Duration? {
        guard track.availability == .present, let seconds = track.duration else { return nil }
        return .seconds(seconds)
    }

    func isPlaying(_ track: TrackRecord) -> Bool {
        guard let trackID = track.id else { return false }
        return trackID == environment.player.currentTrack?.trackID
    }
}

// MARK: - Context menu

private extension PlayableTrackList {
    @ViewBuilder
    func trackContextMenu(_ track: TrackRecord) -> some View {
        Button { addTarget = AddToPlaylistTarget(track: track) } label: {
            Label { Text(MacAMPStrings.playlistAddTo) } icon: { Image(systemName: "text.badge.plus") }
        }
        let editRecords = tagEditRecords(for: track, in: tracks, selection: tagEditSelection)
        Button { tagEditRequest = TagEditorRequest(records: editRecords) } label: {
            Label {
                Text(editRecords.count > 1
                    ? MacAMPStrings.tagsMenuMulti(editRecords.count)
                    : MacAMPStrings.tagsMenuSingle)
            } icon: {
                Image(systemName: "pencil")
            }
        }
        if editRecords.count == 1 {
            Button { tagEditRequest = TagEditorRequest(records: editRecords, autoFill: true) } label: {
                Label { Text(MacAMPStrings.tagsMenuAutoFill) } icon: { Image(systemName: "wand.and.stars") }
            }
        }
    }
}

// MARK: - Actions

private extension PlayableTrackList {
    func play(at index: Int) {
        let refs = tracks.map { TrackRef(record: $0) }
        guard refs.indices.contains(index) else { return }
        environment.coordinator.setQueue(refs, startingAt: index)
        environment.queue.refresh()
    }

    func paginate(_ track: TrackRecord) {
        guard track.id == tracks.last?.id else { return }
        onReachEnd()
    }
}
