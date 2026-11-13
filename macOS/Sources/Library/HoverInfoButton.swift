import DesignSystem
import SwiftUI

/// A hoverable affordance that reveals an info glyph over its content while the
/// pointer is inside it, and runs `action` on tap.
///
/// It owns its own `isHovered` state, so revealing the glyph never re-evaluates
/// the parent view. That is the fix for the bug where the glyph only appeared
/// after a detail sheet had been opened once: when the hover flag lived on the
/// same view as the `.sheet`, every hover re-ran the parent `body` and tore down
/// the macOS tracking area until the first sheet presentation forced a stable
/// layout. Isolating the flag here keeps hover independent of sheet state.
struct HoverInfoButton<Content: View>: View {
    private let icon: String
    private let font: Font
    private let color: Color
    private let alignment: Alignment
    private let shadowRadius: CGFloat
    private let help: LocalizedStringResource
    private let action: () -> Void
    private let content: Content

    @Environment(\.designTokens) private var tokens
    @State private var isHovered = false

    init(
        icon: String = "info.circle.fill",
        font: Font = .title2,
        color: Color,
        alignment: Alignment = .bottomTrailing,
        shadowRadius: CGFloat = 4,
        help: LocalizedStringResource,
        action: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.icon = icon
        self.font = font
        self.color = color
        self.alignment = alignment
        self.shadowRadius = shadowRadius
        self.help = help
        self.action = action
        self.content = content()
    }

    var body: some View {
        content
            .overlay(alignment: alignment) {
                if isHovered {
                    Image(systemName: icon)
                        .font(font)
                        .foregroundStyle(color)
                        .shadow(radius: shadowRadius)
                        .padding(tokens.spacing.small)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .onTapGesture(perform: action)
            .help(Text(help))
            .pointingHandCursor()
            .animation(.easeInOut(duration: 0.12), value: isHovered)
    }
}
