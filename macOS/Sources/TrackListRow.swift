// TrackListRow — the one track row shared by every macOS list surface.
//
// The folder browser, playlist detail, favourites and the play queue all render a
// structurally identical row: a leading now-playing speaker / ordinal, a title +
// artist stack, an optional availability badge, an optional duration, and an
// optional favourite toggle. Extracting it here removes four near-duplicate row
// builders and gives the now-playing indicator (Fix 3) a single home so it shows
// consistently — and updates the moment next/previous changes the current track.
//
// The row is just CONTENT: callers own row-level behaviour (selection `tag`,
// double-click, context menu, hover) by applying their own modifiers, so it drops
// cleanly into any `List`. `title`/`artist` are track *data*, not UI copy, so they
// render verbatim; every colour, font and spacing value comes from design tokens.
import DesignSystem
import Persistence
import SwiftUI

/// A unified, reusable track row for the folder, playlist, favourites and queue
/// lists. Pass primitive values so it stays agnostic of `TrackRecord` / `TrackRef`.
struct TrackListRow: View {
    /// Ordinal in the leading slot (track number / playlist position / queue index).
    /// A value `<= 0` renders no number — e.g. a folder track with no track tag.
    let number: Int
    /// Track title (user data — rendered verbatim).
    let title: String
    /// Track artist (user data — rendered verbatim); hidden when nil/empty.
    let artist: String?
    var artistId: Int64?
    /// Duration in seconds; `nil` hides the duration label (e.g. the queue).
    let duration: TimeInterval?
    /// `true` when this row is the track currently loaded in the transport.
    let isPlaying: Bool
    /// Backing-file availability; `.present` shows no badge.
    let availability: Availability
    /// Current favourite state; `nil` hides the favourite toggle (e.g. the queue).
    var isFavourite: Bool?
    /// Invoked when the favourite toggle is tapped (ignored when `isFavourite` is nil).
    var onToggleFavourite: (() -> Void)?
    /// Karaoke accessory: `.ready` shows an instrumental-ready glyph,
    /// `.rendering(fraction)` a progress ring, `nil` nothing. Computed by the PARENT
    /// view (which owns the `KaraokeReadyStore` lookups) and passed down as a plain
    /// value, so the row stays O(1) — it never reads the environment at 100k-row scale.
    var karaokeState: TrackRowKaraokeState?
    /// Schedules an on-demand karaoke render for this track. When non-nil a small
    /// `mic.badge.plus` button shows in the accessory area so the user can queue a
    /// render without playing the track; `nil` hides it. Like every input, the PARENT
    /// supplies this (only for renderable tracks) as a plain closure — the row never
    /// reads the environment.
    var onRequestKaraokeRender: (() -> Void)?
    /// Shows a waveform badge marking the track's cached lyrics as time-synced.
    /// Resolved by the PARENT (only the Lyrics browser knows), like every input here.
    var isLyricsSynced = false
    /// Removes this track from the karaoke render queue. When non-nil (the PARENT
    /// supplies it only for a `.queued` pending item) the karaoke accessory's clock
    /// becomes a button so the user can drop a pending render straight from the list;
    /// `nil` leaves the badge non-interactive. Another plain closure — the row never
    /// reads the environment.
    var onDequeueKaraoke: (() -> Void)?

    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: tokens.spacing.small) {
            leading
                .frame(width: 24, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                    .font(tokens.typography.body.font)
                    .foregroundStyle(titleColor)
                    .lineLimit(1)
                if let artist, !artist.isEmpty {
                    ArtistLink(name: artist, artistId: artistId)
                        .font(tokens.typography.caption.font)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: tokens.spacing.small)
            badge
            if isLyricsSynced {
                Image(systemName: "waveform")
                    .font(tokens.typography.caption.font)
                    .foregroundStyle(tokens.colors.accent.resolve(scheme))
                    .accessibilityLabel(Text(MacAMPStrings.lyricsBrowserSyncedBadge))
            }
            if let karaokeState {
                KaraokeBadge(state: karaokeState, onDequeue: onDequeueKaraoke)
            }
            if let onRequestKaraokeRender {
                KaraokeRenderButton(action: onRequestKaraokeRender)
            }
            if let duration {
                Text(verbatim: Self.durationText(duration))
                    .font(tokens.typography.timecode.font)
                    .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
            }
            if let isFavourite, let onToggleFavourite {
                FavouriteButton(isFavourite: isFavourite, action: onToggleFavourite)
            }
        }
        .padding(.vertical, tokens.spacing.xxSmall)
        .opacity(availability == .present ? 1 : 0.55)
    }

    private var titleColor: Color {
        isPlaying
            ? tokens.colors.accent.resolve(scheme)
            : tokens.colors.textPrimary.resolve(scheme)
    }

    @ViewBuilder
    private var leading: some View {
        if isPlaying {
            Image(systemName: "speaker.wave.2.fill")
                .font(tokens.typography.caption.font)
                .foregroundStyle(tokens.colors.accent.resolve(scheme))
                .accessibilityLabel(Text(MacAMPStrings.nowPlayingIndicator))
        } else if number > 0 {
            Text(verbatim: "\(number)")
                .font(tokens.typography.timecode.font)
                .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private var badge: some View {
        switch availability {
        case .present:
            EmptyView()
        case .missing:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(tokens.colors.warning.resolve(scheme))
                .accessibilityLabel(Text(MacAMPStrings.badgeMissing))
        case .externalOffline:
            Image(systemName: "externaldrive.badge.xmark")
                .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
                .accessibilityLabel(Text(MacAMPStrings.badgeOffline))
        }
    }

    /// Formats a second count as `m:ss` (matching the previous per-view formatters).
    static func durationText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

#Preview {
    List {
        trackListRowPreview(1, "Now Playing Track", playing: true, availability: .present)
        trackListRowPreview(2, "Another Track", playing: false, availability: .present)
        trackListRowPreview(3, "Missing Track", playing: false, availability: .missing)
        trackListRowPreview(4, "Karaoke Ready", playing: false, availability: .present, karaoke: .ready)
        trackListRowPreview(5, "Karaoke Rendering", playing: false, availability: .present, karaoke: .rendering(0.4))
        trackListRowPreview(6, "Karaoke Renderable", playing: false, availability: .present, onRender: {})
    }
    .designTokens(.standard)
    .frame(width: 360, height: 360)
}

private func trackListRowPreview(
    _ number: Int,
    _ title: String,
    playing: Bool,
    availability: Availability,
    karaoke: TrackRowKaraokeState? = nil,
    onRender: (@Sendable () -> Void)? = nil
) -> some View {
    TrackListRow(
        number: number,
        title: title,
        artist: "Preview Artist",
        duration: 222,
        isPlaying: playing,
        availability: availability,
        isFavourite: !playing,
        onToggleFavourite: {},
        karaokeState: karaoke,
        onRequestKaraokeRender: onRender
    )
}
