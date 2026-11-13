// ProfileEditorPINSection — the optional profile-lock PIN controls in the editor.
//
// Pure UI over three bindings the parent owns: the draft `newPIN`, a
// `removeRequested` flag, and the current `hasExistingPIN` state. It never touches
// ``ProfileManaging`` itself — the parent's Save applies set/change/remove through
// the service, which is the sole PIN validator (this view only surfaces the
// resulting ``ProfilePINError`` inline). The parent omits this section entirely for
// Guest, so no PIN control ever renders for the PIN-ineligible built-in profile.
import DesignSystem
import Services
import SwiftUI

struct ProfileEditorPINSection: View {
    @Binding var newPIN: String
    @Binding var removeRequested: Bool
    let hasExistingPIN: Bool
    let pinError: ProfilePINError?

    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Section {
            if hasExistingPIN {
                statusRow
            }
            if !removeRequested {
                entryField
            }
            if let pinError {
                Text(ProfileStrings.pinErrorMessage(for: pinError))
                    .font(tokens.typography.caption.font)
                    .foregroundStyle(tokens.colors.danger.resolve(scheme))
            }
        } header: {
            Text(ProfileStrings.editorSectionPIN)
        }
    }
}

// MARK: - Rows

private extension ProfileEditorPINSection {
    var statusRow: some View {
        HStack {
            Text(removeRequested ? ProfileStrings.editorPINWillRemove : ProfileStrings.editorPINStatusSet)
                .font(tokens.typography.callout.font)
                .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
            Spacer()
            if removeRequested {
                Button { removeRequested = false } label: {
                    Text(ProfileStrings.editorKeepPIN)
                }
            } else {
                Button(role: .destructive) {
                    removeRequested = true
                    newPIN = ""
                } label: {
                    Text(ProfileStrings.editorRemovePIN)
                }
                .accessibilityIdentifier("profiles.editor.removePINButton")
            }
        }
    }

    var entryField: some View {
        SecureField(text: $newPIN, prompt: Text(ProfileStrings.editorPINPrompt)) {
            Text(hasExistingPIN ? ProfileStrings.editorChangePIN : ProfileStrings.editorSetPIN)
        }
        .accessibilityIdentifier("profiles.editor.pinField")
    }
}
