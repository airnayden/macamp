// MacAMPBackdrop — the faint synthwave splash art shown behind translucent
// content when the MacAMP skin is active. Shared by the main window and the
// expanded now-playing overlay so both surfaces carry the same wash.
//
// The wash is scheme-conditional. On a dark canvas the art reads as depth, so it
// carries its full weight; on the light canvas the same opacity tints the pale
// surfaces underneath and drags every label's contrast ratio down with it, so it
// is halved. Keep these two constants in step with the light-mode contrast floors
// asserted by `ContrastTests`.
import SwiftUI

struct MacAMPBackdrop: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.colorScheme) private var scheme

    private var splashOpacity: Double {
        scheme == .dark ? 0.12 : 0.06
    }

    var body: some View {
        if settings.themePreset == .macAMP {
            Image("Splash")
                .resizable()
                .aspectRatio(contentMode: .fill)
                .opacity(splashOpacity)
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .clipped()
        }
    }
}
