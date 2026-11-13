// InfoPanelView — the right-panel "Info" tab: narrative info about the CURRENTLY
// PLAYING track. Shows the track description, the artist biography, and the album
// story (each fetched + cached by ``InfoService`` from MusicBrainz + Wikipedia),
// reloading whenever the playing track changes. Distinct from the Tags tab, which
// lists raw metadata fields. Fetched prose is DATA → rendered with `Text(verbatim:)`.
import DesignSystem
import Metadata
import Persistence
import Services
import SwiftUI

struct InfoPanelView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(AppSettings.self) private var settings
    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    @State private var trackInfo: TrackInfo?
    @State private var artistInfo: ArtistInfo?
    @State private var albumInfo: AlbumInfo?
    @State private var isLoading = false
    @State private var didLoad = false

    var body: some View {
        Group {
            if environment.player.currentTrack == nil {
                StateView(
                    systemImage: "info.circle",
                    title: InfoPanelStrings.emptyTitle,
                    message: InfoPanelStrings.emptyMessage
                )
            } else if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if hasAnyInfo {
                infoSections
            } else if !settings.onlineDataEnabled {
                VStack(spacing: tokens.spacing.medium) {
                    Image(systemName: "globe")
                        .font(.largeTitle)
                        .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
                    Text(PreferencesStrings.onlineDataDisabledHint)
                        .font(tokens.typography.callout.font)
                        .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, tokens.spacing.large)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: tokens.spacing.medium) {
                    Image(systemName: "info.circle")
                        .font(.largeTitle)
                        .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
                    Text(InfoPanelStrings.noInfo)
                        .font(tokens.typography.headline.font)
                        .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
                    Button { Task { await retry() } } label: {
                        HStack(spacing: tokens.spacing.xSmall) {
                            Image(systemName: "arrow.clockwise")
                            Text(InfoPanelStrings.retry)
                        }
                        .font(tokens.typography.callout.font)
                        .foregroundStyle(tokens.colors.onAccent.resolve(scheme))
                        .padding(.horizontal, tokens.spacing.medium)
                        .padding(.vertical, tokens.spacing.xSmall)
                        .background(Capsule().fill(tokens.colors.accent.resolve(scheme)))
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: environment.player.currentTrack?.trackID) {
            await load(track: environment.player.currentTrack)
        }
    }

    private var infoSections: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: tokens.spacing.large) {
                if let text = trackText { section(InfoPanelStrings.trackHeading, text) }
                if let text = artistText { section(InfoPanelStrings.artistHeading, text) }
                if let text = albumText { section(InfoPanelStrings.albumHeading, text) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, tokens.spacing.small)
        }
    }

    private func section(_ heading: LocalizedStringResource, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: tokens.spacing.xSmall) {
            Text(heading)
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

    private var trackText: String? {
        Self.nonEmpty(trackInfo?.description)
    }

    private var artistText: String? {
        Self.nonEmpty(artistInfo?.biography)
    }

    private var albumText: String? {
        Self.nonEmpty(albumInfo?.description)
    }

    private var hasAnyInfo: Bool {
        trackText != nil || artistText != nil || albumText != nil
    }

    private func load(track: TrackRef?) async {
        guard let track else {
            trackInfo = nil
            artistInfo = nil
            albumInfo = nil
            isLoading = false
            didLoad = true
            return
        }
        didLoad = true

        guard settings.onlineDataEnabled else {
            trackInfo = nil
            artistInfo = nil
            albumInfo = nil
            isLoading = false
            return
        }

        let title = track.title ?? ""
        let artist = track.artist ?? ""
        let album = await albumTitle(for: track.trackID) ?? ""

        let info = environment.infoService
        let cachedTrack = title.isEmpty ? nil : await info.trackInfo(title: title, artist: artist, mbid: nil)
        let cachedArtist = artist.isEmpty ? nil : await info.artistInfo(name: artist, mbid: nil)
        let cachedAlbum = album.isEmpty ? nil : await info.albumInfo(title: album, artist: artist, mbid: nil)

        trackInfo = cachedTrack
        artistInfo = cachedArtist
        albumInfo = cachedAlbum
        isLoading = false
    }

    private func albumTitle(for trackID: Int64?) async -> String? {
        guard let trackID else { return nil }
        let record = try? await environment.database.writer.read { db in
            try TrackRecord.filter(sql: "id = ?", arguments: [trackID]).fetchOne(db)
        }
        return record?.albumTitle
    }

    private func retry() async {
        guard settings.onlineDataEnabled else { return }
        isLoading = true
        let track = environment.player.currentTrack
        let title = track?.title ?? ""
        let artist = track?.artist ?? ""
        let album = await albumTitle(for: track?.trackID) ?? ""
        let info = environment.infoService
        if !title.isEmpty { trackInfo = await info.trackInfo(title: title, artist: artist, mbid: nil) }
        if !artist.isEmpty { artistInfo = await info.artistInfo(name: artist, mbid: nil) }
        if !album.isEmpty { albumInfo = await info.albumInfo(title: album, artist: artist, mbid: nil) }
        isLoading = false
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }
}

#Preview {
    InfoPanelView()
        .environment(AppEnvironment.preview())
        .environment(AppSettings.preview)
        .designTokens(.standard)
        .frame(width: 320, height: 480)
}
