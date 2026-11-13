// OnlinePanes — the Online preferences pane.
//
// Controls what MacAMP fetches from the internet: song/artist/album info
// (MusicBrainz + Wikipedia) and lyrics (LRCLIB). Both default On and persist in
// the shared `AppSettings` store; the shell honors them at the fetch call sites
// (Info/Lyrics panels and the album/artist detail screens) rather than changing
// PlayerCore services. Copy resolves through `PreferencesStrings`.
import SwiftUI

// MARK: - Online

/// Toggles for internet-backed song/artist/album info and lyrics fetching.
struct OnlinePreferencesPane: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        PreferencePane(
            icon: "globe",
            title: PreferencesStrings.tabOnline,
            subtitle: PreferencesStrings.onlineSubtitle
        ) {
            Section {
                Toggle(isOn: $settings.onlineDataEnabled) {
                    Text(PreferencesStrings.onlineData)
                }
                PreferenceCaption(text: PreferencesStrings.onlineDataCaption)
            }
            Section {
                Toggle(isOn: $settings.onlineLyricsEnabled) {
                    Text(PreferencesStrings.onlineLyrics)
                }
                PreferenceCaption(text: PreferencesStrings.onlineLyricsCaption)
            }
        }
    }
}

#Preview("Online") {
    OnlinePreferencesPane()
        .environment(AppEnvironment.preview())
        .environment(AppSettings.preview)
        .designTokens(.standard)
}
