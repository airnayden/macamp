// MacAMPApp — the iOS / iPadOS entry point.
//
// Builds the single ``AppEnvironment`` composition root once (`live()`), creates
// the ``AppSettings`` preference store backed by the App Group `UserDefaults`
// suite, injects both into the SwiftUI environment, and presents the adaptive
// ``RootTabView``. Design tokens are wired from the user's ``ThemePreset``
// selection. The "MacAMP" brand is rendered with `Text(verbatim:)`, never
// localized.
//
// AVAudioSession activation is wired separately in Task 34 (``AudioSessionController``)
// — this entry point deliberately leaves that seam untouched.
import DesignSystem
import SwiftUI

@main
struct MacAMPApp: App {
    @State private var environment: AppEnvironment
    @State private var settings: AppSettings

    /// Both roots are built here rather than in property initialisers because the
    /// AI graph is gated on a preference: the environment has to see the settings
    /// store, and a `@State` initial value cannot reference a sibling `@State`.
    init() {
        let settings = AppSettings()
        let environment = AppEnvironment.live()
        environment.connectAI(settings: settings)
        _settings = State(initialValue: settings)
        _environment = State(initialValue: environment)
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(environment)
                .environment(settings)
                .designTokens(settings.designTokens)
                .preferredColorScheme(settings.appearance.colorScheme)
        }
    }
}
