// PlaylistsScreen — the iOS playlists browser + editor.
//
// Driven by the shared ``PlaylistViewModel`` (Task 9): listing is keyset-paginated
// (only the loaded window lives in memory), and create / rename / delete run on the
// view model's off-actor CRUD. Tapping a playlist pushes a ``PlaylistDetailView``
// (paginated tracks, play/enqueue, swipe-to-remove, drag-reorder). Deleting a
// playlist removes the list only — its tracks stay in the library.
//
// Auto Mixes (Task 26) is the iOS shell's ENTIRE local-AI surface: a READ-ONLY
// section listing the profile's generator-backed playlists. There is no assistant,
// no proposal preview and no edit affordance here — a mix materialises into an
// ordinary `playlist` row, so its rows are the ORDINARY rows (same
// ``row(_:)``, same `NavigationLink` into ``PlaylistDetailView``) and open, play
// and enqueue exactly like any other playlist.
//
// Four decisions worth stating:
//
//  * The section sits ABOVE the ordinary playlists. It is small (one row per
//    generator kind) and fixed, while the list below it is unbounded and
//    paginated, so putting it first keeps it reachable without scrolling.
//  * A mix is also an ordinary playlist, so it would otherwise appear TWICE. The
//    lower section subtracts ``AutoMixListViewModel/playlistIds`` from the loaded
//    window, and gains a header of its own only while the Auto Mixes section is
//    visible.
//  * Rows are matched out of the ALREADY-LOADED playlist window rather than
//    re-read, so the section costs no extra query and its track counts can never
//    disagree with the list below. A mix that sorts beyond the loaded pages
//    surfaces once pagination reaches it.
//  * The refresh runs on the SECTION's `.task` — once per appearance, never on a
//    timer and never per render. `refreshIfStale` is a no-op inside its TTL.
//
// Both toggles gate the section by CONSTRUCTION: with the master switch off the
// whole AI graph is `nil` (nothing is built to read the database), and the
// `autoMixes` bundle switch hides the section on top of that.
import DesignSystem
import Persistence
import SwiftUI
import ViewModels

/// The playlists browser screen.
struct PlaylistsScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(AppSettings.self) private var settings
    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    @State private var sheet: PlaylistSheet?
    @State private var exportRequest: PlaylistExportRequest?
    @State private var didLoad = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(Text(MacAMPStrings.playlistsTitle))
                .navigationDestination(for: PlaylistRecord.self) { PlaylistDetailView(playlist: $0) }
                .toolbar { toolbarContent }
                .task { await loadInitial() }
                .refreshable { try? await environment.playlists.loadInitialPlaylists() }
                .sheet(item: $sheet) { sheetContent($0) }
                .sheet(item: $exportRequest) { PlaylistExportSheet(request: $0) }
                .modifier(PlaylistImportActions())
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button { sheet = .create } label: {
                Label { Text(MacAMPStrings.playlistsNew) } icon: { Image(systemName: "plus") }
            }
            .accessibilityHint(Text(MacAMPStrings.a11yHintNewPlaylist))
        }
    }
}

// MARK: - Sheet routing

/// The two text-field flows the browser presents (one `.sheet(item:)` for both),
/// since ``PlaylistRecord`` is not `Identifiable`.
private enum PlaylistSheet: Identifiable {
    case create
    case rename(PlaylistRecord)

    var id: String {
        switch self {
        case .create: "create"
        case let .rename(playlist): "rename-\(playlist.id ?? 0)"
        }
    }
}

private extension PlaylistsScreen {
    @ViewBuilder
    func sheetContent(_ route: PlaylistSheet) -> some View {
        switch route {
        case .create:
            PlaylistNameSheet(title: MacAMPStrings.playlistsNew, confirmLabel: MacAMPStrings.playlistsCreate) {
                create(named: $0)
            }
        case let .rename(playlist):
            PlaylistNameSheet(
                title: MacAMPStrings.playlistsRename,
                confirmLabel: MacAMPStrings.playlistsSave,
                initialName: playlist.name
            ) { rename(playlist, to: $0) }
        }
    }
}

// MARK: - Content

private extension PlaylistsScreen {
    /// The Auto Mixes projection, or `nil` when either switch is off — `nil` is
    /// the whole gate: no model, no section, no `.task`, no refresh.
    var autoMixes: AutoMixListViewModel? {
        guard settings.intelligenceEnabled, settings.autoMixesEnabled else { return nil }
        return environment.intelligence?.autoMixList
    }

    @ViewBuilder
    var content: some View {
        if let autoMixes {
            // Rendered even with nothing loaded yet: the section's `.task` is what
            // materialises the mixes on a first launch, so it has to be mounted.
            sectionedList(autoMixes)
        } else if environment.playlists.playlists.isEmpty {
            if environment.playlists.isLoadingPlaylists {
                StateView.loading()
            } else {
                emptyState
            }
        } else {
            list
        }
    }

    var emptyState: some View {
        StateView(
            systemImage: "music.note.list",
            title: MacAMPStrings.playlistsEmptyTitle,
            message: MacAMPStrings.playlistsEmptyMessage,
            action: StateView.Action(title: MacAMPStrings.playlistsNew, systemImage: "plus") { sheet = .create }
        )
    }

    var list: some View {
        List {
            ForEach(environment.playlists.playlists, id: \.playlist.id) { item in
                playlistRow(item, lastOf: environment.playlists.playlists)
            }
        }
        .listStyle(.plain)
    }

    /// The Auto Mixes section over the ordinary playlists, each in its own group.
    func sectionedList(_ model: AutoMixListViewModel) -> some View {
        let mixRows = autoMixRows(model)
        let playlistRows = ordinaryRows(excluding: model.playlistIds)
        return List {
            Section {
                if mixRows.isEmpty, model.isLoading {
                    ProgressView { Text(MacAMPStrings.playlistsAutoMixesPreparing) }
                }
                ForEach(mixRows, id: \.playlist.id) { item in
                    NavigationLink(value: item.playlist) { row(item) }
                }
            } header: {
                Text(MacAMPStrings.playlistsAutoMixesHeader)
                    .accessibilityIdentifier("playlists.autoMixes.header")
            }
            .task { await refreshAutoMixes(model) }

            Section {
                if playlistRows.isEmpty {
                    Text(MacAMPStrings.playlistsEmptyMessage)
                        .font(tokens.typography.body.font)
                        .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
                }
                ForEach(playlistRows, id: \.playlist.id) { item in
                    playlistRow(item, lastOf: playlistRows)
                }
            } header: {
                Text(MacAMPStrings.playlistsTitle)
            }
        }
        .listStyle(.plain)
    }

    /// One editable playlist row. `lastOf` is the list it is rendered in, so the
    /// next page is requested when its final row appears.
    func playlistRow(_ item: PlaylistWithTrackCount, lastOf rows: [PlaylistWithTrackCount]) -> some View {
        NavigationLink(value: item.playlist) { row(item) }
            .onAppear { paginate(item, lastOf: rows) }
            .swipeActions(edge: .trailing) { rowActions(item.playlist) }
            .contextMenu { exportMenuItem(item.playlist) }
    }

    func row(_ item: PlaylistWithTrackCount) -> some View {
        HStack(spacing: tokens.spacing.medium) {
            Image(systemName: "music.note.list")
                .font(tokens.typography.headline.font)
                .foregroundStyle(tokens.colors.accent.resolve(scheme))
                .frame(width: 36)
                .accessibilityHidden(true)
            Text(verbatim: item.playlist.name)
                .font(tokens.typography.headline.font)
                .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
                .lineLimit(1)
            Spacer(minLength: tokens.spacing.small)
            Text(verbatim: "\(item.trackCount)")
                .font(tokens.typography.timecode.font)
                .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
        }
        .padding(.vertical, tokens.spacing.xSmall)
    }

    @ViewBuilder
    func rowActions(_ playlist: PlaylistRecord) -> some View {
        Button(role: .destructive) { delete(playlist) } label: {
            Label { Text(MacAMPStrings.playlistsDelete) } icon: { Image(systemName: "trash") }
        }
        Button { sheet = .rename(playlist) } label: {
            Label { Text(MacAMPStrings.playlistsRename) } icon: { Image(systemName: "pencil") }
        }
        .tint(tokens.colors.accent.resolve(scheme))
    }

    @ViewBuilder
    func exportMenuItem(_ playlist: PlaylistRecord) -> some View {
        if let playlistId = playlist.id {
            Button {
                exportRequest = PlaylistExportRequest(id: playlistId, name: playlist.name)
            } label: {
                Label { Text(MacAMPStrings.playlistExport) } icon: { Image(systemName: "square.and.arrow.up") }
            }
        }
    }
}

// MARK: - Data operations

private extension PlaylistsScreen {
    func loadInitial() async {
        guard !didLoad else { return }
        didLoad = true
        try? await environment.playlists.loadInitialPlaylists()
    }

    func paginate(_ item: PlaylistWithTrackCount, lastOf rows: [PlaylistWithTrackCount]) {
        guard item.playlist.id == rows.last?.playlist.id else { return }
        Task { try? await environment.playlists.loadMorePlaylists() }
    }

    /// The loaded playlists that back the listed mixes, in the service's order.
    func autoMixRows(_ model: AutoMixListViewModel) -> [PlaylistWithTrackCount] {
        guard !model.mixes.isEmpty else { return [] }
        let loaded = Dictionary(
            environment.playlists.playlists.map { ($0.playlist.id ?? 0, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return model.mixes.compactMap { loaded[$0.playlistId] }
    }

    /// The loaded playlists that are NOT auto-mixes, so no row is listed twice.
    func ordinaryRows(excluding mixIds: Set<Int64>) -> [PlaylistWithTrackCount] {
        guard !mixIds.isEmpty else { return environment.playlists.playlists }
        return environment.playlists.playlists.filter { !mixIds.contains($0.playlist.id ?? 0) }
    }

    /// Refreshes the stale mixes on section appearance, reloading the playlist
    /// page only when a refresh actually created or rewrote one.
    func refreshAutoMixes(_ model: AutoMixListViewModel) async {
        guard await model.load() else { return }
        try? await environment.playlists.loadInitialPlaylists()
    }

    func create(named name: String) {
        Task {
            try? await environment.playlists.createPlaylist(named: name)
            try? await environment.playlists.loadInitialPlaylists()
        }
    }

    func rename(_ playlist: PlaylistRecord, to name: String) {
        Task {
            try? await environment.playlists.renamePlaylist(playlist, to: name)
            try? await environment.playlists.loadInitialPlaylists()
        }
    }

    func delete(_ playlist: PlaylistRecord) {
        guard let playlistId = playlist.id else { return }
        Task {
            try? await environment.playlists.deletePlaylist(id: playlistId)
            try? await environment.playlists.loadInitialPlaylists()
        }
    }
}

#Preview {
    PlaylistsScreen()
        .environment(AppEnvironment.preview())
        .environment(AppSettings.preview)
        .designTokens(.standard)
}
