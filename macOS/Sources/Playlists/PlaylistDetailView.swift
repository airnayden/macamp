// PlaylistDetailView — one playlist's tracks on macOS, with play/enqueue,
// add-to-playlist, drag-reorder and remove.
//
// Driven by the shared ``PlaylistViewModel`` (Task 9). A playlist pages its
// ordered membership (`tracks`) keyset-paginated — only the loaded window lives in
// memory; the last row's `onAppear` pulls the next page.
//
// Reorder rewrites the COMPLETE order (`PlaylistViewModel.reorderTracks` deletes
// then re-inserts), so an "Edit Order" toggle first drains every unloaded page
// (`handleEditOrderChange`) before a move can persist a truncated list — the read
// path stays windowed; only the explicit edit action loads the whole list. A local
// `orderedRows` mirror gives instant move/remove feedback because the view model's
// `tracks` is `private(set)`. Removing a track removes it from THIS playlist only,
// never from the library.
//
// Region helpers live in sibling files to keep this source under the SwiftLint
// file-length limit: rows/header in ``PlaylistDetailRows``, the selection context
// menu in ``PlaylistDetailContextMenu``, windowed loading + edit-order draining in
// ``PlaylistDetailLoading``, and playback/membership mutations in
// ``PlaylistDetailActions``.
import DesignSystem
import Foundation
import Persistence
import Services
import SwiftUI
import ViewModels

struct PlaylistDetailView: View {
    let playlist: PlaylistRecord
    var onBack: (() -> Void)?

    @Environment(AppEnvironment.self) var environment
    @Environment(AppSettings.self) var settings
    @Environment(NavigationModel.self) var nav
    @Environment(PlayIntent.self) private var playIntent
    @Environment(\.designTokens) var tokens
    @Environment(\.colorScheme) var scheme

    @State var orderedRows: [PlaylistTrackItem] = []
    @State var selection = Set<Int64>()
    @State var isEditingOrder = false
    @State private var showExportSheet = false
    @State var selectedGenre: GenreFilter = .all
    @State var genreOptions: [GenreFilter] = [.all]
    @State var favouriteOverrides: [Int64: Bool] = [:]
    @State var favouriteIds: Set<Int64> = []
    @State var newPlaylistRequest: NewPlaylistRequest?
    @State private var localFilter = ""

    var body: some View {
        VStack(spacing: 0) {
            if let onBack {
                backBar(onBack)
                Divider()
            }
            if genreOptions.count > 1 {
                GenreFilterChipBar(options: genreOptions, selection: $selectedGenre)
                Divider()
            }
            content
        }
        .task(id: playlist.id) { await load() }
        .onChange(of: loadedRowIds) { _, _ in syncRowsFromModel() }
        .onChange(of: isEditingOrder) { _, editing in
            Task { await handleEditOrderChange(editing) }
        }
        .onChange(of: playIntent.idlePlayToken) { _, _ in playSelectionOrFirst() }
        .sheet(isPresented: $showExportSheet) {
            if let playlistId = playlist.id {
                PlaylistExportSheet(playlistId: playlistId, playlistName: playlist.name)
                    .environment(environment)
            }
        }
        .sheet(item: $newPlaylistRequest) { request in
            PlaylistNameSheet(
                title: MacAMPStrings.playlistsNew,
                confirmLabel: MacAMPStrings.playlistsCreate
            ) { name in
                createPlaylistAndAdd(named: name, trackIds: request.trackIds)
            }
            .designTokens(tokens)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if !displayRows.isEmpty {
            ToolbarItem(placement: .primaryAction) {
                Toggle(isOn: $isEditingOrder) {
                    Label {
                        Text(isEditingOrder ? MacAMPStrings.playlistDoneEditing : MacAMPStrings.playlistEditOrder)
                    } icon: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                }
                .toggleStyle(.button)
            }
            ToolbarItem(placement: .secondaryAction) {
                MacAMPToolbarButton(
                    icon: "square.and.arrow.up",
                    label: MacAMPStrings.playlistExport
                ) {
                    showExportSheet = true
                }
            }
        }
    }

    struct NewPlaylistRequest: Identifiable {
        let id = UUID()
        let trackIds: Set<Int64>
    }
}

// MARK: - Content

extension PlaylistDetailView {
    var displayRows: [PlaylistDetailRow] {
        let raw = orderedRows.enumerated().map { offset, item in
            PlaylistDetailRow(id: item.id ?? 0, position: offset + 1, track: item.track)
        }
        guard !selectedGenre.isAll else { return raw }
        return raw.filter { row in
            switch selectedGenre {
            case .all: true
            case .untagged: row.track.genre == nil || (row.track.genre ?? "").isEmpty
            case let .genre(name): row.track.genre == name
            }
        }
    }

    var visibleRows: [PlaylistDetailRow] {
        guard !localFilter.isEmpty else { return displayRows }
        return displayRows.filter { $0.track.matchesFilter(localFilter) }
    }

    func playSelectionOrFirst() {
        if !selection.isEmpty { primaryPlay(selection) }
        else if let first = visibleRows.first?.id { primaryPlay([first]) }
    }
}

private extension PlaylistDetailView {
    func backBar(_ onBack: @escaping () -> Void) -> some View {
        HStack {
            Button(action: onBack) {
                HStack(spacing: tokens.spacing.xSmall) {
                    Image(systemName: "chevron.left")
                    Text(verbatim: playlist.name)
                        .font(tokens.typography.headline.font)
                }
                .foregroundStyle(tokens.colors.accent.resolve(scheme))
            }
            .buttonStyle(.plain)
            .help(Text(MacAMPStrings.helpBack))
            .pointingHandCursor()
            Spacer()
        }
        .padding(.horizontal, tokens.spacing.medium)
        .padding(.vertical, tokens.spacing.small)
    }

    @ViewBuilder
    var content: some View {
        if displayRows.isEmpty {
            emptyOrLoading
        } else {
            VStack(spacing: 0) {
                if let playlistId = playlist.id {
                    PlayShuffleBar(
                        tracks: displayRows.map(\.track),
                        source: .playlist(id: playlistId),
                        filterText: $localFilter
                    )
                    Divider()
                }
                trackList
            }
        }
    }

    var trackList: some View {
        List(selection: $selection) {
            trackRows
        }
        .scrollContentBackground(.hidden)
        .background(tokens.colors.canvas.resolve(scheme).opacity(0.25))
        .contextMenu(forSelectionType: Int64.self) { ids in
            contextMenu(for: ids)
        } primaryAction: { ids in
            primaryPlay(ids)
        }
    }

    var trackRows: some View {
        ForEach(visibleRows) { row in
            rowView(row)
                .onAppear { paginate(row) }
                .moveDisabled(!localFilter.isEmpty)
        }
        .onMove(perform: move)
    }

    @ViewBuilder
    var emptyOrLoading: some View {
        if environment.playlists.isLoadingTracks {
            StateView.loading()
        } else {
            StateView(
                systemImage: "music.note",
                title: MacAMPStrings.playlistTracksEmptyTitle,
                message: MacAMPStrings.playlistTracksEmptyMessage
            )
        }
    }
}

// MARK: - Row model

struct PlaylistDetailRow: Identifiable {
    let id: Int64
    let position: Int
    let track: TrackRecord
}

#Preview {
    NavigationStack {
        PlaylistDetailView(playlist: PlaylistRecord(id: 1, name: "My Mix"))
            .environment(AppEnvironment.preview())
            .environment(AppSettings.preview)
            .environment(NavigationModel())
            .environment(PlayIntent())
            .designTokens(.standard)
    }
}
