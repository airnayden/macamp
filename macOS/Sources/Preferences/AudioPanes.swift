// AudioPanes — the Playback, Equalizer and Visualizer preferences panes.
//
// These panes own audio-related launch defaults in the shared `AppSettings` store
// and mirror each change into the live `AppEnvironment` view models so the user
// hears/sees the choice immediately. ReplayGain/visualizer/EQ copy resolves through
// `PreferencesStrings` and `VisualizerStrings`.
import DesignSystem
import Persistence
import Services
import SwiftUI
import ViewModels
import Visualizer

// MARK: - Playback

/// ReplayGain default and gapless playback.
struct PlaybackPreferencesPane: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        @Bindable var settings = settings
        PreferencePane(
            icon: "play.circle",
            title: PreferencesStrings.tabPlayback,
            subtitle: PreferencesStrings.playbackSubtitle
        ) {
            Section {
                Picker(selection: $settings.replayGainMode) {
                    Text(PreferencesStrings.replayGainOff).tag(ReplayGainMode.off)
                    Text(PreferencesStrings.replayGainTrack).tag(ReplayGainMode.track)
                    Text(PreferencesStrings.replayGainAlbum).tag(ReplayGainMode.album)
                } label: {
                    Text(PreferencesStrings.replayGain)
                }
                PreferenceCaption(text: PreferencesStrings.replayGainCaption)
            }
            Section {
                Toggle(isOn: $settings.gaplessEnabled) {
                    Text(PreferencesStrings.gapless)
                }
                PreferenceCaption(text: PreferencesStrings.gaplessCaption)
            }
            LoudnessSettingsSection()
            CrossfeedSettingsSection(model: environment.crossfeed)
        }
        .onChange(of: settings.replayGainMode) { _, mode in
            environment.equalizer.setReplayGainMode(mode)
        }
    }
}

// MARK: - Equalizer

/// The EQ preset applied at launch (built-ins + persisted custom presets).
struct EQPreferencesPane: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        @Bindable var settings = settings
        PreferencePane(
            icon: "slider.vertical.3",
            title: PreferencesStrings.tabEqualizer,
            subtitle: PreferencesStrings.equalizerSubtitle
        ) {
            Section {
                Picker(selection: $settings.defaultEQPresetName) {
                    ForEach(environment.equalizer.presets, id: \.name) { preset in
                        Text(verbatim: preset.name).tag(preset.name)
                    }
                } label: {
                    Text(PreferencesStrings.defaultPreset)
                }
                PreferenceCaption(text: PreferencesStrings.defaultPresetCaption)
            }
            Section {
                ParametricEQModePicker(
                    model: environment.parametricEqualizer,
                    identifier: "preferences.eq.modeToggle"
                )
                PreferenceCaption(text: ParametricEQStrings.modeCaption)
            }
            Section {
                ParametricEQEditor(model: environment.parametricEqualizer)
            }
        }
        .task {
            if environment.equalizer.presets.isEmpty {
                environment.equalizer.loadPresets()
            }
        }
        .onChange(of: settings.defaultEQPresetName) { _, name in
            environment.equalizer.applyPreset(named: name)
        }
    }
}

// MARK: - Visualizer

/// The visualizer mode shown when the visualizer first opens.
struct VisualizerPreferencesPane: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        @Bindable var settings = settings
        PreferencePane(
            icon: "waveform",
            title: PreferencesStrings.tabVisualizer,
            subtitle: PreferencesStrings.visualizerSubtitle
        ) {
            Section {
                Toggle(isOn: $settings.showVisualizer) {
                    Text(PreferencesStrings.showVisualizer)
                }
                PreferenceCaption(text: PreferencesStrings.showVisualizerCaption)
            }
            Section {
                Picker(selection: $settings.defaultVisualizerMode) {
                    ForEach(VisualizerMode.allCases, id: \.self) { mode in
                        Text(VisualizerStrings.modeName(mode)).tag(mode)
                    }
                } label: {
                    Text(PreferencesStrings.defaultMode)
                }
                PreferenceCaption(text: PreferencesStrings.defaultModeCaption)
            }
        }
        .onChange(of: settings.defaultVisualizerMode) { _, mode in
            environment.visualizer.setMode(mode)
        }
    }
}

#Preview("Playback") {
    PlaybackPreferencesPane()
        .environment(AppEnvironment.preview())
        .environment(AppSettings.preview)
        .designTokens(.standard)
}

#Preview("Equalizer") {
    EQPreferencesPane()
        .environment(AppEnvironment.preview())
        .environment(AppSettings.preview)
        .designTokens(.standard)
}

#Preview("Visualizer") {
    VisualizerPreferencesPane()
        .environment(AppEnvironment.preview())
        .environment(AppSettings.preview)
        .designTokens(.standard)
}
