import DesignSystem
import Persistence
import SwiftUI
import ViewModels

struct SidebarView: View {
    var folders: [FolderSidebarNode] = []
    var onRemoveFolder: ((Int64) -> Void)?

    @Environment(AppEnvironment.self) private var environment
    @Environment(AppSettings.self) private var settings
    @Environment(NavigationModel.self) private var nav
    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    @State private var renameTarget: PlaylistRecord?
    @State private var renameText = ""
    @State private var deleteTarget: PlaylistRecord?

    private var sidebarSelectionBinding: Binding<SidebarDestination?> {
        Binding(
            get: { nav.sidebar },
            set: { if let newValue = $0 { nav.sidebar = newValue } }
        )
    }

    private func expansionBinding(_ section: SidebarSectionID) -> Binding<Bool> {
        Binding(
            get: { nav.isSectionExpanded(section) },
            set: { nav.sidebarSectionExpanded[section.rawValue] = $0 }
        )
    }

    /// `karaokeRender` is non-nil iff a separation model is bundled — the same
    /// authoritative gate `KaraokeBadge` uses (not the unwired availability seam).
    private var karaokeAvailable: Bool {
        settings.karaokeEnabled && environment.karaokeRender != nil
    }

    /// Gated on the SETTING alone, not on `environment.intelligence != nil`: the AI
    /// graph is rebuilt asynchronously off a `withObservationTracking` hop, so it
    /// trails the toggle by a runloop pass. The setting is the immediate,
    /// authoritative answer to "should this row exist", and it is the same value
    /// ``NavigationModel/reconcileAssistant(available:)`` is reconciled against —
    /// so the row and the selection can never disagree.
    private var assistantAvailable: Bool {
        settings.intelligenceEnabled
    }

    private var karaokeReadyCount: Int {
        environment.karaokeReadyBadge.resolvedCount
    }

    private var karaokeQueueCount: Int {
        let store = environment.karaokeQueueStore
        return (store.currentPath != nil ? 1 : 0) + store.pendingPaths.count
    }

    /// Reads through the `@ObservationIgnored` model to the `@Observable` store, so the
    /// badge tracks membership without the model reference itself being observed. `nil`
    /// (no badge) before the composition root has built the queue.
    private var downloadsQueueCount: Int? {
        environment.downloadsModel.map(\.count)
    }

    private var activeProfileId: Int64 {
        environment.profileService.activeProfile.id ?? ProfileRecord.guestID
    }

    private var karaokeReadyBadgeLoadKey: KaraokeReadyBadgeLoadKey {
        KaraokeReadyBadgeLoadKey(
            readyVersion: environment.karaokeReadyStore.version,
            libraryRevision: environment.libraryFolders.revision,
            profileId: activeProfileId
        )
    }

    var body: some View {
        List(selection: sidebarSelectionBinding) {
            Section(isExpanded: expansionBinding(.library)) {
                ForEach(LibrarySection.libraryRowList) {
                    row($0, badge: libraryRowBadge(for: $0))
                }
            } header: {
                sectionHeader(MacAMPStrings.sidebarLibrarySection, id: .library)
            }
            if karaokeAvailable {
                Section(isExpanded: expansionBinding(.karaoke)) {
                    row(.karaoke, badge: karaokeReadyCount)
                    row(.karaokeQueue, badge: karaokeQueueCount)
                } header: {
                    sectionHeader(MacAMPStrings.sidebarKaraokeSection, id: .karaoke)
                }
            }
            if assistantAvailable {
                Section(isExpanded: expansionBinding(.intelligence)) {
                    row(.assistant)
                } header: {
                    sectionHeader(AssistantPaneStrings.sidebarSection, id: .intelligence)
                }
            }
            Section(isExpanded: expansionBinding(.playlists)) {
                row(.playlists)
                ForEach(environment.playlists.playlists, id: \.playlist.id) { item in
                    playlistRow(item.playlist)
                }
                .onMove { from, destination in
                    environment.playlists.movePlaylists(from: from, to: destination)
                }
            } header: {
                sectionHeader(MacAMPStrings.sidebarPlaylistsSection, id: .playlists)
            }
            if !folders.isEmpty {
                Section(isExpanded: expansionBinding(.folders)) {
                    SidebarFolderTreeSection(
                        roots: folders,
                        model: environment.libraryFolders.sidebar,
                        onRemoveFolder: onRemoveFolder
                    )
                } header: {
                    foldersSectionHeader
                }
            }
        }
        .listStyle(.sidebar)
        .accessibilityIdentifier("sidebar.list")
        .scrollContentBackground(.hidden)
        .background(tokens.colors.surface.resolve(scheme).opacity(0.25))
        // Bottom-pinned so it cannot overlap the folder filter field or a section
        // header; the model's zero-work guard is the only visibility guard.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SidebarImportProgressBar(progress: environment.libraryFolders.importProgress)
        }
        // On the LIST, not inside the section: a collapsed Folders section renders no
        // content, so a selection change would otherwise go unrecorded.
        .onChange(of: nav.sidebar) { _, destination in
            environment.libraryFolders.sidebar.noteFolderSelection(destination)
        }
        .onChange(of: environment.libraryFolders.revision) { _, _ in
            if case let .folder(id) = nav.sidebar, environment.libraryFolders.sidebar.path(forId: id) == nil {
                nav.sidebar = .fixed(.allTracks)
            }
        }
        .task {
            nav.reconcileKaraoke(available: karaokeAvailable)
            nav.reconcileAssistant(available: assistantAvailable)
            if environment.playlists.playlists.isEmpty {
                try? await environment.playlists.loadInitialPlaylists()
            }
        }
        .task(id: karaokeReadyBadgeLoadKey) {
            await environment.karaokeReadyBadge.recompute(profileId: activeProfileId)
        }
        .onChange(of: settings.karaokeEnabled) { _, _ in
            nav.reconcileKaraoke(available: karaokeAvailable)
        }
        .onChange(of: settings.intelligenceEnabled) { _, _ in
            nav.reconcileAssistant(available: assistantAvailable)
        }
        .alert(
            Text(MacAMPStrings.sidebarRenamePlaylist),
            isPresented: Binding(
                get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } }
            )
        ) {
            TextField(text: $renameText) { EmptyView() }
            Button(String(localized: MacAMPStrings.playlistCancel)) { renameTarget = nil }
            Button(String(localized: MacAMPStrings.playlistImportDone)) {
                guard let target = renameTarget, target.id != nil else { return }
                Task { try? await environment.playlists.renamePlaylist(target, to: renameText) }
                renameTarget = nil
            }
        }
        .alert(
            Text(MacAMPStrings.sidebarDeletePlaylist),
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            )
        ) {
            Button(String(localized: MacAMPStrings.sidebarDeletePlaylist), role: .destructive) {
                guard let target = deleteTarget, let targetId = target.id else { return }
                let name = target.name
                Task {
                    _ = try? await environment.playlists.deletePlaylist(id: targetId)
                    try? await environment.playlists.loadInitialPlaylists()
                    environment.toast.show(
                        text: String(localized: MacAMPStrings.playlistDeletedToast) + " \"\(name)\""
                    )
                }
                if nav.sidebar == .playlist(id: targetId) { nav.sidebar = .fixed(.allTracks) }
                deleteTarget = nil
            }
        } message: {
            if let target = deleteTarget {
                Text(verbatim: "\"\(target.name)\"")
            }
        }
    }

    /// Downloads is the only Library row that carries a badge. `nil` adds no
    /// modifier at all (see ``optionalBadge(_:)``), so routing all eight rows
    /// through here leaves the other seven byte-identical to un-badged rows.
    private func libraryRowBadge(for section: LibrarySection) -> Int? {
        section == .downloads ? downloadsQueueCount : nil
    }

    private func sectionHeader(_ title: LocalizedStringResource, id: SidebarSectionID) -> some View {
        Text(title)
            .accessibilityIdentifier("sidebar.section.\(id.rawValue)")
    }

    private var foldersSectionHeader: some View {
        HStack(spacing: 0) {
            sectionHeader(FolderSidebarStrings.section, id: .folders)
            Spacer(minLength: 0)
            SidebarFolderSortMenu(settings: settings)
        }
    }

    private func row(_ section: LibrarySection, badge: Int? = nil) -> some View {
        Label {
            Text(section.label)
        } icon: {
            Image(systemName: section.systemImage)
        }
        .optionalBadge(badge)
        .tag(SidebarDestination.fixed(section))
        .accessibilityIdentifier("sidebar.row.\(section.rawValue)")
    }

    private func playlistRow(_ playlist: PlaylistRecord) -> some View {
        Label {
            Text(verbatim: playlist.name)
                .lineLimit(1)
        } icon: {
            Image(systemName: "music.note.list")
        }
        .tag(playlist.id.map { SidebarDestination.playlist(id: $0) } ?? SidebarDestination.fixed(.playlists))
        .contextMenu {
            Button(MacAMPStrings.sidebarRenamePlaylist) {
                renameText = playlist.name
                renameTarget = playlist
            }
            PlaylistOrganizeMenu(playlist: playlist, trackSource: .repositoryPages)
            Divider()
            Button(MacAMPStrings.sidebarDeletePlaylist, role: .destructive) {
                deleteTarget = playlist
            }
        }
    }
}

// MARK: - Library row classification

private extension LibrarySection {
    /// Exhaustive, no `default:` — a new ``LibrarySection`` case must be classified
    /// here (shown in the Library row list, or claimed by one of the dedicated
    /// sections below it) before the shell compiles.
    var appearsInLibraryRowList: Bool {
        switch self {
        case .allTracks, .albums, .artists, .favourites, .lyrics, .stats, .queue, .downloads:
            true
        case .playlists, .karaoke, .karaokeQueue, .assistant:
            // Rendered by their own dedicated sidebar sections, not this row list.
            false
        }
    }

    /// Display order is explicit (not `allCases`) so an enum declaration change can
    /// never silently reorder the sidebar; the filter keeps membership owned solely
    /// by ``appearsInLibraryRowList``.
    static var libraryRowList: [LibrarySection] {
        [.allTracks, .albums, .artists, .favourites, .lyrics, .stats, .queue, .downloads]
            .filter(\.appearsInLibraryRowList)
    }
}

struct KaraokeReadyBadgeLoadKey: Equatable {
    let readyVersion: Int
    let libraryRevision: Int
    let profileId: Int64
}

private extension View {
    /// Applies `.badge(count)` only when `count` is non-nil, and MUST be chained
    /// before `.tag()` on a `List(selection:)` row: a `.badge()` applied AFTER `.tag()`
    /// hides the tag from the List's selection resolution, so clicking the row never
    /// commits the selection. Passing `nil` adds no modifier at all, leaving untagged
    /// or non-counted rows byte-identical to an un-badged row.
    @ViewBuilder
    func optionalBadge(_ count: Int?) -> some View {
        if let count {
            badge(count)
        } else {
            self
        }
    }
}

#Preview {
    SidebarView(
        folders: [
            FolderSidebarNode(rootId: 1, path: "/Music/Library", name: "Library", isMissing: false),
            FolderSidebarNode(rootId: 2, path: "/Volumes/Archive", name: "Archive", isMissing: true),
        ]
    )
    .environment(AppEnvironment.preview())
    .environment(AppSettings.preview)
    .environment(NavigationModel())
    .designTokens(.standard)
    .frame(width: 220, height: 420)
}
