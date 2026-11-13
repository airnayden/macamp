// EQOverlayView — the ten-band equalizer presented as a fading overlay over the
// main window (the EQ moved out of the right panel's tab strip; the toggle lives
// next to the volume/balance controls in the player bar). The presenting overlay
// in `MainWindowView` owns the full-window backdrop; this view is just the card.
import DesignSystem
import SwiftUI

struct EQOverlayView: View {
    @Binding var isPresented: Bool

    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    @FocusState private var hasKeyFocus: Bool

    var body: some View {
        VStack(spacing: tokens.spacing.small) {
            closeBar
            EQPanelView()
        }
        .padding(tokens.spacing.large)
        .frame(maxWidth: 640, maxHeight: 560)
        .background(
            RoundedRectangle(cornerRadius: tokens.radii.large, style: .continuous)
                .fill(tokens.colors.surfaceRaised.resolve(scheme))
                .shadow(color: .black.opacity(0.3), radius: 24, y: 10)
        )
        .padding(tokens.spacing.xLarge)
        // See `NowPlayingExpandedView`: Esc only reaches the FOCUSED view, and
        // `focusEffectDisabled` suppresses AppKit's animated focus ring.
        .focusable()
        .focusEffectDisabled()
        .focused($hasKeyFocus)
        .onExitCommand {
            withAnimation(.easeInOut(duration: 0.3)) { isPresented = false }
        }
        .onAppear { hasKeyFocus = true }
    }

    private var closeBar: some View {
        HStack {
            Spacer()
            Button {
                withAnimation(.easeInOut(duration: 0.3)) { isPresented = false }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
            }
            .buttonStyle(.plain)
            .help(Text(MacAMPStrings.playerClose))
            .accessibilityLabel(Text(MacAMPStrings.playerClose))
        }
    }
}

#Preview {
    EQOverlayView(isPresented: .constant(true))
        .environment(AppEnvironment.preview())
        .designTokens(.standard)
        .frame(width: 720, height: 620)
}
