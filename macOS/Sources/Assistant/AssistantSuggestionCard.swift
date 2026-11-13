import DesignSystem
import SwiftUI

/// One row of the assistant's suggestion feed: an accent icon chip, a title, a
/// subtitle, an optional trailing count, and an optional tap action.
///
/// `title` is a `Text` rather than a `LocalizedStringResource` because a generated
/// playlist name is DATA — it arrives already written in the listener's language and
/// is rendered `Text(verbatim:)` — while the hygiene card's title is localized
/// chrome. Both shapes have to flow through the same component.
struct AssistantSuggestionCard: View {
    let systemImage: String
    let title: Text
    let subtitle: Text
    var count: Int?
    /// What pressing the card does, in the listener's language. Defaults to the
    /// generated-mix wording because that is what most cards are; the library-health
    /// card opens a findings list and says so instead.
    var actionHint: LocalizedStringResource = AssistantPaneStrings.openPlaylist
    var action: (() -> Void)?

    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme
    @State private var isHovered = false

    var body: some View {
        if let action {
            Button(action: action) { card }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .help(actionHint)
                .accessibilityHint(Text(actionHint))
        } else {
            card
        }
    }
}

// MARK: - Card

private extension AssistantSuggestionCard {
    var card: some View {
        HStack(spacing: tokens.spacing.small) {
            iconChip
            VStack(alignment: .leading, spacing: tokens.spacing.xxSmall) {
                title
                    .font(tokens.typography.headline.font)
                    .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
                    .lineLimit(1)
                subtitle
                    .font(tokens.typography.caption.font)
                    .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
                    .lineLimit(2)
            }
            Spacer(minLength: tokens.spacing.xSmall)
            trailing
        }
        .padding(tokens.spacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
        .contentShape(RoundedRectangle(cornerRadius: tokens.radii.medium, style: .continuous))
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
    }

    var iconChip: some View {
        RoundedRectangle(cornerRadius: tokens.radii.small, style: .continuous)
            .fill(tokens.colors.accentMuted.resolve(scheme))
            .frame(width: iconChipSide, height: iconChipSide)
            .overlay {
                Image(systemName: systemImage)
                    .font(tokens.typography.titleMedium.font)
                    .foregroundStyle(tokens.colors.accent.resolve(scheme))
            }
    }

    @ViewBuilder
    var trailing: some View {
        if let count {
            Text(verbatim: "\(count)")
                .font(tokens.typography.headline.font)
                .monospacedDigit()
                .foregroundStyle(tokens.colors.accent.resolve(scheme))
                .padding(.horizontal, tokens.spacing.xSmall)
                .padding(.vertical, tokens.spacing.xxSmall)
                .background(
                    Capsule().fill(tokens.colors.accentMuted.resolve(scheme))
                )
        } else if action != nil {
            Image(systemName: "chevron.right")
                .font(tokens.typography.caption.font)
                .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
        }
    }

    var background: some View {
        RoundedRectangle(cornerRadius: tokens.radii.medium, style: .continuous)
            .fill(tokens.colors.surfaceRaised.resolve(scheme))
            .overlay(
                RoundedRectangle(cornerRadius: tokens.radii.medium, style: .continuous)
                    .strokeBorder(
                        isHovered && action != nil
                            ? tokens.colors.accent.resolve(scheme)
                            : tokens.colors.separator.resolve(scheme),
                        lineWidth: tokens.spacing.hairline
                    )
            )
            .shadow(
                color: .black.opacity(tokens.elevation.low.colorOpacity),
                radius: tokens.elevation.low.radius,
                x: tokens.elevation.low.offsetX,
                y: tokens.elevation.low.offsetY
            )
    }

    /// Sized off the spacing grid rather than a literal so the chip tracks the
    /// 4-pt scale the rest of the shell is built on.
    var iconChipSide: CGFloat {
        tokens.spacing.large + tokens.spacing.xSmall
    }
}

#Preview {
    VStack(spacing: 12) {
        AssistantSuggestionCard(
            systemImage: "wand.and.stars",
            title: Text(verbatim: "Evening Mix"),
            subtitle: Text(AssistantPaneStrings.autoMixSubtitle),
            action: {}
        )
        AssistantSuggestionCard(
            systemImage: "sparkles.rectangle.stack",
            title: Text(AssistantPaneStrings.hygieneIssues),
            subtitle: Text(AssistantPaneStrings.hygieneIssuesSubtitle),
            count: 3
        )
    }
    .padding()
    .designTokens(.standard)
    .frame(width: 420)
}
