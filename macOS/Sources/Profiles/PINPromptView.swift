import DesignSystem
import Foundation
import Services
import SwiftUI

struct PINPromptView: View {
    let profileName: String
    let onCancel: () -> Void
    let onSubmit: (String) -> Bool

    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var pin = ""
    @State private var showError = false
    @State private var shakeAmount: CGFloat = 0
    @FocusState private var fieldFocused: Bool

    private let boxCount = ProfilePIN.maxLength

    var body: some View {
        VStack(spacing: tokens.spacing.large) {
            Text(ProfileStrings.pinTitle(profileName: profileName))
                .font(tokens.typography.titleMedium.font)
                .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
            boxes
            if showError {
                Text(ProfileStrings.pinError)
                    .font(tokens.typography.caption.font)
                    .foregroundStyle(tokens.colors.danger.resolve(scheme))
            }
            buttons
        }
        .padding(tokens.spacing.xLarge)
        .frame(maxWidth: 420)
        .background(
            RoundedRectangle(cornerRadius: tokens.radii.large, style: .continuous)
                .fill(tokens.colors.surfaceRaised.resolve(scheme))
                .shadow(color: .black.opacity(0.3), radius: 24, y: 10)
        )
        .onAppear { DispatchQueue.main.async { fieldFocused = true } }
    }

    private var boxes: some View {
        ZStack {
            SecureField("", text: $pin)
                .textFieldStyle(.plain)
                .focused($fieldFocused)
                .opacity(0.02)
                .accessibilityIdentifier("profiles.pinField")
                .accessibilityLabel(Text(ProfileStrings.pinFieldLabel))
                .onChange(of: pin) { _, newValue in sanitize(newValue) }
                .onSubmit(submit)
            boxRow
                .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .onTapGesture { fieldFocused = true }
        .modifier(ShakeEffect(animatableData: shakeAmount))
    }

    private var boxRow: some View {
        HStack(spacing: tokens.spacing.small) {
            ForEach(0 ..< boxCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: tokens.radii.small, style: .continuous)
                    .strokeBorder(borderColor(index), lineWidth: 2)
                    .background(
                        RoundedRectangle(cornerRadius: tokens.radii.small, style: .continuous)
                            .fill(tokens.colors.surface.resolve(scheme))
                    )
                    .frame(width: 40, height: 52)
                    .overlay { filledDot(index) }
            }
        }
    }

    @ViewBuilder private func filledDot(_ index: Int) -> some View {
        if index < pin.count {
            Circle()
                .fill(tokens.colors.textPrimary.resolve(scheme))
                .frame(width: 12, height: 12)
        }
    }

    private var buttons: some View {
        HStack(spacing: tokens.spacing.medium) {
            Button(role: .cancel, action: onCancel) {
                Text(ProfileStrings.pinCancel)
            }
            Button(action: submit) {
                Text(ProfileStrings.pinUnlock)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(pin.count < ProfilePIN.minLength)
        }
    }

    private func borderColor(_ index: Int) -> Color {
        if showError { return tokens.colors.danger.resolve(scheme) }
        if index < pin.count { return tokens.colors.accent.resolve(scheme) }
        return tokens.colors.separator.resolve(scheme)
    }

    private func sanitize(_ newValue: String) {
        let filtered = String(newValue.filter { $0.isLetter || $0.isNumber }.prefix(boxCount))
        if filtered != pin { pin = filtered }
        if showError { showError = false }
    }

    private func submit() {
        guard pin.count >= ProfilePIN.minLength else { return }
        if onSubmit(pin) { return }
        failAttempt()
    }

    private func failAttempt() {
        showError = true
        if reduceMotion {
            pin = ""
        } else {
            withAnimation(.linear(duration: tokens.motion.standard)) { shakeAmount += 1 }
            DispatchQueue.main.asyncAfter(deadline: .now() + tokens.motion.standard) { pin = "" }
        }
        fieldFocused = true
    }
}

private struct ShakeEffect: GeometryEffect {
    var animatableData: CGFloat

    private let travel: CGFloat = 8
    private let cycles = 3.0

    func effectValue(size _: CGSize) -> ProjectionTransform {
        let offset = travel * CGFloat(sin(Double(animatableData) * .pi * cycles))
        return ProjectionTransform(CGAffineTransform(translationX: offset, y: 0))
    }
}
