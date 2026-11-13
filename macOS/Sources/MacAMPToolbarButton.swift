// MacAMPToolbarButton — the macOS shell's standardized toolbar action button.
//
// One SF Symbol glyph (optionally paired with a label) that carries MacAMP's
// accent tint, reveals a soft accent-muted fill on hover, and shows a localized
// `.help()` tooltip. It replaces the ad-hoc `Button { } label: { Label/Image }`
// scattered across the window toolbars so every primary-action control shares one
// look, one hover model and one accessibility contract.
//
// Lives in the macOS shell (NOT PlayerCore): its padding and hover affordance are
// tuned for the AppKit toolbar. Every color and metric resolves through the shared
// ``DesignTokens`` — no literal colors, no magic numbers.
import DesignSystem
import SwiftUI

struct MacAMPToolbarButton: View {
    let icon: String
    let label: LocalizedStringResource?
    let help: LocalizedStringResource?
    let action: () -> Void

    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme
    @State private var isHovered = false

    init(
        icon: String,
        label: LocalizedStringResource? = nil,
        help: LocalizedStringResource? = nil,
        action: @escaping () -> Void
    ) {
        self.icon = icon
        self.label = label
        self.help = help
        self.action = action
    }

    var body: some View {
        let button = Button(action: action) { content }
            .buttonStyle(.plain)
            .pointingHandCursor()
        if let help {
            button.help(Text(help))
        } else {
            button
        }
    }
}

// MARK: - Composition

private extension MacAMPToolbarButton {
    var content: some View {
        glyph
            .font(tokens.typography.headline.font)
            .foregroundStyle(tokens.colors.accent.resolve(scheme))
            .padding(.horizontal, label == nil ? tokens.spacing.xSmall : tokens.spacing.small)
            .padding(.vertical, tokens.spacing.xxSmall)
            .background(hoverFill)
            .contentShape(Rectangle())
            .accessibilityLabel(accessibilityText)
            .onHover { hovering in
                withAnimation(.easeInOut(duration: tokens.motion.quick)) { isHovered = hovering }
            }
    }

    @ViewBuilder
    var glyph: some View {
        if let label {
            Label { Text(label) } icon: { Image(systemName: icon) }
        } else {
            Image(systemName: icon)
        }
    }

    var hoverFill: some View {
        RoundedRectangle(cornerRadius: tokens.radii.small, style: .continuous)
            .fill(tokens.colors.accentMuted.resolve(scheme))
            .opacity(isHovered ? 1 : 0)
    }

    var accessibilityText: Text {
        if let label {
            Text(label)
        } else if let help {
            Text(help)
        } else {
            Text(verbatim: icon)
        }
    }
}

#Preview {
    HStack(spacing: 12) {
        MacAMPToolbarButton(
            icon: "plus",
            label: FileAccessStrings.addFolder,
            help: MacAMPStrings.helpAddFolder
        ) {}
        MacAMPToolbarButton(
            icon: "sidebar.trailing",
            help: MacAMPStrings.helpRightPanel
        ) {}
    }
    .padding()
    .designTokens(.standard)
}
