import Foundation

/// Stable navigation identity, localized copy and SF Symbols for Settings.
enum PreferencesSection: String, CaseIterable, Identifiable {
    case general, library, downloads, playback, output, equalizer, visualizer
    case karaoke, intelligence, online, profiles, updates, acknowledgments

    var id: String {
        rawValue
    }

    var title: LocalizedStringResource {
        switch self {
        case .general: PreferencesStrings.tabGeneral
        case .library: PreferencesStrings.tabLibrary
        case .downloads: PreferencesStrings.tabDownloads
        case .playback: PreferencesStrings.tabPlayback
        case .output: PreferencesStrings.tabOutput
        case .equalizer: PreferencesStrings.tabEqualizer
        case .visualizer: PreferencesStrings.tabVisualizer
        case .karaoke: PreferencesStrings.tabKaraoke
        case .intelligence: PreferencesStrings.tabIntelligence
        case .online: PreferencesStrings.tabOnline
        case .profiles: ProfileStrings.preferencesTitle
        case .updates: PreferencesStrings.tabUpdates
        case .acknowledgments: PreferencesStrings.tabAcknowledgments
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .library: "folder"
        case .downloads: "arrow.down.circle"
        case .playback: "play.circle"
        case .output: "hifispeaker"
        case .equalizer: "slider.vertical.3"
        case .visualizer: "waveform"
        case .karaoke: "music.mic"
        case .intelligence: "sparkles"
        case .online: "globe"
        case .profiles: "person.crop.circle"
        case .updates: "arrow.triangle.2.circlepath"
        case .acknowledgments: "doc.text"
        }
    }
}
