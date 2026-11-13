// ArtistDetailView — one artist's albums and tracks (Task 33).
//
// A pinned header (artist name + Play/Shuffle over every track) sits above a
// horizontally-paged album carousel and the shared ``PlayableTrackList`` of the
// artist's songs. Both the albums and the tracks come from the keyset-paginated
// ``ArtistDetailViewModel`` — only the loaded windows live in memory. Tapping an
// album card drills into ``AlbumDetailView`` via value-based navigation resolved by
// the enclosing ``LibraryScreen`` stack. Artist/album text is DATA → `Text(verbatim:)`.
import DesignSystem
import Persistence
import Services
import SwiftUI

struct ArtistDetailView: View {
    let artist: ArtistRecord

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    @State private var model: ArtistDetailViewModel?

    var body: some View {
        content
            .navigationTitle(Text(verbatim: artistDisplayName))
            .navigationBarTitleDisplayMode(.inline)
            .task(id: artist.id) { await load() }
    }
}

// MARK: - Content

private extension ArtistDetailView {
    @ViewBuilder
    var content: some View {
        if let model, !isEmpty(model) {
            VStack(spacing: 0) {
                header(for: model.tracks)
                if !model.albums.isEmpty {
                    albumsSection(model)
                }
                tracksSection(model)
            }
        } else if model?.isLoadingTracks ?? true {
            StateView.loading()
        } else {
            StateView(
                systemImage: "music.mic",
                title: MacAMPStrings.artistEmptyTitle,
                message: MacAMPStrings.artistEmptyMessage
            )
        }
    }

    func header(for tracks: [TrackRecord]) -> some View {
        VStack(spacing: tokens.spacing.small) {
            Text(verbatim: artistDisplayName)
                .font(tokens.typography.titleLarge.font)
                .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
                .multilineTextAlignment(.center)
                .lineLimit(2)
            if !tracks.isEmpty {
                DetailPlayBar(
                    playTitle: MacAMPStrings.artistPlay,
                    shuffleTitle: MacAMPStrings.artistShuffle,
                    onPlay: { play(tracks, shuffled: false) },
                    onShuffle: { play(tracks, shuffled: true) }
                )
            }
        }
        .padding(.horizontal, tokens.spacing.large)
        .padding(.top, tokens.spacing.medium)
        .padding(.bottom, tokens.spacing.small)
    }

    func albumsSection(_ model: ArtistDetailViewModel) -> some View {
        VStack(alignment: .leading, spacing: tokens.spacing.xSmall) {
            sectionHeader(MacAMPStrings.artistAlbumsHeader)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: tokens.spacing.medium) {
                    ForEach(model.albums, id: \.id) { album in
                        NavigationLink(value: album) { albumCard(album) }
                            .buttonStyle(.plain)
                            .onAppear { paginateAlbums(album, in: model) }
                    }
                }
                .padding(.horizontal, tokens.spacing.large)
            }
        }
        .padding(.bottom, tokens.spacing.small)
    }

    func tracksSection(_ model: ArtistDetailViewModel) -> some View {
        VStack(alignment: .leading, spacing: tokens.spacing.xSmall) {
            sectionHeader(MacAMPStrings.artistSongsHeader)
                .padding(.horizontal, tokens.spacing.large)
            PlayableTrackList(tracks: model.tracks) {
                Task { try? await model.loadMoreTracks() }
            }
        }
    }

    func sectionHeader(_ title: LocalizedStringResource) -> some View {
        Text(title)
            .font(tokens.typography.headline.font)
            .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    func albumCard(_ album: AlbumRecord) -> some View {
        VStack(alignment: .leading, spacing: tokens.spacing.xxSmall) {
            ArtworkView(image: nil, cornerRadius: tokens.radii.medium, shadow: tokens.elevation.low)
                .frame(width: 124, height: 124)
            Text(verbatim: album.title ?? String(localized: MacAMPStrings.unknownTitle))
                .font(tokens.typography.caption.font)
                .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
                .lineLimit(1)
            if let year = album.year {
                Text(verbatim: String(year))
                    .font(tokens.typography.caption.font)
                    .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
            }
        }
        .frame(width: 124, alignment: .leading)
    }
}

// MARK: - Derived state + loading

private extension ArtistDetailView {
    var artistDisplayName: String {
        artist.name ?? artist.sortName
    }

    func isEmpty(_ model: ArtistDetailViewModel) -> Bool {
        model.albums.isEmpty && model.tracks.isEmpty
    }

    func load() async {
        guard let artistId = artist.id else { return }
        let model = model ?? ArtistDetailViewModel(
            trackRepository: TrackRepository(environment.database),
            albumRepository: AlbumRepository(environment.database),
            artistId: artistId
        )
        self.model = model
        async let albums: Void = await (try? model.loadInitialAlbums()) ?? ()
        async let tracks: Void = await (try? model.loadInitialTracks()) ?? ()
        _ = await (albums, tracks)
    }

    func paginateAlbums(_ album: AlbumRecord, in model: ArtistDetailViewModel) {
        guard album.id == model.albums.last?.id else { return }
        Task { try? await model.loadMoreAlbums() }
    }

    func play(_ tracks: [TrackRecord], shuffled: Bool) {
        let refs = tracks.map { TrackRef(record: $0) }
        guard !refs.isEmpty else { return }
        environment.coordinator.setQueue(shuffled ? refs.shuffled() : refs, startingAt: 0)
        environment.queue.refresh()
    }
}

#Preview {
    NavigationStack {
        ArtistDetailView(artist: ArtistRecord(id: 1, name: "The Artist", sortName: "Artist, The"))
            .environment(AppEnvironment.preview())
            .designTokens(.standard)
    }
}
