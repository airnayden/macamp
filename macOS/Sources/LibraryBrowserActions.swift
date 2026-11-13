// LibraryBrowserActions — the data loading, drag-import, and playback / playlist /
// favourite mutations behind ``LibraryBrowserView``.
//
// Split out of the view file purely to keep each source under the SwiftLint
// file-length and type-body-length limits; the members are internal (not private)
// because the view's body/menu/table in the sibling file invoke them. Every
// database touch routes through the shared view models / repositories.
import DesignSystem
import Persistence
import Services
import SwiftUI
import ViewModels

/// Composite `.task(id:)` key for ``LibraryBrowserView``'s initial load: pairs the
/// selected library-root filter with the active profile id, so a profile switch
/// re-fires the load even when `filterRootPath` is unchanged (the "All Tracks" case).
struct LibraryBrowserLoadKey: Hashable {
    let filterRootPath: String?
    let profileId: Int64
}

// MARK: - Loading + derived state

extension LibraryBrowserView {
    var activeProfileId: Int64 {
        environment.profileService.activeProfile.id ?? ProfileRecord.guestID
    }

    var playbackSource: PlaybackSource {
        if let filterRootPath {
            return .folder(path: filterRootPath)
        }
        return .librarySection(LibrarySection.allTracks.rawValue)
    }

    var loadKey: LibraryBrowserLoadKey {
        LibraryBrowserLoadKey(filterRootPath: filterRootPath, profileId: activeProfileId)
    }

    func handleDrop(_ urls: [URL]) -> Bool {
        let importer = DropImporter(scanner: environment.scanner)
        let access = environment.libraryAccess
        let plan = importer.plan(for: urls, existingRoots: access.roots.map(\.url))
        guard !plan.isEmpty else { return false }
        Task { await environment.libraryFolders.importDrop(plan) }
        return true
    }

    var addFolderAction: StateView.Action {
        StateView.Action(title: FileAccessStrings.addFolder, systemImage: "plus") {
            Task { await environment.libraryAccess.requestAccess() }
        }
    }

    var navigationTitle: Text {
        if let filterRootPath {
            Text(verbatim: (filterRootPath as NSString).lastPathComponent)
        } else {
            Text(MacAMPStrings.libraryTitle)
        }
    }

    func syncSourceTracks() {
        let raw: [TrackRecord] = if filterRootPath != nil {
            folderModel?.tracks ?? []
        } else if let genreModel {
            genreModel.tracks
        } else {
            environment.library.tracks
        }
        sourceTracks = applyingGenreFilter(raw)
        rebuildDerivedRows()
    }

    var isLoadingTracks: Bool {
        if filterRootPath != nil {
            folderModel?.isLoading ?? false
        } else if let genreModel {
            genreModel.isLoading
        } else {
            environment.library.isLoadingTracks
        }
    }

    var rows: [LibraryTrackRow] {
        displayedTracks.map { LibraryTrackRow(track: $0) }
    }

    var sortedRows: [LibraryTrackRow] {
        guard FolderReorderPolicy.appliesTableSort(filterRootPath: filterRootPath) else { return rows }
        return rows.sorted(using: sortOrder)
    }

    var canReorderFolder: Bool {
        FolderReorderPolicy.allowsReorder(filterRootPath: filterRootPath, isGenreFilterAll: selectedGenre.isAll)
    }

    /// ``canReorderFolder`` narrowed by the browser's own Sort menu.
    ///
    /// Separate from that property rather than replacing it: ``canReorderFolder``
    /// also answers for surfaces with no sort control, where manual order is the
    /// only order there is. Under Name or Date added the row order is the QUERY's,
    /// so a drag would persist positions the next page load discards — the gate
    /// must close before the drag, not after.
    var canReorderOutline: Bool {
        FolderReorderPolicy.allowsReorder(
            filterRootPath: filterRootPath,
            isGenreFilterAll: selectedGenre.isAll,
            filesSort: settings.folderSort.browser
        )
    }

    func load() async {
        // Drop any optimistic favourite toggles from the previous load/profile so
        // rows fall back to the freshly fetched `favouriteIds` (DB truth).
        favouriteOverrides.removeAll()
        configureLocalSearch()
        await loadGenreOptions()
        await loadFavourites()
        await reloadTracks()
    }

    func loadFavourites() async {
        let repository = TrackRepository(environment.database)
        let profileId = activeProfileId
        favouriteIds = await (try? Task.detached { try repository.favouriteTrackIDs(profileId: profileId) }.value) ?? []
    }

    func loadGenreOptions() async {
        let repository = TrackRepository(environment.database)
        let loaded: LibraryGenreFacets? = if let filterRootPath {
            try? await repository.distinctGenres(rootPath: filterRootPath)
        } else {
            try? await repository.distinctGenres(profileId: activeProfileId)
        }
        let facets = loaded ?? LibraryGenreFacets(genres: [], includesUntagged: false)
        genreOptions = GenreFilter.options(from: facets)
        if !genreOptions.contains(selectedGenre) {
            selectedGenre = .all
        }
    }

    /// Rebuilds the active track window, then tops it up to a viewport-filling
    /// row count (bounded — see ``fillViewportIfNeeded()``) so a tall window does
    /// not paint one page and stall.
    func reloadTracks() async {
        if let filterRootPath {
            genreModel = nil
            let model = FolderBrowserViewModel(
                repository: TrackRepository(environment.database),
                rootPath: filterRootPath,
                activeProfileId: activeProfileId
            )
            folderModel = model
            try? await model.loadInitial()
        } else {
            folderModel = nil
            if selectedGenre.isAll {
                genreModel = nil
                try? await environment.library.loadInitialTracks()
            } else {
                let model = GenreBrowserViewModel(
                    repository: TrackRepository(environment.database),
                    genre: selectedGenre.queryArgument,
                    activeProfileId: activeProfileId
                )
                genreModel = model
                try? await model.loadInitial()
            }
        }
        syncSourceTracks()
        await fillViewportIfNeeded()
    }

    func moveFolderTracks(from source: IndexSet, to destination: Int) {
        guard let folderModel,
              let reordered = folderModel.moveTracks(from: source, to: destination, isEnabled: canReorderFolder)
        else { return }
        syncSourceTracks()
        environment.coordinator.reorderQueue(reordered.map { TrackRef(record: $0) })
        environment.queue.refresh()
    }
}

// MARK: - Selection helpers + playback / playlist / favourite actions

extension LibraryBrowserView {
    @ViewBuilder
    func availabilityBadge(_ row: LibraryTrackRow) -> some View {
        switch environment.library.badge(for: row.track) {
        case .available:
            EmptyView()
        case .missing:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(tokens.colors.warning.resolve(scheme))
                .accessibilityLabel(Text(MacAMPStrings.badgeMissing))
        case .offline:
            Image(systemName: "externaldrive.badge.xmark")
                .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
                .accessibilityLabel(Text(MacAMPStrings.badgeOffline))
        }
    }

    func refs(for ids: Set<Int64>) -> [TrackRef] {
        derivedRows
            .filter { ids.contains($0.id) }
            .map { TrackRef(record: $0.track) }
    }

    func records(for ids: Set<Int64>) -> [TrackRecord] {
        derivedRows
            .filter { ids.contains($0.id) }
            .map(\.track)
    }

    /// The shared row-action bodies. This screen resolves ids against its own
    /// rendered order and hands the result over; the helper never sees a `Set`.
    var rowActions: TrackRowActions {
        TrackRowActions(environment: environment)
    }

    func editTagsLabel(for ids: Set<Int64>) -> Text {
        ids.count > 1 ? Text(MacAMPStrings.tagsMenuMulti(ids.count)) : Text(MacAMPStrings.tagsMenuSingle)
    }

    func editTags(_ ids: Set<Int64>) {
        guard let request = TrackRowActions.tagEditRequest(for: records(for: ids)) else { return }
        tagEditRequest = request
    }

    func play(_ ids: Set<Int64>) {
        rowActions.play(
            displayedTracks.map { TrackRef(record: $0) },
            startingAt: ids.first,
            source: playbackSource
        )
    }

    func enqueue(_ ids: Set<Int64>) {
        rowActions.enqueue(refs(for: ids))
    }

    func playNext(_ ids: Set<Int64>) {
        rowActions.playNext(refs(for: ids))
    }

    func addTracks(_ ids: Set<Int64>, toPlaylist playlist: PlaylistRecord) {
        rowActions.addTracks(ids, toPlaylist: playlist)
    }

    func createPlaylistAndAdd(named name: String, trackIds: Set<Int64>) {
        Task {
            guard let playlist = try? await environment.playlists.createPlaylist(named: name),
                  let playlistId = playlist.id
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

    /// Whether the track menu offers "More Like This".
    ///
    /// The bundle is `.nlCreation`, not `.organization`: the action produces a NEW
    /// playlist through the very code path a typed request takes — the same
    /// ``AssistantViewModel``, the same ``MixGeneratorService``, the same
    /// `createPlaylist` proposal — and that view model's availability probe is
    /// already composed against `.nlCreation`. Gating the menu on `.organization`
    /// while its view model answers to `.nlCreation` would be two switches for one
    /// feature. `.organization` covers rewriting a list the listener already has,
    /// which is what the playlist "Organize…" menu does.
    ///
    /// ABSENT rather than disabled when the bundle is off.
    var showsMoreLikeThis: Bool {
        environment.intelligence != nil && settings.isEnabled(.nlCreation)
    }

    /// The track a similarity mix would be seeded from: the first of `ids` in the
    /// order the listener sees.
    ///
    /// Display order rather than `ids.first` — a `Set` iterates nondeterministically,
    /// so seeding from it would build a different mix each time the same rows were
    /// right-clicked.
    func seedTrack(for ids: Set<Int64>) -> TrackRecord? {
        derivedRows.first { ids.contains($0.id) }?.track
    }

    /// The menu item's label, naming the seed whenever there is one to name.
    ///
    /// Falls back to the unqualified wording only when the seed has no title — a row
    /// showing a bare file name would otherwise put a path fragment in a menu.
    static func moreLikeThisLabel(for seed: TrackRecord?) -> LocalizedStringResource {
        guard let title = seed?.title, !title.isEmpty else { return AIActionStrings.moreLikeThis }
        return AIActionStrings.moreLikeThisNamed(track: title)
    }

    @ViewBuilder
    func moreLikeThisMenuItem(_ ids: Set<Int64>) -> some View {
        if showsMoreLikeThis {
            let seed = seedTrack(for: ids)
            let isSeedable = seed?.availability == .present
            Button { moreLikeThis(ids) } label: {
                Label {
                    Text(Self.moreLikeThisLabel(for: seed))
                } icon: {
                    Image(systemName: "wand.and.stars")
                }
            }
            .disabled(!isSeedable)
            .help(isSeedable ? AIActionStrings.moreLikeThisHelp : AIActionStrings.moreLikeThisUnavailable)
            .accessibilityIdentifier("track.action.moreLikeThis")
        }
    }

    /// Proposes a playlist built around the selected track, then hands it to the
    /// window's review sheet.
    ///
    /// A `missing` or `externalOffline` seed is refused HERE as well as in the menu:
    /// the item is greyed out rather than hidden so the listener sees WHY, and the
    /// guard means a keyboard route to the same action cannot get past it. Writes
    /// nothing — the proposal is reviewed before anything is saved.
    func moreLikeThis(_ ids: Set<Int64>) {
        guard let assistant = environment.intelligence?.assistant,
              let seed = seedTrack(for: ids),
              let trackId = seed.id,
              seed.availability == .present
        else { return }
        let title = seed.title ?? (seed.filePath as NSString).lastPathComponent
        let profileId = activeProfileId
        Task { @MainActor in
            let proposal = await assistant.proposeMix(
                from: .similaritySeed(trackId: trackId),
                named: String(localized: AIActionStrings.moreLikeName(track: title)),
                profileId: profileId
            )
            guard let proposal else {
                environment.toast.show(text: String(localized: AIActionStrings.nothingToPropose))
                return
            }
            nav.pendingProposal = proposal
        }
    }

    func isCurrent(_ track: TrackRecord) -> Bool {
        guard let trackId = track.id else { return false }
        return trackId == environment.player.currentTrack?.trackID
    }

    func isFavourite(_ track: TrackRecord) -> Bool {
        guard let trackId = track.id else { return false }
        return favouriteOverrides[trackId] ?? favouriteIds.contains(trackId)
    }

    func toggleFavourite(_ track: TrackRecord) {
        guard let trackId = track.id else { return }
        let wasF = isFavourite(track)
        favouriteOverrides[trackId] = !wasF
        rowActions.toggleFavourite(track, wasFavourite: wasF)
    }
}
