// AlbumDetailView — one album's hero header over its track list.
//
// A large placeholder artwork + title + year with Play All / Shuffle actions, then
// the album's tracks (loaded off-main by ``AlbumTracksModel``, ordered by track
// number). Double-clicking a track plays the whole album starting at that row; all
// playback goes through the shared ``PlaybackCoordinator`` exactly as the library
// table does. Token-styled throughout (no magic numbers).
import Artwork
import DesignSystem
import Metadata
import Persistence
import Services
import SwiftUI

/// The detail screen pushed when an album tile is selected.
struct AlbumDetailView: View {
    let album: AlbumRecord
    var onBack: (() -> Void)?

    @Environment(AppEnvironment.self) private var environment
    @Environment(AppSettings.self) private var settings
    @Environment(PlayIntent.self) private var playIntent
    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme
    @State private var model: AlbumTracksModel?
    @State private var heroImage: CGImage?
    @State private var albumInfo: AlbumInfo?
    @State private var infoLoaded = false
    @State private var showInfoSheet = false
    @State private var selection = Set<Int64>()
    @State private var favouriteOverrides: [Int64: Bool] = [:]
    @State private var favouriteIds: Set<Int64> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let onBack {
                HStack {
                    Button { onBack() } label: {
                        HStack(spacing: tokens.spacing.xSmall) {
                            Image(systemName: "chevron.left")
                            Text(verbatim: albumTitle)
                                .font(tokens.typography.headline.font)
                        }
                        .foregroundStyle(tokens.colors.accent.resolve(scheme))
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                .padding(.horizontal, tokens.spacing.medium)
                .padding(.vertical, tokens.spacing.small)
                Divider()
            }
            VStack(alignment: .leading, spacing: tokens.spacing.large) {
                header
                albumDescription
            }
            .padding(tokens.spacing.large)
            trackList
        }
        .background(tokens.colors.canvas.resolve(scheme).opacity(0.25))
        .task(id: environment.profileService.activeProfile.id) { await start() }
        .onChange(of: playIntent.idlePlayToken) { _, _ in playSelectionOrFirst() }
        .sheet(isPresented: $showInfoSheet) {
            InfoSheetView(
                title: albumTitle,
                info: albumInfo?.description,
                tags: albumInfo?.tags ?? [],
                isLoading: !infoLoaded
            )
            .environment(environment)
            .designTokens(tokens)
        }
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: tokens.spacing.large) {
            HoverInfoButton(
                color: tokens.colors.textPrimary.resolve(scheme),
                help: InfoPanelStrings.albumHeading,
                action: { showInfoSheet = true },
                content: {
                    ZStack {
                        RoundedRectangle(cornerRadius: tokens.radii.large, style: .continuous)
                            .fill(tokens.colors.surfaceRaised.resolve(scheme))
                        if let heroImage {
                            Image(decorative: heroImage, scale: 1)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } else {
                            Image(systemName: "music.note")
                                .font(.system(size: 48))
                                .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
                        }
                    }
                    .frame(width: LibraryGridMetrics.heroArtworkWidth, height: LibraryGridMetrics.heroArtworkWidth)
                    .clipShape(RoundedRectangle(cornerRadius: tokens.radii.large, style: .continuous))
                }
            )
            VStack(alignment: .leading, spacing: tokens.spacing.small) {
                Text(verbatim: albumTitle)
                    .font(tokens.typography.displayMedium.font)
                    .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
                    .lineLimit(2)
                if let year = album.year {
                    Text(verbatim: String(year))
                        .font(tokens.typography.callout.font)
                        .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
                }
                actionButtons
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var albumDescription: some View {
        if let text = albumInfo?.description, !text.isEmpty {
            VStack(alignment: .leading, spacing: tokens.spacing.xSmall) {
                Text(InfoPanelStrings.albumHeading)
                    .font(tokens.typography.headline.font)
                    .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
                Text(verbatim: text)
                    .font(tokens.typography.body.font)
                    .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var actionButtons: some View {
        HStack(spacing: tokens.spacing.small) {
            Button { playAll(shuffled: false) } label: {
                Label { Text(LibraryGridStrings.playAll) } icon: { Image(systemName: "play.fill") }
            }
            .buttonStyle(.borderedProminent)
            .tint(tokens.colors.accent.resolve(scheme))
            Button { playAll(shuffled: true) } label: {
                Label { Text(LibraryGridStrings.shuffle) } icon: { Image(systemName: "shuffle") }
            }
            .buttonStyle(.bordered)
        }
        .disabled(model?.tracks.isEmpty ?? true)
    }

    @ViewBuilder
    private var trackList: some View {
        if let model {
            if model.isLoading, model.tracks.isEmpty {
                StateView.loading()
            } else {
                albumTrackList(model.tracks)
            }
        }
    }

    private var albumTitle: String {
        album.title ?? String(localized: LibraryGridStrings.untitledAlbum)
    }

    private func start() async {
        guard model == nil else {
            // A profile switch re-fires this task; the album's tracks are
            // profile-independent, so only the favourite state is refreshed.
            favouriteOverrides.removeAll()
            await loadFavourites()
            return
        }
        let model = AlbumTracksModel(writer: environment.database.writer, album: album)
        self.model = model
        await model.load()
        await loadFavourites()
        await loadHeroImage()
        await loadInfo()
    }

    private func loadFavourites() async {
        let profileId = environment.profileService.activeProfile.id ?? ProfileRecord.guestID
        let repo = TrackRepository(environment.database)
        favouriteIds = await (try? Task.detached { try repo.favouriteTrackIDs(profileId: profileId) }.value) ?? []
    }

    private func loadInfo() async {
        defer { infoLoaded = true }
        guard settings.onlineDataEnabled else { return }
        guard let title = album.title, !title.isEmpty else { return }
        let artist = model?.tracks.first?.artistName
        albumInfo = await environment.infoService.albumInfo(title: title, artist: artist, mbid: nil)
    }

    private func loadHeroImage() async {
        guard let albumId = album.id else { return }
        let firstTrack = try? await environment.database.writer.read { db in
            try TrackRecord.filter(sql: "albumId = ?", arguments: [albumId]).fetchOne(db)
        }
        guard let firstTrack else { return }
        let request = ArtworkRequest(
            albumKey: ArtworkRequest.AlbumKey(artist: firstTrack.artistName ?? "", album: album.title ?? ""),
            sourceURL: URL(fileURLWithPath: firstTrack.filePath),
            rendition: .thumbnail(maxPixel: Int(LibraryGridMetrics.heroArtworkWidth))
        )
        let result = try? await environment.artworkProvider.artwork(for: request)
        heroImage = AlbumArtImage.decode(result?.data, maxPixel: Int(LibraryGridMetrics.heroArtworkWidth))
    }

    private func playAll(shuffled: Bool) {
        guard let albumId = album.id,
              let tracks = model?.tracks,
              !tracks.isEmpty
        else { return }
        let refs = tracks.map { TrackRef(record: $0) }
        environment.coordinator.setQueue(
            shuffled ? refs.shuffled() : refs,
            startingAt: 0,
            source: .albumDetail(id: albumId)
        )
        environment.queue.refresh()
    }

    private func play(startingAt index: Int) {
        guard let albumId = album.id,
              let tracks = model?.tracks,
              tracks.indices.contains(index)
        else { return }
        let refs = tracks.map { TrackRef(record: $0) }
        environment.coordinator.setQueue(refs, startingAt: index, source: .albumDetail(id: albumId))
        environment.queue.refresh()
    }
}

// MARK: - Track list

private extension AlbumDetailView {
    /// Shared ``TrackListRow`` in a `List(selection:)` — the same pattern the
    /// library, playlists, favourites and queue use, so every track list matches.
    func albumTrackList(_ tracks: [TrackRecord]) -> some View {
        List(selection: $selection) {
            ForEach(tracks, id: \.id) { track in
                rowView(track)
                    .tag(track.id ?? 0)
            }
        }
        .scrollContentBackground(.hidden)
        .background(tokens.colors.canvas.resolve(scheme).opacity(0.25))
        .contextMenu(forSelectionType: Int64.self) { ids in
            contextMenu(for: ids)
        } primaryAction: { ids in
            play(rowIds: ids)
        }
    }

    func rowView(_ track: TrackRecord) -> some View {
        TrackListRow(
            number: track.trackNumber ?? 0,
            title: track.title ?? track.filePath,
            artist: track.artistName,
            artistId: track.artistId,
            duration: track.duration,
            isPlaying: isCurrent(track),
            availability: track.availability,
            isFavourite: isFavourite(track),
            onToggleFavourite: { toggleFavourite(track) },
            karaokeState: environment.karaokeRowState(
                filePath: track.filePath,
                enabled: settings.karaokeEnabled
            ),
            onRequestKaraokeRender: environment.karaokeRenderAction(
                filePath: track.filePath,
                enabled: settings.karaokeEnabled
            ),
            onDequeueKaraoke: environment.karaokeDequeueAction(
                filePath: track.filePath,
                enabled: settings.karaokeEnabled
            )
        )
    }

    func isCurrent(_ track: TrackRecord) -> Bool {
        guard let trackId = track.id else { return false }
        return trackId == environment.player.currentTrack?.trackID
    }
}

// MARK: - Favourites

private extension AlbumDetailView {
    func isFavourite(_ track: TrackRecord) -> Bool {
        guard let trackId = track.id else { return false }
        return favouriteOverrides[trackId] ?? favouriteIds.contains(trackId)
    }

    func toggleFavourite(_ track: TrackRecord) {
        guard let trackId = track.id else { return }
        let wasF = isFavourite(track)
        favouriteOverrides[trackId] = !wasF
        let profileId = environment.profileService.activeProfile.id ?? ProfileRecord.guestID
        let repository = TrackRepository(environment.database)
        let name = track.title ?? track.filePath
        Task { try? await repository.toggleFavourite(profileId: profileId, trackId: trackId) }
        environment.toast.show(
            text: wasF
                ? "\(String(localized: FavouritesStrings.removedToast)) \"\(name)\""
                : "\(String(localized: FavouritesStrings.addedToast)) \"\(name)\"",
            icon: wasF ? "heart.slash" : "heart.fill"
        )
    }
}

// MARK: - Context menu + selection playback

private extension AlbumDetailView {
    @ViewBuilder
    func contextMenu(for ids: Set<Int64>) -> some View {
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
            filePaths: refs(for: ids).map(\.filePath),
            enabled: settings.karaokeEnabled
        )
    }

    func refs(for ids: Set<Int64>) -> [TrackRef] {
        guard let tracks = model?.tracks else { return [] }
        return tracks.filter { ids.contains($0.id ?? 0) }.map { TrackRef(record: $0) }
    }

    func play(_ ids: Set<Int64>) {
        let selected = refs(for: ids)
        guard let albumId = album.id, !selected.isEmpty else { return }
        environment.coordinator.setQueue(selected, startingAt: 0, source: .albumDetail(id: albumId))
        environment.queue.refresh()
    }

    func playSelectionOrFirst() {
        if !selection.isEmpty { play(selection) }
        else if let first = model?.tracks.first?.id { play([first]) }
    }

    func playNext(_ ids: Set<Int64>) {
        let selected = refs(for: ids)
        guard !selected.isEmpty else { return }
        environment.coordinator.playNextManual(contentsOf: selected)
        environment.queue.refresh()
    }

    func enqueue(_ ids: Set<Int64>) {
        let selected = refs(for: ids)
        guard !selected.isEmpty else { return }
        environment.coordinator.enqueueManual(contentsOf: selected)
        environment.queue.refresh()
    }

    func play(rowIds ids: Set<Int64>) {
        guard let tracks = model?.tracks,
              let clickedId = ids.first,
              let index = tracks.firstIndex(where: { $0.id == clickedId })
        else { return }
        play(startingAt: index)
    }
}
