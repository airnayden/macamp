// VisualizerStrings — user-facing copy for the macOS visualizer host.
//
// Every label resolves through a `LocalizedStringResource` with an English
// `defaultValue`, so the running app and previews show real copy now and the
// dotted keys (`visualizer.<area>.<element>`) are the single handoff list for
// Task 44. The mode keys deliberately match `VisualizerMode.localizationKey`
// (`visualizer.mode.<rawValue>`). Renderer/brand names are non-translatable
// tokens rendered with `Text(verbatim:)` at the call site, never from here.
import Foundation
import Visualizer

/// Localized copy for the visualizer surface and its overlay controls.
enum VisualizerStrings {
    static let title = LocalizedStringResource(
        "visualizer.title",
        defaultValue: "Visualizer",
        comment: "Title of the audio visualizer surface"
    )
    static let modeLabel = LocalizedStringResource(
        "visualizer.mode.label",
        defaultValue: "Visual Mode",
        comment: "Accessibility label for the visualizer mode switcher"
    )
    static let rendererLabel = LocalizedStringResource(
        "visualizer.renderer.label",
        defaultValue: "Renderer",
        comment: "Label for the menu that picks the visualizer rendering backend"
    )
    static let enterFullScreen = LocalizedStringResource(
        "visualizer.action.enterFullScreen",
        defaultValue: "Enter Full Screen",
        comment: "Button that puts the visualizer window into native full screen"
    )
    static let exitFullScreen = LocalizedStringResource(
        "visualizer.action.exitFullScreen",
        defaultValue: "Exit Full Screen",
        comment: "Button that leaves native full screen"
    )
    static let fillWindow = LocalizedStringResource(
        "visualizer.action.fillWindow",
        defaultValue: "Fill Window",
        comment: "Button that expands the visualizer edge-to-edge within the window"
    )
    static let windowed = LocalizedStringResource(
        "visualizer.action.windowed",
        defaultValue: "Windowed",
        comment: "Button that insets the visualizer into a framed card"
    )
    static let idleMessage = LocalizedStringResource(
        "visualizer.idle.message",
        defaultValue: "Play a track to bring the visualizer to life",
        comment: "Hint shown over the visualizer when nothing is playing"
    )

    /// Localized display name for a visual mode. Keys match
    /// ``VisualizerMode/localizationKey``; the default values mirror the
    /// module's `fallbackDisplayName`.
    static func modeName(_ mode: VisualizerMode) -> LocalizedStringResource {
        switch mode {
        case .bars:
            LocalizedStringResource(
                "visualizer.mode.bars",
                defaultValue: "Spectrum Bars",
                comment: "Frequency-domain spectrum bars visual mode"
            )
        case .oscilloscope:
            LocalizedStringResource(
                "visualizer.mode.oscilloscope",
                defaultValue: "Oscilloscope",
                comment: "Time-domain waveform visual mode"
            )
        case .particles:
            LocalizedStringResource(
                "visualizer.mode.particles",
                defaultValue: "Particles",
                comment: "Spectrum-reactive particle field visual mode"
            )
        case .aurora:
            LocalizedStringResource(
                "visualizer.mode.aurora",
                defaultValue: "Aurora",
                comment: "Flowing aurora art visual mode"
            )
        }
    }
}
