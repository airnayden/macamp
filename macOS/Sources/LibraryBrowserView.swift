import DesignSystem
import Persistence
import Services
import SwiftUI
import ViewModels

/// The detail pane: a virtualized, keyset-paginated table of library tracks.
///
/// Only the loaded window lives in memory — `SwiftUI.Table` renders just the
/// visible rows, and the last visible row's `onAppear` pulls the next keyset page
/// (never the whole 100k-row table). With no `filterRootPath` it shows every track
/// via the shared ``LibraryViewModel``; with one it shows just that library root's
/// tracks via a per-root ``FolderBrowserViewModel`` (`tracksByRoot`). Columns are
/// sortable over the loaded window, rows multi-selectable, and a context menu /
/// double-click drives the playback coordinator.
///
/// The data-loading and playback/menu actions live in a sibling
/// ``LibraryBrowserView`` extension (`LibraryBrowserActions.swift`) so this file
/// stays within the design-system line budget; the members they touch are
/// therefore internal rather than private.
struct LibraryBrowserView: View {
    /// When non-nil, the browser shows only the tracks under this library-root
    /// folder (the sidebar `.folder(rootId:)` selection); nil shows All Tracks.
    var filterRootPath: String?

    @Environment(AppEnvironment.self) var environment
    @Environment(AppSettings.self) var settings
    @Environment(NavigationModel.self) var nav
    @Environment(PlayIntent.self) private var playIntent
    @Environment(\.designTokens) var tokens
    @Environment(\.colorScheme) var scheme

    @State var selection = Set<Int64>()
    @State var localFilter = ""
    /// Non-empty filter text replaces the rows below with ranked FTS5 results and
    /// leaves the browse window untouched, so clearing it restores the list for
    /// free. Wired in `LibraryBrowserSearch.swift`.
    @State var localSearch = LibraryLocalSearchModel()
    /// Snapshot of the active track list, refreshed via `syncSourceTracks()` after
    /// each load. Reading `environment.library.tracks` directly does not re-render
    /// when it changes (nested `@Observable` via `@Environment` does not propagate
    /// here), so the list is driven by this `@State` instead.
    @State var sourceTracks: [TrackRecord] = []
    /// The rendered rows, derived once per change rather than per body evaluation.
    /// Rebuilt only by ``rebuildDerivedRows()`` (`LibraryBrowserRows.swift`), which
    /// documents every trigger.
    @State var derivedRows: [LibraryTrackRow] = []
    /// `derivedRows`' row id → position, so the scroll prefetch locates a row in
    /// O(1) instead of scanning the window on every `onAppear`.
    @State var rowIndexById: [Int64: Int] = [:]
    @State var sortOrder = [KeyPathComparator(\LibraryTrackRow.titleText)]
    @State var folderModel: FolderBrowserViewModel?
    @State var genreModel: GenreBrowserViewModel?
    @State var selectedGenre: GenreFilter = .all
    @State var genreOptions: [GenreFilter] = [.all]
    @State var tagEditRequest: TagEditorRequest?
    /// Internal, not `private`: the sibling-file loudness extension sets it.
    @State var replayGainWriteRequest: ReplayGainWriteRequest?
    /// Internal, not `private`: the sibling-file integrity extension sets it.
    @State var integrityReportRequest: IntegrityReportRequest?
    @State private var newPlaylistRequest: NewPlaylistRequest?
    @State private var isDropTargeted = false
    @State private var deleteTracksConfirm: Set<Int64>?
    @State var favouriteOverrides: [Int64: Bool] = [:]
    @State var favouriteIds: Set<Int64> = []
    @State var prefetchGate = LibraryPrefetchGate()
    /// Per-level outline state for a `.folder` destination; nil in every other mode.
    /// Built and driven in `FolderOutlineView.swift`.
    @State var outline: FolderOutlineViewModel?

    var body: some View {
        VStack(spacing: 0) {
            if showsBrowseHeader {
                browseHeader
                Divider()
            }
            content
        }
        .dropDestination(for: URL.self, action: { urls, _ in
            handleDrop(urls)
        }, isTargeted: { targeted in
            isDropTargeted = targeted
        })
        .overlay { dropOverlay }
        .animation(.easeInOut(duration: 0.15), value: isDropTargeted)
        .task(id: loadKey) { await load() }
        .onAppear { Task { await load() } }
        .onChange(of: selectedGenre) { _, _ in
            rebuildDerivedRows()
            Task { await reloadTracks() }
        }
        .onChange(of: environment.libraryFolders.revision) { _, _ in
            Task { await reloadTracks() }
        }
        .onChange(of: localSearch.isActive) { _, _ in rebuildDerivedRows() }
        .onChange(of: localSearch.results) { _, _ in rebuildDerivedRows() }
        .onChange(of: sortOrder) { _, _ in rebuildDerivedRows() }
        .onChange(of: playIntent.idlePlayToken) { _, _ in playSelectionOrFirst() }
        .sheet(item: $tagEditRequest, onDismiss: { Task { await reloadTracks() } }, content: { request in
            TagEditorSheet(records: request.records)
        })
        .sheet(item: $replayGainWriteRequest) { request in
            ReplayGainWriteSheet(plan: request.plan)
                .environment(environment)
                .designTokens(tokens)
        }
        .sheet(item: $integrityReportRequest) { request in
            IntegrityReportSheet(targets: request.targets)
                .environment(environment)
                .designTokens(tokens)
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
        .alert(
            Text(MacAMPStrings.menuDeleteTracksTitle),
            isPresented: Binding(
                get: { deleteTracksConfirm != nil },
                set: { if !$0 { deleteTracksConfirm = nil } }
            )
        ) {
            Button(String(localized: MacAMPStrings.sidebarDeletePlaylist), role: .destructive) {
                guard let ids = deleteTracksConfirm else { return }
                let count = ids.count
                Task {
                    let repository = TrackRepository(environment.database)
                    for trackId in ids {
                        _ = try? repository.deleteTrack(id: trackId)
                    }
                    await reloadTracks()
                    environment.toast.show(text: String(localized: MacAMPStrings.tracksDeletedToast(count)))
                }
                deleteTracksConfirm = nil
            }
        } message: {
            if let ids = deleteTracksConfirm {
                Text(MacAMPStrings.menuDeleteTracks(ids.count))
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if derivedRows.isEmpty {
            if isLoadingTracks {
                StateView.loading()
                    .synthwaveEmptyBackground()
            } else {
                StateView.empty(action: addFolderAction)
                    .synthwaveEmptyBackground()
            }
        } else {
            VStack(spacing: 0) {
                PlayShuffleBar(
                    tracks: displayedTracks,
                    source: playbackSource,
                    filterText: localFilterBinding
                )
                Divider()
                browseContent
            }
        }
    }

    private var table: some View {
        Table(sortedRows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn(String(localized: MacAMPStrings.columnNumber), value: \.trackNumber) { row in
                numberCell(row)
            }
            .width(44)
            TableColumn(String(localized: MacAMPStrings.columnTitle), value: \.titleText) { row in
                titleCell(row)
            }
            TableColumn(String(localized: MacAMPStrings.columnArtist), value: \.artistText) { row in
                ArtistLink(name: row.artistText, artistId: row.track.artistId)
            }
            TableColumn(String(localized: MacAMPStrings.columnAlbum), value: \.albumText) { row in
                Text(verbatim: row.albumText)
                    .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
            }
            TableColumn(String(localized: MacAMPStrings.columnDuration), value: \.durationSeconds) { row in
                Text(verbatim: row.durationText)
                    .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
                    .monospacedDigit()
            }
            .width(80)
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
    private func numberCell(_ row: LibraryTrackRow) -> some View {
        if isCurrent(row.track) {
            Image(systemName: "speaker.wave.2.fill")
                .foregroundStyle(tokens.colors.accent.resolve(scheme))
                .accessibilityLabel(Text(MacAMPStrings.nowPlayingIndicator))
        } else {
            Text(verbatim: row.trackNumberText)
                .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
                .monospacedDigit()
        }
    }

    private func titleCell(_ row: LibraryTrackRow) -> some View {
        HStack(spacing: tokens.spacing.xSmall) {
            Text(verbatim: row.titleText)
                .foregroundStyle(isCurrent(row.track)
                    ? tokens.colors.accent.resolve(scheme)
                    : tokens.colors.textPrimary.resolve(scheme))
                .lineLimit(1)
            Spacer(minLength: 0)
            availabilityBadge(row)
        }
        .onAppear { loadMoreIfNeeded(row) }
    }

    @ViewBuilder
    func menuItems(for ids: Set<Int64>) -> some View {
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
            filePaths: records(for: ids).map(\.filePath),
            enabled: settings.karaokeEnabled
        )
        Divider()
        addToPlaylistMenu(ids)
        moreLikeThisMenuItem(ids)
        Divider()
        Button { editTags(ids) } label: {
            Label { editTagsLabel(for: ids) } icon: { Image(systemName: "tag") }
        }
        Button { analyzeLoudness(ids) } label: {
            Label {
                Text(ReplayGainTagStrings.analyze)
            } icon: {
                Image(systemName: "waveform.badge.magnifyingglass")
            }
        }
        Button { requestReplayGainWrite(ids) } label: {
            Label { Text(ReplayGainTagStrings.write) } icon: { Image(systemName: "tag.square") }
        }
        Button { verifyFiles(ids) } label: {
            Label { Text(IntegrityStrings.menuVerify) } icon: { Image(systemName: "checkmark.shield") }
        }
        .accessibilityIdentifier("track.action.verifyFiles")
        Divider()
        Button(role: .destructive) { deleteTracksConfirm = ids } label: {
            Label { Text(MacAMPStrings.menuDeleteTracks(ids.count)) } icon: { Image(systemName: "trash") }
        }
    }

    private func addToPlaylistMenu(_ ids: Set<Int64>) -> some View {
        Menu {
            Button {
                newPlaylistRequest = NewPlaylistRequest(trackIds: ids)
            } label: {
                Label { Text(MacAMPStrings.menuNewPlaylist) } icon: { Image(systemName: "plus") }
            }
            if !environment.playlists.playlists.isEmpty {
                Divider()
            }
            ForEach(environment.playlists.playlists, id: \.playlist.id) { item in
                Button(item.playlist.name) {
                    addTracks(ids, toPlaylist: item.playlist)
                }
            }
        } label: {
            Label { Text(MacAMPStrings.menuAddToPlaylist) } icon: { Image(systemName: "music.note.list") }
        }
    }
}

private extension LibraryBrowserView {
    /// The genre chips, the folder Sort menu, or both — drawn only when at least one
    /// of them has something to offer, so All Tracks with one genre keeps today's
    /// header-free layout.
    var showsBrowseHeader: Bool {
        genreOptions.count > 1 || filterRootPath != nil
    }

    var browseHeader: some View {
        HStack(spacing: 0) {
            if genreOptions.count > 1 {
                GenreFilterChipBar(options: genreOptions, selection: $selectedGenre)
            }
            Spacer(minLength: 0)
            if filterRootPath != nil {
                FolderBrowserSortMenu(settings: settings)
                    .padding(.horizontal, tokens.spacing.small)
            }
        }
    }

    func playSelectionOrFirst() {
        if !selection.isEmpty { play(selection) }
        else if let first = derivedRows.first?.id { play([first]) }
    }

    @ViewBuilder
    var dropOverlay: some View {
        if isDropTargeted {
            ZStack {
                RoundedRectangle(cornerRadius: tokens.radii.medium)
                    .strokeBorder(tokens.colors.accent.resolve(scheme), lineWidth: 2)
                VStack(spacing: tokens.spacing.small) {
                    Image(systemName: "square.and.arrow.down.fill")
                        .font(.largeTitle)
                        .foregroundStyle(tokens.colors.accent.resolve(scheme))
                    Text(MacAMPStrings.dropImportHint)
                        .foregroundStyle(tokens.colors.accent.resolve(scheme))
                }
                .padding(tokens.spacing.large)
                .background(
                    RoundedRectangle(cornerRadius: tokens.radii.medium)
                        .fill(tokens.colors.accentMuted.resolve(scheme))
                )
            }
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }
}

/// A pending "New Playlist…" request carrying the tracks to add once the user
/// names the playlist (wraps a non-`Identifiable` `Set` for `.sheet(item:)`).
private struct NewPlaylistRequest: Identifiable {
    let id = UUID()
    let trackIds: Set<Int64>
}

#Preview {
    LibraryBrowserView()
        .environment(AppEnvironment.preview())
        .environment(AppSettings.preview)
        .environment(NavigationModel())
        .environment(PlayIntent())
        .designTokens(.standard)
        .frame(width: 720, height: 480)
}
