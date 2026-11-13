// PlaylistsView — the macOS playlists pane.
//
// A keyset-paginated browser (via the shared ``PlaylistViewModel``) wrapped in a
// `NavigationStack`: a row pushes a ``PlaylistDetailView``; the toolbar creates a
// playlist and imports a file; a row's context menu renames, deletes (membership
// only — the tracks stay in the library), and exports. All file IO runs off the
// main actor in ``PlaylistImportExportViewModel``; entries that don't resolve to a
// library track are surfaced in a sheet, never silently dropped.
import DesignSystem
import Persistence
import SwiftUI
import ViewModels

struct PlaylistsView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    @State private var sheet: PlaylistSheet?
    @State private var exportRequest: ExportRequest?
    @State private var showUnresolved = false
    @State private var importFailed = false
    @State private var selectedPlaylist: PlaylistRecord?

    var body: some View {
        Group {
            if let selectedPlaylist {
                PlaylistDetailView(playlist: selectedPlaylist, onBack: { self.selectedPlaylist = nil })
            } else {
                content
            }
        }
        .accessibilityIdentifier("playlists.view")
        .sheet(item: $sheet, content: sheetContent)
        .sheet(item: $exportRequest, content: exportSheet)
        .sheet(isPresented: $showUnresolved, content: unresolvedSheet)
        .alert(Text(MacAMPStrings.playlistImportFailedTitle), isPresented: $importFailed) {
            Button(role: .cancel) {} label: { Text(MacAMPStrings.playlistImportDone) }
        } message: {
            Text(MacAMPStrings.playlistImportFailed)
        }
        .task {
            if model.playlists.isEmpty {
                try? await model.loadInitialPlaylists()
            }
        }
    }
}

// MARK: - Sheet routing

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

// MARK: - Content

private extension PlaylistsView {
    struct ExportRequest: Identifiable {
        let id: Int64
        let name: String
    }

    var model: PlaylistViewModel {
        environment.playlists
    }

    @ViewBuilder
    var content: some View {
        if model.playlists.isEmpty {
            if model.isLoadingPlaylists {
                StateView.loading()
            } else {
                StateView(
                    systemImage: "music.note.list",
                    title: MacAMPStrings.playlistsEmptyTitle,
                    message: MacAMPStrings.playlistsEmptyMessage,
                    action: StateView.Action(title: MacAMPStrings.playlistsNew, systemImage: "plus") {
                        sheet = .create
                    }
                )
            }
        } else {
            List {
                ForEach(model.playlists, id: \.playlist.id) { item in
                    Button { selectedPlaylist = item.playlist } label: { row(item) }
                        .buttonStyle(.plain)
                        .pointingHandCursor()
                        .onAppear { paginate(item) }
                        .contextMenu { rowMenu(item.playlist) }
                }
            }
            .scrollContentBackground(.hidden)
            .background(tokens.colors.canvas.resolve(scheme).opacity(0.25))
        }
    }

    @ToolbarContentBuilder
    var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button { sheet = .create } label: {
                Label { Text(MacAMPStrings.playlistsNew) } icon: { Image(systemName: "plus") }
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button(action: startImport) {
                Label {
                    Text(MacAMPStrings.playlistImport)
                } icon: {
                    Image(systemName: "square.and.arrow.down")
                }
            }
        }
    }

    func row(_ item: PlaylistWithTrackCount) -> some View {
        HStack(spacing: tokens.spacing.medium) {
            Image(systemName: "music.note.list")
                .foregroundStyle(tokens.colors.accent.resolve(scheme))
                .accessibilityHidden(true)
            Text(verbatim: item.playlist.name)
                .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
                .lineLimit(1)
            Spacer(minLength: tokens.spacing.small)
            Text(verbatim: "\(item.trackCount)")
                .font(tokens.typography.timecode.font)
                .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
        }
        .padding(.vertical, tokens.spacing.xxSmall)
    }
}

// MARK: - Row context menu + sheets

private extension PlaylistsView {
    @ViewBuilder
    func rowMenu(_ playlist: PlaylistRecord) -> some View {
        Button { sheet = .rename(playlist) } label: {
            Label { Text(MacAMPStrings.playlistsRename) } icon: { Image(systemName: "pencil") }
        }
        exportMenuItem(playlist)
        Divider()
        Button(role: .destructive) { delete(playlist) } label: {
            Label { Text(MacAMPStrings.playlistsDelete) } icon: { Image(systemName: "trash") }
        }
    }

    @ViewBuilder
    func exportMenuItem(_ playlist: PlaylistRecord) -> some View {
        if let identifier = playlist.id {
            Button {
                exportRequest = ExportRequest(id: identifier, name: playlist.name)
            } label: {
                Label {
                    Text(MacAMPStrings.playlistExport)
                } icon: {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
    }

    @ViewBuilder
    func sheetContent(_ route: PlaylistSheet) -> some View {
        switch route {
        case .create:
            PlaylistNameSheet(title: MacAMPStrings.playlistsNew, confirmLabel: MacAMPStrings.playlistsCreate) {
                create(named: $0)
            }
            .designTokens(tokens)
        case let .rename(playlist):
            PlaylistNameSheet(
                title: MacAMPStrings.playlistsRename,
                confirmLabel: MacAMPStrings.playlistsSave,
                initialName: playlist.name
            ) { rename(playlist, to: $0) }
                .designTokens(tokens)
        }
    }

    func exportSheet(_ request: ExportRequest) -> some View {
        PlaylistExportSheet(playlistId: request.id, playlistName: request.name)
            .environment(environment)
            .designTokens(tokens)
    }

    func unresolvedSheet() -> some View {
        PlaylistUnresolvedSheet(entries: environment.playlistImportExport.unresolved) {
            environment.playlistImportExport.clearUnresolved()
        }
        .designTokens(tokens)
    }
}

// MARK: - Data operations

private extension PlaylistsView {
    func startImport() {
        guard let url = PlaylistFilePanels.chooseImportFile() else { return }
        Task {
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            do {
                _ = try await environment.playlistImportExport.importPlaylist(
                    from: url,
                    profileId: environment.profileService.activeProfile.id ?? ProfileRecord.guestID
                )
                await reload()
                showUnresolved = !environment.playlistImportExport.unresolved.isEmpty
            } catch {
                importFailed = true
            }
        }
    }

    func create(named name: String) {
        Task {
            try? await model.createPlaylist(named: name)
            try? await model.loadInitialPlaylists()
        }
    }

    func rename(_ playlist: PlaylistRecord, to name: String) {
        Task {
            try? await model.renamePlaylist(playlist, to: name)
            try? await model.loadInitialPlaylists()
        }
    }

    func delete(_ playlist: PlaylistRecord) {
        guard let playlistId = playlist.id else { return }
        Task {
            try? await model.deletePlaylist(id: playlistId)
            try? await model.loadInitialPlaylists()
        }
    }

    func reload() async {
        try? await model.loadInitialPlaylists()
    }

    func paginate(_ item: PlaylistWithTrackCount) {
        guard item.playlist.id == model.playlists.last?.playlist.id else { return }
        Task { try? await model.loadMorePlaylists() }
    }
}

#Preview {
    PlaylistsView()
        .environment(AppEnvironment.preview())
        .designTokens(.standard)
}
