import SwiftUI

/// A centered empty / loading / offline state: an icon (or spinner), a title, an
/// optional message and an optional call-to-action — all token-styled and
/// localized. Use the ``empty(action:)`` / ``loading()`` / ``offline(action:)``
/// presets, or compose a custom one.
public struct StateView: View {
    /// A call-to-action rendered as a prominent accent button.
    public struct Action {
        public var title: LocalizedStringResource
        public var systemImage: String?
        public var handler: () -> Void

        public init(
            title: LocalizedStringResource,
            systemImage: String? = nil,
            handler: @escaping () -> Void
        ) {
            self.title = title
            self.systemImage = systemImage
            self.handler = handler
        }
    }

    private let systemImage: String?
    private let showsProgress: Bool
    private let title: LocalizedStringResource
    private let message: LocalizedStringResource?
    private let action: Action?

    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    public init(
        systemImage: String?,
        showsProgress: Bool = false,
        title: LocalizedStringResource,
        message: LocalizedStringResource? = nil,
        action: Action? = nil
    ) {
        self.systemImage = systemImage
        self.showsProgress = showsProgress
        self.title = title
        self.message = message
        self.action = action
    }

    public var body: some View {
        VStack(spacing: tokens.spacing.large) {
            emblem
            VStack(spacing: tokens.spacing.small) {
                Text(title)
                    .font(tokens.typography.titleLarge.font)
                    .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
                    .multilineTextAlignment(.center)
                if let message {
                    Text(message)
                        .font(tokens.typography.callout.font)
                        .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
                        .multilineTextAlignment(.center)
                }
            }
            if let action {
                actionButton(action)
            }
        }
        .padding(tokens.spacing.xxLarge)
        .frame(maxWidth: 420)
        .accessibilityElement(children: .combine)
    }

    private var emblem: some View {
        ZStack {
            Circle()
                .fill(tokens.colors.accentMuted.resolve(scheme))
                .frame(width: 96, height: 96)
            if showsProgress {
                ProgressView()
                    .controlSize(.large)
                    .tint(tokens.colors.accent.resolve(scheme))
            } else if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(tokens.colors.accent.resolve(scheme))
            }
        }
    }

    private func actionButton(_ action: Action) -> some View {
        Button(action: action.handler) {
            HStack(spacing: tokens.spacing.xSmall) {
                if let symbol = action.systemImage {
                    Image(systemName: symbol)
                }
                Text(action.title)
            }
            .font(tokens.typography.headline.font)
            .foregroundStyle(tokens.colors.onAccent.resolve(scheme))
            .padding(.horizontal, tokens.spacing.large)
            .padding(.vertical, tokens.spacing.small)
            .background(
                Capsule(style: .continuous)
                    .fill(tokens.colors.accent.resolve(scheme))
            )
        }
        .buttonStyle(.plain)
    }
}

public extension StateView {
    static func empty(action: Action? = nil) -> StateView {
        StateView(
            systemImage: "music.note.list",
            title: DesignSystemStrings.emptyTitle,
            message: DesignSystemStrings.emptyMessage,
            action: action
        )
    }

    static func loading() -> StateView {
        StateView(
            systemImage: nil,
            showsProgress: true,
            title: DesignSystemStrings.loadingTitle
        )
    }

    static func offline(action: Action? = nil) -> StateView {
        StateView(
            systemImage: "wifi.slash",
            title: DesignSystemStrings.offlineTitle,
            message: DesignSystemStrings.offlineMessage,
            action: action
        )
    }
}
