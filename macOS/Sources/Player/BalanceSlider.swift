import DesignSystem
import SwiftUI

struct BalanceSlider: View {
    @Binding var value: Double

    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    private let trackHeight: CGFloat = 4
    private let thumbDiameter: CGFloat = 14

    @State private var localDragValue: Double?

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let display = localDragValue ?? value
            let clamped = max(0, min(1, display))
            let thumbCenter = thumbDiameter / 2 + (width - thumbDiameter) * clamped
            let center = width / 2

            ZStack {
                Capsule(style: .continuous)
                    .fill(tokens.colors.separator.resolve(scheme))
                    .frame(height: trackHeight)

                let fillStart = min(thumbCenter, center)
                let fillWidth = abs(thumbCenter - center)
                Capsule(style: .continuous)
                    .fill(tokens.colors.accent.resolve(scheme))
                    .frame(width: max(2, fillWidth), height: trackHeight)
                    .position(x: fillStart + fillWidth / 2, y: thumbDiameter / 2)

                Rectangle()
                    .fill(tokens.colors.textTertiary.resolve(scheme))
                    .frame(width: 1, height: trackHeight + 4)
                    .position(x: center, y: thumbDiameter / 2)

                Circle()
                    .fill(tokens.colors.accent.resolve(scheme))
                    .frame(width: thumbDiameter, height: thumbDiameter)
                    .position(x: thumbCenter, y: thumbDiameter / 2)
                    .allowsHitTesting(false)
            }
            .frame(height: thumbDiameter)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
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
                    }
            )
            .onTapGesture(count: 2) {
                value = 0.5
            }
            .animation(nil, value: clamped)
        }
        .frame(height: thumbDiameter)
        .help(Text(DesignSystemStrings.balanceLabel))
    }
}
