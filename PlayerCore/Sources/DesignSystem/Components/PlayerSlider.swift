import SwiftUI

/// A custom seek / volume slider.
///
/// A rounded token-styled track with an accent fill and a draggable thumb. An
/// optional `buffered` value paints a secondary fill behind the accent (e.g. the
/// buffered range of a stream). Fully accessible: it is one adjustable element
/// with a localized label and a percentage value. The thumb's drag animation is
/// suppressed under reduce-motion.
public struct PlayerSlider: View {
    @Binding private var value: Double
    private let buffered: Double?
    private let label: LocalizedStringResource
    private let onEditingChanged: (Bool) -> Void

    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme
    @Environment(\.themePresentation) private var presentation

    @State private var isDragging = false

    public init(
        value: Binding<Double>,
        buffered: Double? = nil,
        label: LocalizedStringResource,
        onEditingChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        _value = value
        self.buffered = buffered
        self.label = label
        self.onEditingChanged = onEditingChanged
    }

    private let trackHeight: CGFloat = 6
    private let thumbDiameter: CGFloat = 18

    @State private var localDragValue: Double?

    public var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let clamped = (localDragValue ?? value).clampedUnit
            let thumbCenter = thumbDiameter / 2 + (width - thumbDiameter) * clamped
            let fillWidth = min(thumbCenter, width)

            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(tokens.colors.separator.resolve(scheme))
                    .frame(height: trackHeight)

                if let buffered {
                    Capsule(style: .continuous)
                        .fill(tokens.colors.textTertiary.resolve(scheme).opacity(0.5))
                        .frame(width: width * buffered.clampedUnit, height: trackHeight)
                }

                Capsule(style: .continuous)
                    .fill(tokens.colors.accent.resolve(scheme))
                    .frame(width: fillWidth, height: trackHeight)
            }
            .frame(height: thumbDiameter)
            .overlay {
                Circle()
                    .fill(tokens.colors.accent.resolve(scheme))
                    .overlay(
                        Circle().strokeBorder(
                            tokens.colors.onAccent.resolve(scheme).opacity(0.85),
                            lineWidth: 2
                        )
                    )
                    .frame(width: thumbDiameter, height: thumbDiameter)
                    .position(x: thumbCenter, y: thumbDiameter / 2)
                    .shadow(for: tokens.elevation.low)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if !isDragging {
                            isDragging = true
                            onEditingChanged(true)
                        }
                        let newValue = max(
                            0,
                            min(1, (gesture.location.x - thumbDiameter / 2) / max(width - thumbDiameter, 1))
                        )
                        localDragValue = newValue
                        value = newValue
                    }
                    .onEnded { _ in
                        if let drag = localDragValue { value = drag }
                        localDragValue = nil
                        isDragging = false
                        onEditingChanged(false)
                    }
            )
        }
        .frame(height: thumbDiameter)
        .accessibilityElement()
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(value.clampedUnit, format: .percent.precision(.fractionLength(0))))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = (value + 0.05).clampedUnit
            case .decrement: value = (value - 0.05).clampedUnit
            @unknown default: break
            }
        }
    }
}
