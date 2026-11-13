import DesignSystem
import Persistence
import Services
import SwiftUI
import ViewModels

struct SearchResultsView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(AppSettings.self) private var settings
    @Environment(PlayIntent.self) private var playIntent
    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Group {
            if environment.search.isSearching {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if environment.search.results.isEmpty {
                StateView(
                    systemImage: "magnifyingglass",
                    title: MacAMPStrings.searchResultsTitle,
                    message: MacAMPStrings.featurePendingMessage
                )
            } else {
                resultsList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: playIntent.idlePlayToken) { _, _ in playSelectionOrFirst() }
    }

    private var rows: [LibraryTrackRow] {
        environment.search.results.map { LibraryTrackRow(track: $0) }
    }

    @State private var selection = Set<Int64>()

    private var resultsList: some View {
        Table(rows, selection: $selection) {
            TableColumn("") { row in
                nowPlayingCell(row)
            }
            .width(24)
            TableColumn(String(localized: MacAMPStrings.columnTitle)) { row in
                titleCell(row)
            }
            TableColumn(String(localized: MacAMPStrings.columnArtist)) { row in
                Text(verbatim: row.artistText)
                    .lineLimit(1)
                    .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
            }
            TableColumn(String(localized: MacAMPStrings.columnAlbum)) { row in
                Text(verbatim: row.albumText)
                    .lineLimit(1)
                    .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
            }
            TableColumn(String(localized: MacAMPStrings.columnDuration)) { row in
                Text(verbatim: row.durationText)
                    .monospacedDigit()
                    .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
            }
            .width(60)
            TableColumn("") { row in
                if let state = environment.karaokeRowState(
                    filePath: row.track.filePath,
                    enabled: settings.karaokeEnabled
                ) {
                    KaraokeBadge(
                        state: state,
                        onDequeue: environment.karaokeDequeueAction(
                            filePath: row.track.filePath,
                            enabled: settings.karaokeEnabled
                        )
                    )
                } else if let render = environment.karaokeRenderAction(
                    filePath: row.track.filePath,
                    enabled: settings.karaokeEnabled
                ) {
                    KaraokeRenderButton(action: render)
                }
            }
            .width(24)
        }
        .scrollContentBackground(.hidden)
        .background(tokens.colors.canvas.resolve(scheme).opacity(0.25))
        .contextMenu(forSelectionType: Int64.self) { ids in
            menuItems(for: ids)
        } primaryAction: { ids in
            play(ids)
        }
    }

    @ViewBuilder
    private func nowPlayingCell(_ row: LibraryTrackRow) -> some View {
        if isPlaying(row) {
            Image(systemName: "speaker.wave.2.fill")
                .foregroundStyle(tokens.colors.accent.resolve(scheme))
                .accessibilityLabel(Text(MacAMPStrings.nowPlayingIndicator))
                .accessibilityIdentifier("searchResults.nowPlaying.\(row.id)")
        }
    }

    private func titleCell(_ row: LibraryTrackRow) -> some View {
        Text(verbatim: row.titleText)
            .lineLimit(1)
            .foregroundStyle(isPlaying(row)
                ? tokens.colors.accent.resolve(scheme)
                : tokens.colors.textPrimary.resolve(scheme))
    }

    private func isPlaying(_ row: LibraryTrackRow) -> Bool {
        Self.isPlaying(
            rowTrackId: row.track.id,
            currentTrackId: environment.player.currentTrack?.trackID
        )
    }

    /// Internal (not private) so `macampMacTests` can drive it without a live
    /// coordinator. An unpersisted row or an idle player is never playing.
    nonisolated static func isPlaying(rowTrackId: Int64?, currentTrackId: Int64?) -> Bool {
        guard let rowTrackId, let currentTrackId else { return false }
        return rowTrackId == currentTrackId
    }

    @ViewBuilder
    private func menuItems(for ids: Set<Int64>) -> some View {
        Button { play(ids) } label: {
            Label { Text(MacAMPStrings.menuPlay) } icon: { Image(systemName: "play.fill") }
        }
        Button { enqueue(ids) } label: {
            Label { Text(MacAMPStrings.menuAddToQueue) } icon: { Image(systemName: "text.append") }
        }
        Divider()
        addToPlaylistMenu(ids)
    }

    private func addToPlaylistMenu(_ ids: Set<Int64>) -> some View {
        Menu {
            ForEach(environment.playlists.playlists, id: \.playlist.id) { item in
                Button(item.playlist.name) {
                    guard let playlistId = item.playlist.id else { return }
                    Task {
                        for trackId in ids {
                            try? await environment.playlists.addTrack(trackId, toPlaylist: playlistId)
                        }
                    }
                }
            }
        } label: {
            Label { Text(MacAMPStrings.menuAddToPlaylist) } icon: { Image(systemName: "music.note.list") }
        }
    }

    private func refs(for ids: Set<Int64>) -> [TrackRef] {
        rows.filter { ids.contains($0.id) }.map { TrackRef(record: $0.track) }
    }

    private func playSelectionOrFirst() {
        if !selection.isEmpty { play(selection) }
        else if let first = rows.first?.id { play([first]) }
    }

    private func play(_ ids: Set<Int64>) {
        let selected = refs(for: ids)
        guard !selected.isEmpty else { return }
        environment.coordinator.setQueue(selected, startingAt: 0, source: .search)
        environment.queue.refresh()
    }

    private func enqueue(_ ids: Set<Int64>) {
        let selected = refs(for: ids)
        guard !selected.isEmpty else { return }
        environment.coordinator.enqueueManual(contentsOf: selected)
        environment.queue.refresh()
    }
}

#Preview {
    SearchResultsView()
        .environment(AppEnvironment.preview())
        .environment(AppSettings.preview)
        .environment(PlayIntent())
        .designTokens(.standard)
        .frame(width: 640, height: 400)
}
