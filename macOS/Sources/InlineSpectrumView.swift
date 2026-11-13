// InlineSpectrumHost — SwiftUI entry point for the compact player-bar /
// now-playing spectrum.
//
// Bridges to the plain-AppKit ``InlineSpectrumNSView``: the previous SwiftUI
// `TimelineView` implementation re-entered the window's layout AND constraint
// passes on every 30 fps tick (full window sizeThatFits — ~20% of a core while
// playing), which made pane and overlay animations stutter during playback.
// See the rationale in `InlineSpectrumNSView.swift` before converting this
// back to SwiftUI.
//
// Each instance drives its own redraw timer and samples the spectrum SOURCE
// directly (`VisualizerViewModel.sample()`), so two on-screen instances animate
// independently. Only `VisualizerViewModel.mode` is shared — the tap-to-cycle
// gesture intentionally switches every instance at once.
import AppKit
import DesignSystem
import SwiftUI
import ViewModels
import Visualizer

struct InlineSpectrumHost: NSViewRepresentable {
    @Environment(AppEnvironment.self) private var environment

    var forcePaused = false

    /// Redraw cadence; consumer-side pull rate only — never touches the
    /// audio-thread spectrum producer.
    var minimumInterval = 1.0 / 30.0

    func makeNSView(context _: Context) -> InlineSpectrumNSView {
        let view = InlineSpectrumNSView()
        let visualizer = environment.visualizer
        view.onTap = {
            let modes = VisualizerMode.allCases
            let currentIndex = modes.firstIndex(of: visualizer.mode) ?? 0
            visualizer.setMode(modes[(currentIndex + 1) % modes.count])
        }
        return view
    }

    func updateNSView(_ nsView: InlineSpectrumNSView, context _: Context) {
        nsView.visualizer = environment.visualizer
        nsView.minimumInterval = minimumInterval
        nsView.currentMode = environment.visualizer.mode
        nsView.isActive = environment.player.isPlaying && !forcePaused
    }

    func sizeThatFits(_: ProposedViewSize, nsView _: InlineSpectrumNSView, context _: Context) -> CGSize? {
        CGSize(width: 90, height: 36)
    }
}

#Preview {
    InlineSpectrumHost()
        .environment(AppEnvironment.preview())
        .designTokens(.standard)
        .frame(width: 120, height: 50)
        .padding()
}
