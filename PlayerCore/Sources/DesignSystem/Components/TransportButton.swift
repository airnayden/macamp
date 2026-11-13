import SwiftUI

/// A playback transport control (play / pause / next / previous / stop / shuffle
/// / repeat).
///
/// Two prominences — `.prominent` (a filled accent disc, for the primary
/// play/pause) and `.standard` (a glyph with a subtle hover fill). The press
/// animation is suppressed under reduce-motion. Accessibility labels come from
/// ``DesignSystemStrings`` and SF Symbol glyphs are used for the icons.
public struct TransportButton: View {
    public enum Kind: Sendable {
        case play, pause, stop, next, previous, shuffle, repeatMode

        var systemImage: String {
            switch self {
            case .play: "play.fill"
            case .pause: "pause.fill"
            case .stop: "stop.fill"
            case .next: "forward.end.fill"
            case .previous: "backward.end.fill"
            case .shuffle: "shuffle"
            case .repeatMode: "repeat"
            }
        }

        var accessibilityLabel: LocalizedStringResource {
            switch self {
            case .play: DesignSystemStrings.transportPlay
            case .pause: DesignSystemStrings.transportPause
            case .stop: DesignSystemStrings.transportStop
            case .next: DesignSystemStrings.transportNext
            case .previous: DesignSystemStrings.transportPrevious
            case .shuffle: DesignSystemStrings.transportShuffle
            case .repeatMode: DesignSystemStrings.transportRepeat
            }
        }
    }

    public enum Prominence: Sendable { case standard, prominent }

    public enum Size: Sendable {
        case small, medium, large

        var diameter: CGFloat {
            switch self {
            case .small: 36
            case .medium: 52
            case .large: 68
            }
        }

        var glyphScale: CGFloat {
            switch self {
            case .small: 0.40
            case .medium: 0.42
            case .large: 0.44
            }
        }
    }

    private let kind: Kind
    private let prominence: Prominence
    private let size: Size
    private let isActive: Bool
    private let helpText: LocalizedStringResource?
    private let action: () -> Void

    public init(
        _ kind: Kind,
        prominence: Prominence = .standard,
        size: Size = .medium,
        isActive: Bool = false,
        helpText: LocalizedStringResource? = nil,
        action: @escaping () -> Void
    ) {
        self.kind = kind
        self.prominence = prominence
        self.size = size
        self.isActive = isActive
        self.helpText = helpText
        self.action = action
    }

    public var body: some View {
        let button = Button(action: action) {
            Image(systemName: kind.systemImage)
                .font(.system(size: size.diameter * size.glyphScale, weight: .semibold))
        }
        .buttonStyle(
            TransportButtonStyle(
                prominence: prominence,
                diameter: size.diameter,
                isActive: isActive
            )
        )
        .accessibilityLabel(Text(kind.accessibilityLabel))
        if let helpText {
            button.help(Text(helpText))
        } else {
            button
        }
    }
}

private struct TransportButtonStyle: ButtonStyle {
    let prominence: TransportButton.Prominence
    let diameter: CGFloat
    let isActive: Bool

    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme
    @Environment(\.themePresentation) private var presentation
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        return configuration.label
            .foregroundStyle(foreground)
            .frame(width: diameter, height: diameter)
            .background(background(pressed: pressed))
            .contentShape(Circle())
            .scaleEffect(presentation.reduceMotion ? 1 : (pressed ? 0.9 : 1))
            .animation(
                presentation.reduceMotion ? nil : .spring(duration: tokens.motion.quick),
                value: pressed
            )
            .onHover { isHovered = $0 }
    }

    private var foreground: Color {
        switch prominence {
        case .prominent:
            tokens.colors.onAccent.resolve(scheme)
        case .standard:
            if isActive {
                tokens.colors.accent.resolve(scheme)
            } else {
                tokens.colors.textPrimary.resolve(scheme)
            }
        }
    }

    @ViewBuilder
    private func background(pressed: Bool) -> some View {
        switch prominence {
        case .prominent:
            Circle()
                .fill(tokens.colors.accent.resolve(scheme))
                .shadow(for: pressed ? tokens.elevation.low : tokens.elevation.medium)
        case .standard:
            Circle()
                .fill(standardFill(pressed: pressed))
        }
    }

    private func standardFill(pressed: Bool) -> Color {
        if isActive {
            return tokens.colors.accentMuted.resolve(scheme)
        }
        if pressed {
            return tokens.colors.surfaceRaised.resolve(scheme)
        }
        if isHovered {
            return tokens.colors.surfaceRaised.resolve(scheme).opacity(0.6)
        }
        return tokens.colors.surface.resolve(scheme).opacity(0.001)
    }
}
