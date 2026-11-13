// VerticalGainSlider — one vertical, center-detented fader for an EQ band.
//
// The fill grows from the 0 dB midline toward the thumb, mirroring a hardware
// graphic-EQ. Token-styled (track = separator, fill + thumb = accent), so it
// inherits the album-art accent automatically. The thumb's press spring and the
// settle animation when a preset moves the band are both suppressed under
// reduce-motion. Fully accessible: an adjustable element with a dB value.
import DesignSystem
import SwiftUI

/// A vertical gain fader bound to a single EQ band's dB value.
struct VerticalGainSlider: View {
    @Binding var gain: Double
    let range: ClosedRange<Double>

    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme
    @Environment(\.themePresentation) private var presentation

    @State private var isDragging = false

    private let trackWidth: CGFloat = 5
    private let thumbDiameter: CGFloat = 16

    var body: some View {
        GeometryReader { proxy in
            fader(in: proxy.size.height)
        }
        .frame(minWidth: thumbDiameter + 8)
        .accessibilityElement()
        .accessibilityValue(Text(verbatim: gainText))
        .accessibilityAdjustableAction(adjust)
    }

    private func fader(in height: CGFloat) -> some View {
        let usable = max(1, height - thumbDiameter)
        let valueY = thumbDiameter / 2 + offset(forFraction: fraction(gain), usable: usable)
        let midY = thumbDiameter / 2 + offset(forFraction: fraction(0), usable: usable)

        return ZStack(alignment: .top) {
            Capsule(style: .continuous)
                .fill(tokens.colors.separator.resolve(scheme))
                .frame(width: trackWidth, height: height)
                .frame(maxWidth: .infinity)

            Capsule(style: .continuous)
                .fill(tokens.colors.accent.resolve(scheme))
                .frame(width: trackWidth, height: abs(valueY - midY))
                .frame(maxWidth: .infinity, alignment: .top)
                .offset(y: min(valueY, midY))

            thumb
                .frame(maxWidth: .infinity)
                .offset(y: valueY - thumbDiameter / 2)
        }
        .frame(height: height)
        .contentShape(Rectangle())
        .animation(settleAnimation, value: gain)
        .gesture(drag(height: height))
    }

    private var thumb: some View {
        Circle()
            .fill(tokens.colors.accent.resolve(scheme))
            .overlay(
                Circle().strokeBorder(
                    tokens.colors.onAccent.resolve(scheme).opacity(0.85),
                    lineWidth: 2
                )
            )
            .frame(width: thumbDiameter, height: thumbDiameter)
            .shadowToken(tokens.elevation.low)
            .scaleEffect(isDragging && !presentation.reduceMotion ? 1.15 : 1)
            .animation(
                presentation.reduceMotion ? nil : .spring(duration: tokens.motion.quick),
                value: isDragging
            )
    }
}

private extension VerticalGainSlider {
    /// Normalized 0…1 position (0 = bottom, 1 = top) for a dB value.
    func fraction(_ value: Double) -> Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0.5 }
        let raw = (value - range.lowerBound) / span
        return min(1, max(0, raw))
    }

    /// Vertical offset (from the top) for a normalized fraction. Top = max gain.
    func offset(forFraction value: Double, usable: CGFloat) -> CGFloat {
        (1 - value) * usable
    }

    var settleAnimation: Animation? {
        if isDragging || presentation.reduceMotion { return nil }
        return .easeOut(duration: tokens.motion.standard)
    }

    var gainText: String {
        let value = Int(gain.rounded())
        return value > 0 ? "+\(value) dB" : "\(value) dB"
    }

    func drag(height: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                isDragging = true
                gain = value(atY: gesture.location.y, height: height)
            }
            .onEnded { _ in isDragging = false }
    }

    func value(atY pointY: CGFloat, height: CGFloat) -> Double {
        let usable = max(1, height - thumbDiameter)
        let clampedY = min(max(0, pointY - thumbDiameter / 2), usable)
        let fromTop = 1 - Double(clampedY / usable)
        let raw = range.lowerBound + fromTop * (range.upperBound - range.lowerBound)
        return raw.rounded()
    }

    func adjust(_ direction: AccessibilityAdjustmentDirection) {
        switch direction {
        case .increment: gain = min(range.upperBound, gain + 1)
        case .decrement: gain = max(range.lowerBound, gain - 1)
        @unknown default: break
        }
    }
}

#Preview("Vertical gain · Light") {
    GainSliderPreview()
        .preferredColorScheme(.light)
}

#Preview("Vertical gain · Dark") {
    GainSliderPreview()
        .preferredColorScheme(.dark)
}

private struct GainSliderPreview: View {
    @State private var gains: [Double] = [6, -3, 0, 4, -6]

    var body: some View {
        HStack(spacing: 20) {
            ForEach(gains.indices, id: \.self) { index in
                VerticalGainSlider(
                    gain: Binding(
                        get: { gains[index] },
                        set: { gains[index] = $0 }
                    ),
                    range: -12 ... 12
                )
                .frame(height: 200)
            }
        }
        .padding(32)
        .designTokens(.standard)
    }
}
