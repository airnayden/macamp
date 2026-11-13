import Artwork
import DesignSystem
import Metadata
import Persistence
import Services
import SwiftUI
import ViewModels

struct ArtistsGridView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(NavigationModel.self) private var nav
    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme
    @State private var model: ArtistsBrowserModel?
    @State private var selectedArtist: ArtistRecord?
    @State private var selectedAlbum: AlbumRecord?
    @State private var sortAscending = true
    @State private var searchText = ""

    var body: some View {
        Group {
            if let selectedAlbum {
                AlbumDetailView(album: selectedAlbum, onBack: { self.selectedAlbum = nil })
            } else if let selectedArtist {
                ArtistDetailView(
                    artist: selectedArtist,
                    onBack: {
                        self.selectedArtist = nil
                        nav.artistDetail = nil
                    },
                    onAlbumSelected: { selectedAlbum = $0 }
                )
            } else {
                mainContent
            }
        }
        .task { await start() }
        .task(id: nav.artistDetail) {
            guard let artistId = nav.artistDetail else { return }
            let record = try? await environment.database.writer.read { db in
                try ArtistRecord.fetchOne(db, key: artistId)
            }
            if let record { selectedArtist = record }
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        if let model {
            if model.artists.isEmpty {
                if model.isLoading {
                    StateView.loading()
                } else {
                    StateView(
                        systemImage: LibrarySection.artists.systemImage,
                        title: LibraryGridStrings.artistsEmpty,
                        message: nil
                    )
                }
            } else {
                VStack(spacing: 0) {
                    sortBar
                    Divider()
                    grid(model)
                }
            }
        } else {
            StateView.loading()
        }
    }

    private var sortBar: some View {
        HStack(spacing: tokens.spacing.small) {
            HStack(spacing: tokens.spacing.xSmall) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
                    .font(tokens.typography.caption.font)
                TextField(String(localized: MacAMPStrings.filterArtists), text: $searchText)
                    .accessibilityLabel(Text(MacAMPStrings.filterArtists))
                    .textFieldStyle(.plain)
                    .font(tokens.typography.callout.font)
                    .frame(maxWidth: 160)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .help(Text(MacAMPStrings.helpClearSearch))
                    .pointingHandCursor()
                }
            }
            .padding(.horizontal, tokens.spacing.small)
            .padding(.vertical, tokens.spacing.xxSmall)
            .background(Capsule(style: .continuous).fill(tokens.colors.surfaceRaised.resolve(scheme)))
            Spacer()
            Button {
                sortAscending.toggle()
            } label: {
                HStack(spacing: tokens.spacing.xxSmall) {
                    Image(systemName: "textformat")
                    Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                }
                .font(tokens.typography.caption.font)
                .foregroundStyle(tokens.colors.accent.resolve(scheme))
            }
            .buttonStyle(.plain)
            .help(Text(LibraryGridStrings.sortByName))
            .pointingHandCursor()
        }
        .padding(.horizontal, tokens.spacing.medium)
        .padding(.vertical, tokens.spacing.xSmall)
    }

    private func grid(_ model: ArtistsBrowserModel) -> some View {
        let filtered = searchText.isEmpty ? model.artists : model.artists.filter {
            ($0.artist.name ?? "").localizedCaseInsensitiveContains(searchText)
        }
        let sorted = sortedArtists(filtered)
        return ScrollView {
            LazyVGrid(
                columns: [GridItem(
                    .adaptive(minimum: LibraryGridMetrics.tileMinWidth),
                    spacing: tokens.spacing.medium
                )],
                spacing: tokens.spacing.medium
            ) {
                ForEach(sorted, id: \.artist.id) { entry in
                    Button { selectedArtist = entry.artist } label: {
                        MediaGridTile(
                            title: entry.artist.name ?? String(localized: LibraryGridStrings.unknownArtist),
                            subtitle: LibraryGridStrings.albumCount(entry.albumCount),
                            fallbackIcon: "person.fill",
                            artworkLoader: { await loadArtistArt(entry) }
                        )
                    }
                    .buttonStyle(.plain)
                    .onAppear { model.loadMoreIfLast(entry) }
                }
            }
            .padding(tokens.spacing.medium)
        }
        .background(tokens.colors.canvas.resolve(scheme).opacity(0.25))
    }

    private func sortedArtists(_ artists: [ArtistWithAlbumCount]) -> [ArtistWithAlbumCount] {
        artists.sorted { lhs, rhs in
            let comparison = (lhs.artist.name ?? "").localizedCaseInsensitiveCompare(rhs.artist.name ?? "")
            return sortAscending ? comparison == .orderedAscending : comparison == .orderedDescending
        }
    }

    private func loadArtistArt(_ entry: ArtistWithAlbumCount) async -> CGImage? {
        guard let artistId = entry.artist.id else { return nil }
        let firstTrack = try? await environment.database.writer.read { db in
            try TrackRecord.filter(sql: "artistId = ?", arguments: [artistId]).fetchOne(db)
        }
        guard let firstTrack else { return nil }
        let request = ArtworkRequest(
            albumKey: ArtworkRequest.AlbumKey(artist: firstTrack.artistName ?? "", album: firstTrack.albumTitle ?? ""),
            sourceURL: URL(fileURLWithPath: firstTrack.filePath),
            rendition: .thumbnail(maxPixel: Int(LibraryGridMetrics.tileMinWidth))
        )
        let result = try? await environment.artworkProvider.artwork(for: request)
        return AlbumArtImage.decode(result?.data, maxPixel: Int(LibraryGridMetrics.tileMinWidth))
    }

    private func start() async {
        guard model == nil else { return }
        let profileId = environment.profileService.activeProfile.id ?? ProfileRecord.guestID
        let model = ArtistsBrowserModel(repository: ArtistRepository(environment.database), profileId: profileId)
        self.model = model
        await model.loadInitial()
    }
}

struct ArtistDetailView: View {
    let artist: ArtistRecord
    var onBack: (() -> Void)?
    var onAlbumSelected: ((AlbumRecord) -> Void)?

    @Environment(AppEnvironment.self) private var environment
    @Environment(AppSettings.self) private var settings
    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme
    @State private var model: ArtistAlbumsModel?
    @State private var artistInfo: ArtistInfo?
    @State private var heroImage: CGImage?
    @State private var infoLoaded = false
    @State private var showInfoSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let onBack {
                HStack {
                    Button { onBack() } label: {
                        HStack(spacing: tokens.spacing.xSmall) {
                            Image(systemName: "chevron.left")
                            Text(verbatim: artistName)
                                .font(tokens.typography.headline.font)
                        }
                        .foregroundStyle(tokens.colors.accent.resolve(scheme))
                    }
                    .buttonStyle(.plain)
                    .help(Text(MacAMPStrings.helpBack))
                    .pointingHandCursor()
                    Spacer()
                }
                .padding(.horizontal, tokens.spacing.medium)
                .padding(.vertical, tokens.spacing.small)
                Divider()
            }
            artistHero
            artistBio
            albumGrid
        }
        .task { await start() }
        .sheet(isPresented: $showInfoSheet) {
            InfoSheetView(
                title: artistName,
                info: artistInfo?.biography,
                tags: artistInfo?.tags ?? [],
                isLoading: !infoLoaded
            )
            .environment(environment)
            .designTokens(tokens)
        }
        .task(id: artist.id) { await loadBio() }
    }

    private var artistName: String {
        artist.name ?? String(localized: LibraryGridStrings.unknownArtist)
    }

    private var artistHero: some View {
        HStack(alignment: .center, spacing: tokens.spacing.large) {
            HoverInfoButton(
                color: tokens.colors.textPrimary.resolve(scheme),
                help: InfoPanelStrings.artistHeading,
                action: { showInfoSheet = true },
                content: {
                    ZStack {
                        Circle()
                            .fill(tokens.colors.surfaceRaised.resolve(scheme))
                        if let heroImage {
                            Image(decorative: heroImage, scale: 1)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } else {
                            Image(systemName: "person.fill")
                                .font(.system(size: 40))
                                .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
                        }
                    }
                    .frame(width: 120, height: 120)
                    .clipShape(Circle())
                }
            )
            Text(verbatim: artistName)
                .font(tokens.typography.displayMedium.font)
                .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, tokens.spacing.large)
        .padding(.vertical, tokens.spacing.medium)
    }

    @ViewBuilder
    private var artistBio: some View {
        if let text = artistInfo?.biography, !text.isEmpty {
            HoverInfoButton(
                font: .title3,
                color: tokens.colors.accent.resolve(scheme),
                alignment: .topTrailing,
                shadowRadius: 0,
                help: InfoPanelStrings.artistHeading,
                action: { showInfoSheet = true },
                content: {
                    VStack(alignment: .leading, spacing: tokens.spacing.xSmall) {
                        Text(InfoPanelStrings.artistHeading)
                            .font(tokens.typography.headline.font)
                            .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
                        Text(verbatim: text)
                            .font(tokens.typography.body.font)
                            .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, tokens.spacing.medium)
                    .padding(.vertical, tokens.spacing.small)
                }
            )
        }
    }

    @ViewBuilder
    private var albumGrid: some View {
        if let model {
            if model.albums.isEmpty, model.isLoading {
                StateView.loading()
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(
                            .adaptive(minimum: LibraryGridMetrics.tileMinWidth),
                            spacing: tokens.spacing.medium
                        )],
                        spacing: tokens.spacing.medium
                    ) {
                        ForEach(model.albums, id: \.id) { album in
                            Button { onAlbumSelected?(album) } label: {
                                MediaGridTile(
                                    title: album.title ?? String(localized: LibraryGridStrings.untitledAlbum),
                                    subtitle: album.year.map(String.init),
                                    fallbackIcon: "music.note",
                                    artworkLoader: { await loadAlbumArt(album) }
                                )
                            }
                            .buttonStyle(.plain)
                            .onAppear { model.loadMoreIfLast(album) }
                        }
                    }
                    .padding(tokens.spacing.medium)
                }
                .background(tokens.colors.canvas.resolve(scheme).opacity(0.25))
            }
        } else {
            StateView.loading()
        }
    }

    private func loadAlbumArt(_ album: AlbumRecord) async -> CGImage? {
        guard let albumId = album.id else { return nil }
        let firstTrack = try? await environment.database.writer.read { db in
            try TrackRecord.filter(sql: "albumId = ?", arguments: [albumId]).fetchOne(db)
        }
        guard let firstTrack else { return nil }
        let request = ArtworkRequest(
            albumKey: ArtworkRequest.AlbumKey(artist: firstTrack.artistName ?? "", album: album.title ?? ""),
            sourceURL: URL(fileURLWithPath: firstTrack.filePath),
            rendition: .thumbnail(maxPixel: Int(LibraryGridMetrics.tileMinWidth))
        )
        let result = try? await environment.artworkProvider.artwork(for: request)
        return AlbumArtImage.decode(result?.data, maxPixel: Int(LibraryGridMetrics.tileMinWidth))
    }

    private func start() async {
        guard model == nil, let artistId = artist.id else { return }
        let profileId = environment.profileService.activeProfile.id ?? ProfileRecord.guestID
        let model = ArtistAlbumsModel(
            repository: AlbumRepository(environment.database),
            artistId: artistId,
            profileId: profileId
        )
        self.model = model
        await model.loadInitial()
        await loadHeroImage()
    }

    private func loadHeroImage() async {
        guard let artistId = artist.id else { return }
        let firstTrack = try? await environment.database.writer.read { db in
            try TrackRecord.filter(sql: "artistId = ?", arguments: [artistId]).fetchOne(db)
        }
        guard let firstTrack else { return }
        let request = ArtworkRequest(
            albumKey: ArtworkRequest.AlbumKey(artist: firstTrack.artistName ?? "", album: firstTrack.albumTitle ?? ""),
            sourceURL: URL(fileURLWithPath: firstTrack.filePath),
            rendition: .thumbnail(maxPixel: Int(LibraryGridMetrics.heroArtworkWidth))
        )
        let result = try? await environment.artworkProvider.artwork(for: request)
        heroImage = AlbumArtImage.decode(result?.data, maxPixel: Int(LibraryGridMetrics.heroArtworkWidth))
    }

    private func loadBio() async {
        defer { infoLoaded = true }
        guard settings.onlineDataEnabled else { return }
        let name = artist.name ?? artist.sortName
        guard !name.isEmpty else { return }
        artistInfo = await environment.infoService.artistInfo(name: name, mbid: artist.mbid)
    }
}
