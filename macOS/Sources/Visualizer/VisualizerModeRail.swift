// VisualizerModeRail — the visualizer's sliding-pill mode switcher.
//
// A bespoke segmented control: one glyph per `VisualizerMode` with an accent pill
// that glides to the selection (the glide is suppressed under reduce-motion).
// Extracted from `VisualizerHostView` to keep that file within the SwiftLint
// file-length budget; both live in the macampMac app module and share the
// internal `VisualizerMetric` hit-area constants.
import DesignSystem
import SwiftUI
import ViewModels
import Visualizer

/// A bespoke segmented mode switcher: a glyph per ``VisualizerMode`` with a
/// sliding accent pill marking the selection. The glide is suppressed under
/// reduce-motion (the pill jumps instantly).
struct VisualizerModeRail: View {
    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var pill

    let selection: VisualizerMode
    let onSelect: (VisualizerMode) -> Void

    var body: some View {
        HStack(spacing: tokens.spacing.xxSmall) {
            ForEach(VisualizerMode.allCases, id: \.self) { mode in
                segment(mode)
            }
        }
        .padding(tokens.spacing.xxSmall)
        .background(Capsule(style: .continuous).fill(tokens.colors.separator.resolve(scheme)))
        .animation(reduceMotion ? nil : .spring(duration: tokens.motion.standard), value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(VisualizerStrings.modeLabel))
    }

    private func segment(_ mode: VisualizerMode) -> some View {
        let isActive = selection == mode
        return Button {
            onSelect(mode)
        } label: {
            Image(systemName: symbol(for: mode))
                .font(tokens.typography.headline.font)
                .foregroundStyle(isActive
                    ? tokens.colors.onAccent.resolve(scheme)
                    : tokens.colors.textSecondary.resolve(scheme))
                .frame(width: VisualizerMetric.segmentWidth, height: VisualizerMetric.segmentHeight)
                .background(pillBackground(isActive: isActive))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(Text(VisualizerStrings.modeName(mode)))
        .accessibilityLabel(Text(VisualizerStrings.modeName(mode)))
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private func pillBackground(isActive: Bool) -> some View {
        if isActive {
            Capsule(style: .continuous)
                .fill(tokens.colors.accent.resolve(scheme))
                .matchedGeometryEffect(id: "modePill", in: pill)
                .shadowToken(tokens.elevation.low)
        }
    }

    private func symbol(for mode: VisualizerMode) -> String {
        switch mode {
        case .bars: "waveform"
        case .oscilloscope: "waveform.path"
        case .particles: "sparkles"
        case .aurora: "sun.haze.fill"
        }
    }
}
