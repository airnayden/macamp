// MainWindowToolbar — the content-area toolbar (sidebar toggle, destination
// title, add-folder / playlist import-export actions, right-panel toggle) behind
// ``MainWindowView``. Split out (like MainWindowActions) to keep the view file
// under the SwiftLint length budget; the members are internal (not private)
// because the view's `detailColumn` invokes `contentToolbarBar`.
import DesignSystem
import Persistence
import Services
import SwiftUI
import ViewModels

extension MainWindowView {
    var contentToolbarBar: some View {
        let destination = nav.sidebar
        return HStack(spacing: tokens.spacing.small) {
            MacAMPToolbarButton(icon: "sidebar.leading", help: MacAMPStrings.helpToggleSidebar) {
                paneTransitionCount += 1
                withAnimation(.easeOut(duration: 0.15)) {
                    nav.sidebarVisibility = nav.sidebarVisibility == .all ? .detailOnly : .all
                } completion: {
                    paneTransitionCount -= 1
                }
            }

            Spacer()

            Text(verbatim: destinationTitle(destination))
                .font(tokens.typography.headline.font)
                .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
                .lineLimit(1)

            Spacer()

            if destination.showsLibraryBrowser {
                if showsSurpriseMe {
                    MacAMPToolbarButton(icon: "shuffle.circle", help: AIActionStrings.surpriseMeHelp) {
                        surpriseMe()
                    }
                    .accessibilityIdentifier("library.action.surpriseMe")
                }
                MacAMPToolbarButton(icon: "plus", help: MacAMPStrings.helpAddFolder) {
                    Task { await environment.libraryAccess.requestAccess() }
                }
            }

            if destination == .fixed(.playlists) {
                MacAMPToolbarButton(icon: "square.and.arrow.down", help: MacAMPStrings.helpImportPlaylist) {
                    showImportPlaylist = true
                }
                MacAMPToolbarButton(icon: "plus", help: MacAMPStrings.helpNewPlaylist) {
                    newItemName = ""
                    showNewPlaylistSheet = true
                }
            }

            if destination == .fixed(.downloads) {
                MacAMPToolbarButton(icon: "plus", help: MacAMPStrings.downloadsPasteOpenHelp) {
                    nav.showDownloadsPasteSheet = true
                }
                .accessibilityIdentifier("downloads.addButton")
            }

            if case let .playlist(playlistId) = destination {
                if let record = playlistRecord(playlistId) {
                    PlaylistOrganizeMenu(playlist: record, trackSource: .loadedDetail)
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .labelStyle(.iconOnly)
                        .fixedSize()
                        .tint(tokens.colors.accent.resolve(scheme))
                        .help(AIActionStrings.organize)
                        .pointingHandCursor()
                }
                MacAMPToolbarButton(icon: "square.and.arrow.up", help: MacAMPStrings.helpExportPlaylist) {
                    exportPlaylistId = playlistId
                }
            }

            MacAMPToolbarButton(icon: "sidebar.trailing", help: MacAMPStrings.helpRightPanel) {
                paneTransitionCount += 1
                withAnimation(.easeOut(duration: 0.15)) {
                    nav.showRightPanel.toggle()
                } completion: {
                    paneTransitionCount -= 1
                }
            }
        }
        .padding(.horizontal, tokens.spacing.medium)
        .frame(height: MainWindowMetrics.topBarHeight)
    }

    /// The record behind a `.playlist` destination, from the sidebar's already-loaded
    /// page. `nil` while that page is still in flight, which is also exactly when the
    /// detail view has no membership to organize.
    func playlistRecord(_ playlistId: Int64) -> PlaylistRecord? {
        environment.playlists.playlists.first { $0.playlist.id == playlistId }?.playlist
    }

    func destinationTitle(_ destination: SidebarDestination) -> String {
        if isSearchActive {
            return String(localized: MacAMPStrings.searchResultsTitle)
        }
        switch destination {
        case let .fixed(section):
            return String(localized: section.label)
        case let .folder(rootId):
            if let path = environment.libraryFolders.sidebar.path(forId: rootId) {
                return URL(fileURLWithPath: path).lastPathComponent
            }
            return String(localized: MacAMPStrings.sidebarAllTracks)
        case let .playlist(playlistId):
            return environment.playlists.playlists
                .first(where: { $0.playlist.id == playlistId })?.playlist.name ?? ""
        }
    }
}
