import DesignSystem
import Observation
import SwiftUI

@MainActor
@Observable
public final class ToastManager {
    public private(set) var activeToast: ToastMessage?
    private var dismissTask: Task<Void, Never>?

    public struct ToastMessage: Equatable {
        public let text: String
        public let icon: String
    }

    public init() {}

    public func show(text: String, icon: String = "checkmark.circle.fill") {
        dismissTask?.cancel()
        activeToast = ToastMessage(text: text, icon: icon)
        dismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            if !Task.isCancelled { activeToast = nil }
        }
    }
}

struct ToastOverlay: View {
    @Environment(ToastManager.self) private var toastManager
    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack {
            if let toast = toastManager.activeToast {
                toastBubble(toast)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .animation(.spring(duration: 0.3), value: toastManager.activeToast)
            }
            Spacer()
        }
        .animation(.spring(duration: 0.3), value: toastManager.activeToast)
        .allowsHitTesting(false)
    }

    private func toastBubble(_ toast: ToastManager.ToastMessage) -> some View {
        HStack(spacing: tokens.spacing.small) {
            Image(systemName: toast.icon)
                .foregroundStyle(tokens.colors.onAccent.resolve(scheme))
            Text(verbatim: toast.text)
                .font(tokens.typography.callout.font)
                .foregroundStyle(tokens.colors.onAccent.resolve(scheme))
                .lineLimit(1)
        }
        .padding(.horizontal, tokens.spacing.large)
        .padding(.vertical, tokens.spacing.small)
        .background(
            Capsule(style: .continuous)
                .fill(tokens.colors.accent.resolve(scheme))
                .shadow(
                    color: Color.black.opacity(tokens.elevation.medium.colorOpacity),
                    radius: tokens.elevation.medium.radius,
                    x: tokens.elevation.medium.offsetX,
                    y: tokens.elevation.medium.offsetY
                )
        )
        .padding(.top, tokens.spacing.medium)
        // Combined first: an identifier on a container holding an SF Symbol is
        // shadowed by its children, and `.combine` leaves none to shadow it.
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("toast")
    }
}
