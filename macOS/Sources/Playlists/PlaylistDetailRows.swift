// PlaylistDetailRows — the header buttons and per-track row builders behind
// ``PlaylistDetailView``, plus the playing / favourite state helpers.
//
// Split out of the view file purely to keep each source under the SwiftLint
// file-length limit; the members are internal (not private) because the view's
// `trackRows` in the parent file (and the context menu sibling) invoke them.
// Toggling a favourite writes through ``TrackRepository`` off the main actor and
// mirrors the change in `favouriteOverrides` for instant feedback.
import DesignSystem
import Foundation
import Persistence
import SwiftUI

extension PlaylistDetailView {
    func playHeader(for tracks: [TrackRecord]) -> some View {
        HStack(spacing: tokens.spacing.medium) {
            headerButton(MacAMPStrings.playlistPlayAll, systemImage: "play.fill") {
                play(tracks, shuffled: false)
            }
            headerButton(MacAMPStrings.playlistShuffle, systemImage: "shuffle") {
                play(tracks, shuffled: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, tokens.spacing.large)
        .padding(.vertical, tokens.spacing.small)
    }

    func headerButton(
        _ title: LocalizedStringResource,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: tokens.spacing.xSmall) {
                Image(systemName: systemImage)
                Text(title)
            }
            .font(tokens.typography.headline.font)
            .foregroundStyle(tokens.colors.onAccent.resolve(scheme))
            .padding(.horizontal, tokens.spacing.medium)
            .padding(.vertical, tokens.spacing.small)
            .background(Capsule(style: .continuous).fill(tokens.colors.accent.resolve(scheme)))
        }
        .buttonStyle(.plain)
    }

    func rowView(_ row: PlaylistDetailRow) -> some View {
        TrackListRow(
            number: row.position,
            title: row.track.title ?? row.track.filePath,
            artist: row.track.artistName,
            artistId: row.track.artistId,
            duration: row.track.duration,
            isPlaying: isPlaying(row.track),
            availability: row.track.availability,
            isFavourite: isFavourite(row.track),
            onToggleFavourite: { toggleFavourite(row.track) },
            karaokeState: environment.karaokeRowState(
                filePath: row.track.filePath,
                enabled: settings.karaokeEnabled
            ),
            onRequestKaraokeRender: environment.karaokeRenderAction(
                filePath: row.track.filePath,
                enabled: settings.karaokeEnabled
            ),
            onDequeueKaraoke: environment.karaokeDequeueAction(
                filePath: row.track.filePath,
                enabled: settings.karaokeEnabled
            )
        )
    }

    func isPlaying(_ track: TrackRecord) -> Bool {
        guard let trackID = track.id else { return false }
        return trackID == environment.player.currentTrack?.trackID
    }

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
