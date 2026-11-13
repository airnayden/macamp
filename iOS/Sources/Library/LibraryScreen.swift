// LibraryScreen — the iOS library browser, bound to `LibraryViewModel`.
//
// A bespoke segmented scope (Songs / Albums / Artists, see ``LibraryScopePicker``)
// over keyset-paginated queries: only the loaded window lives in memory, and the
// last row's `onAppear` pulls the next page (never the whole 100k-row table). A
// `.searchable` field drives the shared `SearchViewModel`; while a query is present
// the inline results replace the browser. Tapping a song plays the queue from that
// row. The whole browser floats on the token `canvas` for the streaming-player look.
import DesignSystem
import Persistence
import SwiftUI
import ViewModels

/// The library browser screen.
struct LibraryScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    @State private var scope: LibraryScope = .songs
    @State private var searchText = ""
    @State private var selectedGenre: GenreFilter = .all
    @State private var genreOptions: [GenreFilter] = [.all]
    @State private var genreModel: GenreBrowserViewModel?

    var body: some View {
        NavigationStack {
            Group {
                if searchText.isEmpty {
                    browser
                } else {
                    searchResults
                }
            }
            .navigationTitle(Text(MacAMPStrings.libraryTitle))
            .navigationDestination(for: AlbumRecord.self) { AlbumDetailView(album: $0) }
            .navigationDestination(for: ArtistRecord.self) { ArtistDetailView(artist: $0) }
            .searchable(text: $searchText, prompt: Text(MacAMPStrings.librarySearchPrompt))
            .onChange(of: searchText) { _, value in environment.search.search(value) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { ImportButton() }
            }
            .task(id: scope.id) { await loadInitial() }
            .onChange(of: selectedGenre) { _, _ in
                Task { await reloadSongs() }
            }
        }
    }
}

// MARK: - Browser

private extension LibraryScreen {
    var browser: some View {
        VStack(spacing: 0) {
            LibraryScopePicker(selection: $scope)
                .padding(.horizontal, tokens.spacing.large)
                .padding(.top, tokens.spacing.xSmall)
                .padding(.bottom, tokens.spacing.small)

            if scope == .songs {
                GenreFilterChipBar(options: genreOptions, selection: $selectedGenre)
                    .padding(.bottom, tokens.spacing.xxSmall)
            }

            scopeList
        }
        .background(tokens.colors.canvas.resolve(scheme))
    }

    @ViewBuilder
    var scopeList: some View {
        switch scope {
        case .songs: songList
        case .albums: albumList
        case .artists: artistList
        }
    }

    var songTracks: [TrackRecord] {
        if let genreModel { genreModel.tracks } else { environment.library.tracks }
    }

    var isLoadingSongs: Bool {
        if let genreModel { genreModel.isLoading } else { environment.library.isLoadingTracks }
    }

    @ViewBuilder
    var songList: some View {
        if songTracks.isEmpty {
            if isLoadingSongs {
                StateView.loading()
            } else {
                StateView.empty()
            }
        } else {
            PlayableTrackList(tracks: songTracks) {
                Task { await loadMoreSongs() }
            }
        }
    }

    @ViewBuilder
    var albumList: some View {
        if environment.library.albums.isEmpty {
            StateView.empty()
        } else {
            List {
                ForEach(environment.library.albums, id: \.id) { album in
                    NavigationLink(value: album) { albumRow(album) }
                        .modifier(BrowseRow())
                        .onAppear { paginateAlbums(album) }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    @ViewBuilder
    var artistList: some View {
        if environment.library.artists.isEmpty {
            StateView.empty()
        } else {
            List {
                ForEach(environment.library.artists, id: \.id) { artist in
                    NavigationLink(value: artist) { artistRow(artist) }
                        .modifier(BrowseRow())
                        .onAppear { paginateArtists(artist) }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    var searchResults: some View {
        PlayableTrackList(tracks: environment.search.results) {
            environment.search.loadMore()
        }
    }
}

// MARK: - Album / artist rows

private extension LibraryScreen {
    func albumRow(_ album: AlbumRecord) -> some View {
        HStack(spacing: tokens.spacing.medium) {
            ArtworkView(image: nil, cornerRadius: tokens.radii.small, shadow: tokens.elevation.low)
                .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: tokens.spacing.xxSmall) {
                Text(verbatim: album.title ?? String(localized: MacAMPStrings.unknownTitle))
                    .font(tokens.typography.headline.font)
                    .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
                    .lineLimit(1)
                Text(verbatim: albumSubtitle(album))
                    .font(tokens.typography.caption.font)
                    .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.forward")
                .font(tokens.typography.caption.font)
                .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
        }
        .padding(.vertical, tokens.spacing.xSmall)
        .padding(.horizontal, tokens.spacing.medium)
        .contentShape(Rectangle())
    }

    func artistRow(_ artist: ArtistRecord) -> some View {
        HStack(spacing: tokens.spacing.medium) {
            ZStack {
                Circle().fill(tokens.colors.accentMuted.resolve(scheme))
                Image(systemName: "music.mic")
                    .font(tokens.typography.headline.font)
                    .foregroundStyle(tokens.colors.accent.resolve(scheme))
            }
            .frame(width: 52, height: 52)
            Text(verbatim: artist.name ?? artist.sortName)
                .font(tokens.typography.headline.font)
                .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
                .lineLimit(1)
            Spacer(minLength: 0)
            Image(systemName: "chevron.forward")
                .font(tokens.typography.caption.font)
                .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
        }
        .padding(.vertical, tokens.spacing.xSmall)
        .padding(.horizontal, tokens.spacing.medium)
        .contentShape(Rectangle())
    }

    func albumSubtitle(_ album: AlbumRecord) -> String {
        if let year = album.year {
            String(year)
        } else {
            String(localized: MacAMPStrings.libraryScopeAlbums)
        }
    }
}

/// Shared list-row chrome for the album/artist browse lists: clear background and
/// hidden separators so each row floats on the screen's `canvas`.
private struct BrowseRow: ViewModifier {
    func body(content: Content) -> some View {
        content
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

// MARK: - Loading

private extension LibraryScreen {
    func loadInitial() async {
        switch scope {
        case .songs:
            await loadGenreOptions()
            await reloadSongs()
        case .albums:
            if environment.library.albums.isEmpty { try? await environment.library.loadInitialAlbums() }
        case .artists:
            if environment.library.artists.isEmpty { try? await environment.library.loadInitialArtists() }
        }
    }

    func loadGenreOptions() async {
        let repository = TrackRepository(environment.database)
        let loaded = try? await repository.distinctGenres()
        let facets = loaded ?? LibraryGenreFacets(genres: [], includesUntagged: false)
        genreOptions = GenreFilter.options(from: facets)
        if !genreOptions.contains(selectedGenre) {
            selectedGenre = .all
        }
    }

    func reloadSongs() async {
        if selectedGenre.isAll {
            genreModel = nil
            if environment.library.tracks.isEmpty {
                try? await environment.library.loadInitialTracks()
            }
        } else {
            let model = GenreBrowserViewModel(
                repository: TrackRepository(environment.database),
                genre: selectedGenre.queryArgument
            )
            genreModel = model
            try? await model.loadInitial()
        }
    }

    func loadMoreSongs() async {
        if let genreModel {
            try? await genreModel.loadMore()
        } else {
            try? await environment.library.loadMoreTracks()
        }
    }

    func paginateAlbums(_ album: AlbumRecord) {
        guard album.id == environment.library.albums.last?.id else { return }
        Task { try? await environment.library.loadMoreAlbums() }
    }

    func paginateArtists(_ artist: ArtistRecord) {
        guard artist.id == environment.library.artists.last?.id else { return }
        Task { try? await environment.library.loadMoreArtists() }
    }
}

#Preview {
    LibraryScreen()
        .environment(AppEnvironment.preview())
        .designTokens(.standard)
}
