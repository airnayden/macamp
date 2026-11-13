// VisualizerSheet — the iOS visualizer sheet, bound to `VisualizerViewModel`.
//
// Hosts the Metal visualizer surface (``MetalVisualizerView``) edge-to-edge with
// an auto-hiding glass mode switcher (bars / oscilloscope / particles / aurora).
// iOS ships Metal modes ONLY — projectM is macOS-only. Frames are PULLED on the
// render cadence; nothing is pushed from the audio thread, and the GPU pauses
// whenever the sheet is dismissed or the app deactivates.
import DesignSystem
import SwiftUI
import ViewModels
import Visualizer

/// The visualizer surface plus its mode switcher, presented as a sheet.
struct VisualizerSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var model: VisualizerViewModel {
        environment.visualizer
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                stageBackground
                MetalVisualizerView(
                    model: model,
                    mode: model.mode,
                    accent: accentSIMD,
                    background: backgroundSIMD,
                    appActive: scenePhase == .active,
                    reduceMotion: reduceMotion
                )
                .ignoresSafeArea(edges: .bottom)
                modeSwitcher
            }
            .navigationTitle(Text(MacAMPStrings.visualizerTitle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(tokens.colors.canvas.dark.color, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { doneButton }
            }
        }
    }
}

// MARK: - Controls

private extension VisualizerSheet {
    var modeSwitcher: some View {
        HStack(spacing: tokens.spacing.xSmall) {
            ForEach(VisualizerMode.allCases, id: \.self) { mode in
                modeButton(mode)
            }
        }
        .padding(tokens.spacing.small)
        .background(.regularMaterial, in: Capsule())
        .padding(.bottom, tokens.spacing.xLarge)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(MacAMPStrings.visualizerModeLabel))
    }

    func modeButton(_ mode: VisualizerMode) -> some View {
        let isActive = model.mode == mode
        return Button {
            model.setMode(mode)
        } label: {
            Image(systemName: symbol(for: mode))
                .font(tokens.typography.headline.font)
                .frame(width: 46, height: 36)
                .foregroundStyle(activeTint(isActive))
                .background { if isActive { Capsule().fill(tokens.colors.accent.resolve(scheme)) } }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(MacAMPStrings.visualizerModeName(mode)))
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }

    var doneButton: some View {
        Button { dismiss() } label: {
            Text(MacAMPStrings.done)
        }
    }

    var stageBackground: some View {
        tokens.colors.canvas.value(for: .dark).color.ignoresSafeArea()
    }

    func activeTint(_ isActive: Bool) -> Color {
        isActive
            ? tokens.colors.onAccent.resolve(scheme)
            : tokens.colors.textSecondary.resolve(scheme)
    }

    var accentSIMD: SIMD4<Float> {
        tokens.colors.accent.value(for: scheme).simd4
    }

    var backgroundSIMD: SIMD4<Float> {
        tokens.colors.canvas.dark.simd4
    }

    func symbol(for mode: VisualizerMode) -> String {
        switch mode {
        case .bars: "waveform"
        case .oscilloscope: "waveform.path"
        case .particles: "sparkles"
        case .aurora: "sun.haze.fill"
        }
    }
}

#Preview {
    VisualizerSheet()
        .environment(AppEnvironment.preview())
        .designTokens(.standard)
}
