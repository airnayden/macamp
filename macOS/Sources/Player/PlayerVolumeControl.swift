import DesignSystem
import SwiftUI

/// The trailing-edge output controls of the player bar: a volume fader over a
/// stereo-balance fader, both bound to the live `PlayerViewModel`.
struct PlayerVolumeControl: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(AppSettings.self) private var settings
    @Environment(NavigationModel.self) private var nav
    @Environment(\.colorScheme) private var scheme
    @State private var balanceResetTick: UInt64 = 0
    @State private var volumeTick: UInt64 = 0

    private var tokens: DesignTokens {
        settings.designTokens
    }

    var body: some View {
        HStack(spacing: tokens.spacing.medium) {
            Spacer(minLength: 0)
            equalizerButton
            VStack(spacing: tokens.spacing.xxSmall) {
                volumeRow
                balanceRow
            }
            .font(tokens.typography.caption.font)
            .frame(maxWidth: 160)
        }
    }

    private var equalizerButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.3)) { nav.showEQOverlay.toggle() }
        } label: {
            Image(systemName: "slider.vertical.3")
                .resizable()
                .scaledToFit()
                .frame(height: 20)
                .foregroundStyle(
                    nav.showEQOverlay
                        ? tokens.colors.accent.resolve(scheme)
                        : tokens.colors.textTertiary.resolve(scheme)
                )
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .help(Text(MacAMPStrings.helpEqualizer))
        .accessibilityLabel(Text(MacAMPStrings.helpEqualizer))
        .accessibilityIdentifier("player.eqToggle")
    }

    private var volumeRow: some View {
        HStack(spacing: tokens.spacing.xSmall) {
            Button { volumeValue = 0 } label: {
                Image(systemName: "speaker.fill")
                    .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            PlayerSlider(value: volumeBinding, label: DesignSystemStrings.volumeLabel)
                .designTokens(tokens)
            Button { volumeValue = 1 } label: {
                Image(systemName: "speaker.wave.3.fill")
                    .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
        }
    }

    private var balanceRow: some View {
        HStack(spacing: tokens.spacing.xSmall) {
            Button { balanceValue = 0 } label: {
                Text(verbatim: "L")
                    .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
                    .frame(width: 14)
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            BalanceSlider(value: balanceBinding)
                .designTokens(tokens)
            Button { balanceValue = 1 } label: {
                Text(verbatim: "R")
                    .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
                    .frame(width: 14)
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            Button {
                environment.player.setBalance(0)
                balanceResetTick &+= 1
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 9))
                    .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help(Text(MacAMPStrings.resetBalance))
            .accessibilityLabel(Text(MacAMPStrings.resetBalance))
            .accessibilityIdentifier("player.balanceReset")
        }
    }

    private var volumeValue: Double {
        get { Double(environment.player.volume) }
        nonmutating set {
            environment.player.setVolume(Float(newValue))
            volumeTick &+= 1
        }
    }

    private var balanceValue: Double {
        get { Double((environment.player.balance + 1) / 2) }
        nonmutating set {
            environment.player.setBalance(Float(newValue * 2 - 1))
            balanceResetTick &+= 1
        }
    }

    private var volumeBinding: Binding<Double> {
        _ = volumeTick
        return Binding(
            get: { Double(environment.player.volume) },
            set: { environment.player.setVolume(Float($0)) }
        )
    }

    private var balanceBinding: Binding<Double> {
        _ = balanceResetTick
        return Binding(
            get: { Double((environment.player.balance + 1) / 2) },
            set: { environment.player.setBalance(Float($0 * 2 - 1)) }
        )
    }
}
