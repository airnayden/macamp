// PlayerBarTransport — the centered transport cluster of the player bar.
//
// Shuffle / previous / play-pause / next / repeat, all forwarding to the live
// `PlayerViewModel`. Stateless: it reads and mutates `environment.player` only,
// so it re-renders on playback-state changes (play / pause, shuffle, repeat) but
// never on the 0.5 s progress ticker. The art-derived accent flows into every
// `TransportButton` and the repeat badge from the parent bar's `\.albumTheme`
// environment.
import DesignSystem
import Services
import SwiftUI

struct PlayerBarTransport: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(PlayIntent.self) private var playIntent
    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: tokens.spacing.small) {
            TransportButton(
                .shuffle,
                size: .small,
                isActive: environment.player.shuffle,
                helpText: MacAMPStrings.helpShuffle
            ) {
                environment.player.setShuffle(!environment.player.shuffle)
            }
            .pointingHandCursor()
            TransportButton(
                .previous,
                size: .small,
                helpText: MacAMPStrings.helpPrevious,
                action: environment.player.previous
            )
            .pointingHandCursor()
            TransportButton(
                environment.player.isPlaying ? .pause : .play,
                prominence: .prominent,
                size: .medium,
                helpText: environment.player.isPlaying ? MacAMPStrings.helpPause : MacAMPStrings.helpPlay
            ) {
                if environment.player.currentTrack == nil {
                    playIntent.requestIdlePlay()
                } else {
                    environment.player.togglePlayPause()
                }
            }
            .pointingHandCursor()
            TransportButton(
                .next,
                size: .small,
                helpText: MacAMPStrings.helpNext,
                action: environment.player.next
            )
            .pointingHandCursor()
            repeatButton
            // Reads karaoke state internally (and self-hides when off) so this
            // cluster never re-renders on karaoke updates (UI-performance rule 3).
            KaraokeButton()
        }
    }

    private var repeatButton: some View {
        TransportButton(
            .repeatMode,
            size: .small,
            isActive: environment.player.repeatMode != .off,
            helpText: MacAMPStrings.helpRepeat,
            action: cycleRepeat
        )
        .overlay(alignment: .topTrailing) {
            if environment.player.repeatMode == .one {
                Text(verbatim: "1")
                    .font(tokens.typography.caption.font)
                    .foregroundStyle(tokens.colors.accent.resolve(scheme))
                    .padding(tokens.spacing.xxSmall)
            }
        }
        .pointingHandCursor()
    }

    private func cycleRepeat() {
        let next: RepeatMode = switch environment.player.repeatMode {
        case .off: .all
        case .all: .one
        case .one: .off
        }
        environment.player.setRepeatMode(next)
    }
}
