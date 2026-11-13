import DesignSystem
import SwiftUI
import ViewModels

// MARK: - Content

extension MainWindowView {
    @ViewBuilder
    var contentPane: some View {
        if isSearchActive {
            SearchResultsView()
        } else {
            destinationContent
        }
    }

    /// Routes the sidebar selection to its detail view.
    ///
    /// Deliberately an **exhaustive** `switch` with no `default:` case, so a new
    /// ``SidebarDestination`` case fails to compile here until it is routed —
    /// rather than silently falling through to the "feature pending" placeholder.
    @ViewBuilder
    var destinationContent: some View {
        let destination = nav.sidebar
        switch destination {
        case .folder:
            LibraryBrowserView(filterRootPath: folderPath(for: destination))
                .id(destination)
        case let .playlist(playlistId):
            playlistContent(playlistId, destination: destination)
        case let .fixed(section):
            fixedSectionContent(section, destination: destination)
        }
    }

    /// Detail for one specific playlist. A selection that no longer resolves to a
    /// loaded playlist falls back to the pending placeholder — the same outcome the
    /// previous if-else chain reached through its final `else`.
    @ViewBuilder
    func playlistContent(_ playlistId: Int64, destination: SidebarDestination) -> some View {
        if let item = environment.playlists.playlists.first(where: { $0.playlist.id == playlistId }) {
            PlaylistDetailView(playlist: item.playlist)
                .id(destination)
        } else {
            pendingContent(for: destination)
        }
    }

    /// Detail for a fixed sidebar section, split across two routers.
    ///
    /// All THREE switches below are exhaustive over ``LibrarySection`` with no
    /// `default:` case, so adding a case intentionally breaks this build until the
    /// new section is given a detail view. The split is forced, not stylistic: one
    /// arm per case put this past SwiftLint's `cyclomatic_complexity` ceiling of 10
    /// once the eleventh section landed. Each router names the cases it does NOT own
    /// explicitly rather than reaching for `default:`, which is what keeps the
    /// compile gate at every site instead of only at this one.
    @ViewBuilder
    func fixedSectionContent(_ section: LibrarySection, destination: SidebarDestination) -> some View {
        switch section {
        case .allTracks, .albums, .artists, .favourites, .lyrics, .playlists:
            libraryContent(section, destination: destination)
        case .stats, .queue, .karaoke, .karaokeQueue, .assistant, .downloads:
            featureContent(section, destination: destination)
        }
    }

    /// The library-browsing sections: everything backed by the track/album/artist
    /// graph or the playlist list.
    @ViewBuilder
    func libraryContent(_ section: LibrarySection, destination: SidebarDestination) -> some View {
        switch section {
        case .allTracks:
            LibraryBrowserView(filterRootPath: folderPath(for: destination))
                .id(destination)
        case .albums:
            AlbumsGridView()
        case .artists:
            ArtistsGridView()
        case .favourites:
            FavouritesView()
                .id(destination)
        case .lyrics:
            LyricsBrowserView()
                .id(destination)
        case .playlists:
            PlaylistsView()
        case .stats, .queue, .karaoke, .karaokeQueue, .assistant, .downloads:
            pendingContent(for: destination)
        }
    }

    /// The feature sections: each owns a purpose-built screen rather than a browser.
    @ViewBuilder
    func featureContent(_ section: LibrarySection, destination: SidebarDestination) -> some View {
        switch section {
        case .stats:
            StatsView()
        case .queue:
            QueueView()
                .id(destination)
        case .karaoke:
            KaraokeReadyListView()
                .id(destination)
        case .karaokeQueue:
            KaraokeQueueView()
                .id(destination)
        case .assistant:
            AssistantView()
                .id(destination)
        case .downloads:
            DownloadsView()
                .id(destination)
        case .allTracks, .albums, .artists, .favourites, .lyrics, .playlists:
            pendingContent(for: destination)
        }
    }

    /// Placeholder for a destination whose detail cannot be resolved right now.
    func pendingContent(for destination: SidebarDestination) -> some View {
        StateView(
            systemImage: destination.systemImage,
            title: MacAMPStrings.featurePendingTitle,
            message: MacAMPStrings.featurePendingMessage
        )
    }

    /// Resolves through the tree registry, so a `.folder` destination naming a nested
    /// folder browses that folder rather than falling back to its library root.
    func folderPath(for destination: SidebarDestination) -> String? {
        guard case let .folder(rootId) = destination else { return nil }
        return environment.libraryFolders.sidebar.path(forId: rootId)
    }
}
