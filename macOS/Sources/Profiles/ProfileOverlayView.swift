import DesignSystem
import Foundation
import Persistence
import Services
import SwiftUI

struct ProfileOverlayView: View {
    @Binding var isPresented: Bool

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var stage: ProfileOverlayStage = .grid
    @State private var editorRequest: EditorRequest?

    var body: some View {
        ZStack {
            backdropCatcher
            content
            if case let .pinPrompt(profile, purpose) = stage {
                pinLayer(profile: profile, purpose: purpose)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onExitCommand(perform: handleDismissRequest)
        .sheet(item: $editorRequest) { request in
            ProfileEditorView(profile: request.profile)
        }
    }

    private var backdropCatcher: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture(perform: handleDismissRequest)
    }

    private var content: some View {
        VStack(spacing: tokens.spacing.xLarge) {
            header
            ProfileOverlayGrid(
                profiles: environment.profileService.profiles,
                activeProfileId: environment.profileService.activeProfile.id ?? ProfileRecord.guestID,
                onSelect: select,
                onEdit: edit,
                onCreate: { editorRequest = EditorRequest(profile: nil) }
            )
        }
        .padding(tokens.spacing.xxLarge)
        .frame(maxWidth: 760)
        .opacity(stage.isGrid ? 1 : 0.15)
    }

    private var header: some View {
        ZStack {
            Text(ProfileStrings.overlayTitle)
                .font(tokens.typography.displayMedium.font)
                .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
                .allowsHitTesting(false)
                .accessibilityIdentifier("profiles.overlay")
            HStack {
                Spacer()
                closeButton
            }
        }
    }

    private var closeButton: some View {
        Button(action: dismissOverlay) {
            Image(systemName: "xmark.circle.fill")
                .font(.title2)
                .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
        }
        .buttonStyle(.plain)
        .help(Text(ProfileStrings.overlayClose))
        .accessibilityLabel(Text(ProfileStrings.overlayClose))
    }

    private func pinLayer(profile: ProfileRecord, purpose: PINPurpose) -> some View {
        ZStack {
            tokens.colors.canvas.resolve(scheme).opacity(0.6)
                .contentShape(Rectangle())
                .onTapGesture { stage = .grid }
            PINPromptView(
                profileName: displayName(for: profile),
                onCancel: { stage = .grid },
                onSubmit: { pin in handlePINSubmit(pin: pin, profile: profile, purpose: purpose) }
            )
        }
    }
}

// MARK: - Actions

private extension ProfileOverlayView {
    func select(_ profile: ProfileRecord) {
        guard let id = profile.id else { return }
        if requiresPIN(profile) {
            stage = .pinPrompt(profile: profile, purpose: .switchTo)
        } else {
            try? environment.profileService.switchTo(profileId: id, pin: nil)
            dismissOverlay()
        }
    }

    func edit(_ profile: ProfileRecord) {
        if requiresPIN(profile) {
            stage = .pinPrompt(profile: profile, purpose: .edit)
        } else {
            editorRequest = EditorRequest(profile: profile)
        }
    }

    func handlePINSubmit(pin: String, profile: ProfileRecord, purpose: PINPurpose) -> Bool {
        switch purpose {
        case .switchTo:
            do {
                try environment.profileService.switchTo(profileId: profile.id ?? 0, pin: pin)
                dismissOverlay()
                return true
            } catch {
                return false
            }
        case .edit:
            guard verifyPIN(pin, for: profile) else { return false }
            stage = .grid
            editorRequest = EditorRequest(profile: profile)
            return true
        }
    }

    func verifyPIN(_ pin: String, for profile: ProfileRecord) -> Bool {
        guard let hash = profile.pinHash,
              let saltString = profile.pinSalt,
              let salt = Data(base64Encoded: saltString)
        else { return false }
        return ProfilePIN.verify(pin: pin, hash: hash, salt: salt)
    }

    func requiresPIN(_ profile: ProfileRecord) -> Bool {
        profile.pinHash != nil && profile.id != ProfileRecord.guestID
    }

    func handleDismissRequest() {
        if stage.isGrid {
            dismissOverlay()
        } else {
            stage = .grid
        }
    }

    func dismissOverlay() {
        stage = .grid
        withAnimation(reduceMotion ? nil : .easeInOut(duration: tokens.motion.standard)) {
            isPresented = false
        }
    }

    func displayName(for profile: ProfileRecord) -> String {
        profile.id == ProfileRecord.guestID ? String(localized: ProfileStrings.guestName) : profile.name
    }
}

// MARK: - Stage + editor request

private enum ProfileOverlayStage {
    case grid
    case pinPrompt(profile: ProfileRecord, purpose: PINPurpose)

    var isGrid: Bool {
        if case .grid = self { return true }
        return false
    }
}

private enum PINPurpose {
    case switchTo
    case edit
}

private struct EditorRequest: Identifiable {
    let id = UUID()
    let profile: ProfileRecord?
}
