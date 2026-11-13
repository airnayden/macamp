// ProfileEditorView — create, edit, and delete a profile on macOS.
//
// A fixed-size sheet (header / grouped Form / footer), the shell's established
// editor shape. `init(profile:)` is the create-vs-edit switch: `nil` → create
// mode; a non-nil ``ProfileRecord`` → edit mode. Todo 15's overlay presents this
// as a `.sheet` — create from its "+" tile with `ProfileEditorView()`, edit with
// `ProfileEditorView(profile: tapped)`.
//
// Every mutation funnels through ``ProfileManaging`` (`environment.profileService`)
// — create/update/delete/setPIN/removePIN — never the repository directly. The
// optional profile lock is a PIN only: this file names no other credential in any
// identifier, string, or comment. Guest (id 1) is PIN-ineligible and undeletable,
// so its PIN section and delete control are absent (not merely disabled).
import DesignSystem
import Persistence
import Services
import SwiftUI

struct ProfileEditorView: View {
    let profile: ProfileRecord?

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    @State private var name: String
    @State private var lastName: String
    @State private var bio: String
    @State private var selectedPreset: ProfileAvatarPreset
    @State private var avatarImagePath: String?
    @State private var newPIN = ""
    @State private var removePINRequested = false
    @State private var nameError = false
    @State private var pinError: ProfilePINError?
    @State private var showDeleteConfirm = false

    init(profile: ProfileRecord? = nil) {
        self.profile = profile
        _name = State(initialValue: profile?.name ?? "")
        _lastName = State(initialValue: profile?.lastName ?? "")
        _bio = State(initialValue: profile?.bio ?? "")
        _selectedPreset = State(
            initialValue: ProfileAvatarPreset(id: profile?.avatarId ?? ProfileRecord.defaultAvatarID)
        )
        _avatarImagePath = State(initialValue: profile?.avatarImagePath)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            form
            Divider()
            footer
        }
        .frame(width: 460, height: 680)
        .background(tokens.colors.canvas.resolve(scheme))
        .alert(Text(ProfileStrings.editorDeleteConfirmTitle), isPresented: $showDeleteConfirm) {
            Button(String(localized: ProfileStrings.editorDeleteConfirmButton), role: .destructive) {
                performDelete()
            }
            Button(String(localized: ProfileStrings.editorCancel), role: .cancel) {}
        } message: {
            if let profile {
                Text(ProfileStrings.editorDeleteConfirmMessage(name: profile.name))
            }
        }
    }
}

// MARK: - Derived state

private extension ProfileEditorView {
    var isEditing: Bool {
        profile != nil
    }

    var isGuest: Bool {
        profile?.id == ProfileRecord.guestID
    }

    var hasExistingPIN: Bool {
        profile?.pinHash != nil
    }

    var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var canDelete: Bool {
        isEditing && !isGuest
    }
}

// MARK: - Chrome

private extension ProfileEditorView {
    var header: some View {
        HStack {
            Text(isEditing ? ProfileStrings.editorEditTitle : ProfileStrings.editorCreateTitle)
                .font(tokens.typography.headline.font)
                .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
                .accessibilityIdentifier("profiles.editor")
            Spacer()
        }
        .padding(tokens.spacing.large)
    }

    var footer: some View {
        HStack(spacing: tokens.spacing.small) {
            if canDelete {
                Button(role: .destructive) { showDeleteConfirm = true } label: {
                    Text(ProfileStrings.editorDelete)
                }
                .accessibilityIdentifier("profiles.editor.deleteButton")
            }
            Spacer()
            Button(role: .cancel) { dismiss() } label: {
                Text(ProfileStrings.editorCancel)
            }
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("profiles.editor.cancelButton")
            Button(action: save) {
                Text(isEditing ? ProfileStrings.editorSave : ProfileStrings.editorCreate)
            }
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("profiles.editor.saveButton")
        }
        .padding(tokens.spacing.large)
    }
}

// MARK: - Form sections

private extension ProfileEditorView {
    var form: some View {
        Form {
            identitySection
            ProfileEditorAvatarSection(
                selectedPreset: $selectedPreset,
                avatarImagePath: $avatarImagePath,
                originalAvatarImagePath: profile?.avatarImagePath
            )
            if !isGuest {
                ProfileEditorPINSection(
                    newPIN: $newPIN,
                    removeRequested: $removePINRequested,
                    hasExistingPIN: hasExistingPIN,
                    pinError: pinError
                )
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onChange(of: name) { _, _ in nameError = false }
        .onChange(of: newPIN) { _, _ in pinError = nil }
    }

    var identitySection: some View {
        Section {
            VStack(alignment: .leading, spacing: tokens.spacing.xxSmall) {
                TextField(text: $name, prompt: Text(ProfileStrings.editorNamePrompt)) {
                    Text(ProfileStrings.editorNameLabel)
                }
                .accessibilityIdentifier("profiles.editor.nameField")
                if nameError {
                    Text(ProfileStrings.editorNameRequiredError)
                        .font(tokens.typography.caption.font)
                        .foregroundStyle(tokens.colors.danger.resolve(scheme))
                }
            }
            TextField(text: $lastName, prompt: Text(ProfileStrings.editorLastNamePrompt)) {
                Text(ProfileStrings.editorLastNameLabel)
            }
            .accessibilityIdentifier("profiles.editor.lastNameField")
            VStack(alignment: .leading, spacing: tokens.spacing.xxSmall) {
                Text(ProfileStrings.editorBioLabel)
                    .font(tokens.typography.caption.font)
                    .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
                TextEditor(text: $bio)
                    .font(tokens.typography.body.font)
                    .frame(minHeight: 72)
                    .accessibilityIdentifier("profiles.editor.bioField")
            }
        } header: {
            Text(ProfileStrings.editorSectionIdentity)
        }
    }
}

// MARK: - Mutations

private extension ProfileEditorView {
    func save() {
        let trimmed = trimmedName
        guard !trimmed.isEmpty else {
            nameError = true
            return
        }
        do {
            let id = try persistProfile(named: trimmed)
            try applyPINChange(profileId: id)
            cleanupReplacedAvatar()
            dismiss()
        } catch let ProfileServiceError.invalidPIN(error) {
            pinError = error
        } catch {}
    }

    func persistProfile(named trimmed: String) throws -> Int64? {
        if let profile {
            var target = profile
            target.name = trimmed
            target.lastName = normalized(lastName)
            target.bio = normalized(bio)
            target.avatarId = selectedPreset.rawValue
            target.avatarImagePath = avatarImagePath
            try environment.profileService.update(target)
            return target.id
        }
        let created = try environment.profileService.create(
            ProfileRecord(
                name: trimmed,
                lastName: normalized(lastName),
                bio: normalized(bio),
                avatarId: selectedPreset.rawValue,
                avatarImagePath: avatarImagePath
            )
        )
        return created.id
    }

    func applyPINChange(profileId: Int64?) throws {
        guard !isGuest, let profileId else { return }
        if removePINRequested {
            try environment.profileService.removePIN(profileId: profileId)
        } else if !newPIN.isEmpty {
            try environment.profileService.setPIN(profileId: profileId, pin: newPIN)
        }
    }

    func performDelete() {
        guard let id = profile?.id, id != ProfileRecord.guestID else { return }
        let removedAvatarPath = profile?.avatarImagePath
        try? environment.profileService.delete(id: id)
        if let removedAvatarPath {
            ProfileAvatarImageStore().remove(at: removedAvatarPath)
        }
        dismiss()
    }

    func cleanupReplacedAvatar() {
        guard let original = profile?.avatarImagePath, original != avatarImagePath else { return }
        ProfileAvatarImageStore().remove(at: original)
    }

    func normalized(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

#Preview("Create profile") {
    ProfileEditorView()
        .environment(AppEnvironment.preview())
        .designTokens(.standard)
}
