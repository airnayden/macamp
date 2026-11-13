// AlbumDetailView — one album's tracks under a themed cover-art header (Task 33).
//
// The header shows the album's cover (decoded off-main to a cross-platform
// CGImage) and recolors the whole surface around it: an ``AlbumTheme`` extracted
// from the artwork is applied as themed ``DesignTokens`` plus a ``ThemedBackground``
// gradient, exactly as the now-playing screen does. The track listing is the shared
// ``PlayableTrackList`` over the keyset-paginated ``AlbumDetailViewModel`` — only the
// loaded window lives in memory, never the whole album in one fetch. Album/track
// text is DATA, so it is rendered with `Text(verbatim:)`.
import Artwork
import CoreGraphics
import DesignSystem
import Persistence
import Services
import SwiftUI

struct AlbumDetailView: View {
    let album: AlbumRecord

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    @State private var model: AlbumDetailViewModel?
    @State private var artworkImage: CGImage?
    @State private var albumTheme: AlbumTheme?

    var body: some View {
        ZStack {
            ThemedBackground()
            content
        }
        .navigationTitle(Text(verbatim: albumDisplayTitle))
        .navigationBarTitleDisplayMode(.inline)
        .designTokens(tokens)
        .albumTheme(albumTheme)
        .themePresentation(presentation)
        .animation(themeAnimation, value: albumTheme)
        .task(id: album.id) { await load() }
    }
}

// MARK: - Content

private extension AlbumDetailView {
    @ViewBuilder
    var content: some View {
        if let model, !model.tracks.isEmpty {
            VStack(spacing: 0) {
                header(for: model.tracks)
                PlayableTrackList(tracks: model.tracks) {
                    Task { try? await model.loadMore() }
                }
                .scrollContentBackground(.hidden)
            }
        } else if model?.isLoading ?? true {
            StateView.loading()
        } else {
            StateView(
                systemImage: "music.note",
                title: MacAMPStrings.albumEmptyTitle,
                message: MacAMPStrings.albumEmptyMessage
            )
        }
    }

    func header(for tracks: [TrackRecord]) -> some View {
        VStack(spacing: tokens.spacing.small) {
            ArtworkView(image: artworkImage, shadow: tokens.elevation.high)
                .frame(maxWidth: 200)
                .padding(.top, tokens.spacing.medium)
            VStack(spacing: tokens.spacing.xxSmall) {
                Text(verbatim: albumDisplayTitle)
                    .font(tokens.typography.titleLarge.font)
                    .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                Text(verbatim: subtitle(for: tracks))
                    .font(tokens.typography.callout.font)
                    .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
                    .lineLimit(1)
            }
            DetailPlayBar(
                playTitle: MacAMPStrings.albumPlay,
                shuffleTitle: MacAMPStrings.albumShuffle,
                onPlay: { play(tracks, shuffled: false) },
                onShuffle: { play(tracks, shuffled: true) }
            )
        }
        .padding(.horizontal, tokens.spacing.large)
        .padding(.bottom, tokens.spacing.small)
    }
}

// MARK: - Derived state

private extension AlbumDetailView {
    var tokens: DesignTokens {
        albumTheme?.applied(to: .standard) ?? .standard
    }

    var presentation: ThemePresentationOptions {
        ThemePresentationOptions(
            reduceTransparency: reduceTransparency,
            reduceMotion: reduceMotion,
            increaseContrast: contrast == .increased
        )
    }

    var themeAnimation: Animation? {
        reduceMotion ? nil : .easeInOut(duration: tokens.motion.expressive)
    }

    var albumDisplayTitle: String {
        album.title ?? String(localized: MacAMPStrings.unknownTitle)
    }

    func subtitle(for tracks: [TrackRecord]) -> String {
        let artist = tracks.first?.artistName ?? String(localized: MacAMPStrings.unknownArtist)
        guard let year = album.year else { return artist }
        return "\(artist) · \(year)"
    }
}

// MARK: - Loading + playback

private extension AlbumDetailView {
    func load() async {
        guard let albumId = album.id else { return }
        let model = model ?? AlbumDetailViewModel(
            repository: TrackRepository(environment.database),
            albumId: albumId
        )
        self.model = model
        try? await model.loadInitial()
        await loadArtwork(for: model.tracks.first)
    }

    func loadArtwork(for track: TrackRecord?) async {
        guard let track else { return }
        let request = ArtworkRequest(
            albumKey: ArtworkRequest.AlbumKey(
                artist: track.artistName ?? "",
                album: track.albumTitle ?? album.title ?? ""
            ),
            sourceURL: URL(fileURLWithPath: track.filePath),
            rendition: .full,
            allowsNetwork: false
        )
        let data = try? await environment.artworkProvider.artwork(for: request).data
        artworkImage = AlbumArtImage.decode(data, maxPixel: 720)
        albumTheme = await AlbumArtTheming.theme(forArtwork: data, options: presentation)
    }

    func play(_ tracks: [TrackRecord], shuffled: Bool) {
        let refs = tracks.map { TrackRef(record: $0) }
        guard !refs.isEmpty else { return }
        environment.coordinator.setQueue(shuffled ? refs.shuffled() : refs, startingAt: 0)
        environment.queue.refresh()
    }
}

#Preview {
    var album = AlbumRecord(id: 1, year: 2024)
    album.title = "Greatest Hits"
    return NavigationStack {
        AlbumDetailView(album: album)
            .environment(AppEnvironment.preview())
            .designTokens(.standard)
    }
}
