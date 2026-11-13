// SynthwaveEmptyBackground — the house treatment for empty/placeholder panes.
//
// A calm, token-derived synthwave haze that echoes the launch `SplashView`
// without its full key art: a pink → purple "horizon" glow rising from the
// bottom edge plus a cyan neon wash in the top-trailing corner, all floated over
// the panel's own `surface`. The purple core comes from `tokens.colors.accent`, so
// it tracks the active theme; the pink and cyan neon ends are fixed `AdaptiveColor`
// stops (the retired `pink` / `cyan` palette accents, pinned here when MacAMP
// collapsed to a single skin) and still adapt per `colorScheme`. The glow is
// deliberately gentle so the centered
// `StateView` title, message and call-to-action stay legible on top.
import DesignSystem
import SwiftUI

/// A token-derived synthwave gradient backdrop for empty states.
struct SynthwaveBackdrop: View {
    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let pink = AdaptiveColor(light: ColorValue(hex: 0xD63062), dark: ColorValue(hex: 0xFF375F))
            .resolve(scheme)
        let cyan = AdaptiveColor(light: ColorValue(hex: 0x0091D9), dark: ColorValue(hex: 0x64D2FF))
            .resolve(scheme)
        let purple = tokens.colors.accent.resolve(scheme)
        ZStack {
            tokens.colors.surface.resolve(scheme)
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.0),
                    .init(color: purple.opacity(glow * 0.45), location: 0.62),
                    .init(color: pink.opacity(glow), location: 1.0),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            RadialGradient(
                colors: [cyan.opacity(glow * 0.6), .clear],
                center: UnitPoint(x: 0.82, y: 0.14),
                startRadius: 0,
                endRadius: 340
            )
        }
    }

    /// Peak neon opacity — bolder in the dark, restrained in the light so the
    /// haze never muddies a bright panel.
    private var glow: Double {
        scheme == .dark ? 0.26 : 0.14
    }
}

extension View {
    /// Fills the available space and paints the shared ``SynthwaveBackdrop``
    /// behind the receiver — the standard finish for empty/placeholder panes.
    func synthwaveEmptyBackground() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview("Empty state · Dark") {
    StateView.empty()
        .synthwaveEmptyBackground()
        .designTokens(.standard)
        .frame(width: 520, height: 420)
        .preferredColorScheme(.dark)
}

#Preview("Empty state · Light") {
    StateView.empty()
        .synthwaveEmptyBackground()
        .designTokens(.standard)
        .frame(width: 520, height: 420)
        .preferredColorScheme(.light)
}
