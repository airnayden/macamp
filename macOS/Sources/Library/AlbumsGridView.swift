import Artwork
import DesignSystem
import Persistence
import Services
import SwiftUI
import ViewModels

enum LibraryGridMetrics {
    static let tileMinWidth: CGFloat = 150
    static let heroArtworkWidth: CGFloat = 220
}

struct AlbumsGridView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme
    @State private var model: AlbumsBrowserModel?
    @State private var selectedAlbum: AlbumRecord?
    @State private var sortAscending = true
    @State private var sortByYear = false
    @State private var searchText = ""

    var body: some View {
        Group {
            if let selectedAlbum {
                AlbumDetailView(album: selectedAlbum, onBack: { self.selectedAlbum = nil })
            } else {
                mainContent
            }
        }
        .task { await start() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("albums.view")
    }

    @ViewBuilder
    private var mainContent: some View {
        if let model {
            if model.albums.isEmpty {
                if model.isLoading {
                    StateView.loading()
                } else {
                    StateView(
                        systemImage: LibrarySection.albums.systemImage,
                        title: LibraryGridStrings.albumsEmpty,
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
                TextField(String(localized: MacAMPStrings.filterAlbums), text: $searchText)
                    .accessibilityLabel(Text(MacAMPStrings.filterAlbums))
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
                sortByYear = false
                sortAscending.toggle()
            } label: {
                HStack(spacing: tokens.spacing.xxSmall) {
                    Image(systemName: "textformat")
                    Image(systemName: sortAscending && !sortByYear ? "chevron.up" : "chevron.down")
                }
                .font(tokens.typography.caption.font)
                .foregroundStyle(!sortByYear ? tokens.colors.accent.resolve(scheme) : tokens.colors.textTertiary
                    .resolve(scheme))
            }
            .buttonStyle(.plain)
            .help(Text(LibraryGridStrings.sortByName))
            .pointingHandCursor()

            Button {
                sortByYear = true
                sortAscending.toggle()
            } label: {
                HStack(spacing: tokens.spacing.xxSmall) {
                    Image(systemName: "calendar")
                    Image(systemName: sortAscending && sortByYear ? "chevron.up" : "chevron.down")
                }
                .font(tokens.typography.caption.font)
                .foregroundStyle(sortByYear ? tokens.colors.accent.resolve(scheme) : tokens.colors.textTertiary
                    .resolve(scheme))
            }
            .buttonStyle(.plain)
            .help(Text(LibraryGridStrings.sortByYear))
            .pointingHandCursor()
        }
        .padding(.horizontal, tokens.spacing.medium)
        .padding(.vertical, tokens.spacing.xSmall)
    }

    private func grid(_ model: AlbumsBrowserModel) -> some View {
        let filtered = searchText.isEmpty ? model.albums : model.albums.filter {
            ($0.album.title ?? "").localizedCaseInsensitiveContains(searchText)
        }
        let sorted = sortedAlbums(filtered)
        return ScrollView {
            LazyVGrid(
                columns: [GridItem(
                    .adaptive(minimum: LibraryGridMetrics.tileMinWidth),
                    spacing: tokens.spacing.medium
                )],
                spacing: tokens.spacing.medium
            ) {
                ForEach(sorted, id: \.album.id) { entry in
                    Button { selectedAlbum = entry.album } label: {
                        MediaGridTile(
                            title: entry.album.title ?? String(localized: LibraryGridStrings.untitledAlbum),
                            subtitle: entry.album.year.map(String.init),
                            fallbackIcon: "music.note",
                            artworkLoader: { await loadAlbumArt(entry) }
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

    private func sortedAlbums(_ albums: [AlbumWithTrackCount]) -> [AlbumWithTrackCount] {
        albums.sorted { lhs, rhs in
            if sortByYear {
                let leftYear = lhs.album.year ?? 0
                let rightYear = rhs.album.year ?? 0
                return sortAscending ? leftYear < rightYear : leftYear > rightYear
            } else {
                let comparison = (lhs.album.title ?? "").localizedCaseInsensitiveCompare(rhs.album.title ?? "")
                return sortAscending ? comparison == .orderedAscending : comparison == .orderedDescending
            }
        }
    }

    private func loadAlbumArt(_ entry: AlbumWithTrackCount) async -> CGImage? {
        guard let albumId = entry.album.id else { return nil }
        let firstTrack = try? await environment.database.writer.read { db in
            try TrackRecord.filter(sql: "albumId = ?", arguments: [albumId]).fetchOne(db)
        }
        guard let firstTrack else { return nil }
        let request = ArtworkRequest(
            albumKey: ArtworkRequest.AlbumKey(artist: firstTrack.artistName ?? "", album: entry.album.title ?? ""),
            sourceURL: URL(fileURLWithPath: firstTrack.filePath),
            rendition: .thumbnail(maxPixel: Int(LibraryGridMetrics.tileMinWidth))
        )
        let result = try? await environment.artworkProvider.artwork(for: request)
        return AlbumArtImage.decode(result?.data, maxPixel: Int(LibraryGridMetrics.tileMinWidth))
    }

    private func start() async {
        guard model == nil else { return }
        let profileId = environment.profileService.activeProfile.id ?? ProfileRecord.guestID
        let model = AlbumsBrowserModel(repository: AlbumRepository(environment.database), profileId: profileId)
        self.model = model
        await model.loadInitial()
    }
}
