import Foundation
import Services

enum ProfileStrings {
    static func profileButtonLabel(profileName: String) -> LocalizedStringResource {
        LocalizedStringResource(
            "player.profileButton.label",
            defaultValue: "Profile: \(profileName)",
            comment: "Accessibility label for the player-bar profile avatar button; argument is the active profile's name"
        )
    }

    static let profileButtonHelp = LocalizedStringResource(
        "player.profileButton.help",
        defaultValue: "Switch profile",
        comment: "Help tooltip for the player-bar profile avatar button"
    )

    // MARK: - Preferences pane

    static let preferencesTitle = LocalizedStringResource(
        "profiles.preferences.title",
        defaultValue: "Profiles",
        comment: "Title of the Profiles preferences tab and the pane header"
    )

    static let preferencesSubtitle = LocalizedStringResource(
        "profiles.preferences.subtitle",
        defaultValue: "Give each listener their own library, playlists, favourites and play history.",
        comment: "One-line subtitle under the Profiles preferences header"
    )

    static let enableToggleLabel = LocalizedStringResource(
        "profiles.preferences.enableToggle",
        defaultValue: "Enable Profiles",
        comment: "Label for the toggle that turns the user-profiles feature on or off"
    )

    static let enableFooter = LocalizedStringResource(
        "profiles.preferences.enableFooter",
        defaultValue: "When off, the app behaves as a single built-in Guest profile; your profiles and their data are kept.",
        comment: "Explanatory footer under the Enable Profiles toggle describing Guest behaviour"
    )

    static let manageButton = LocalizedStringResource(
        "profiles.preferences.manageButton",
        defaultValue: "Manage Profiles…",
        comment: "Button that opens the full-window profile management overlay"
    )

    static let currentProfileLabel = LocalizedStringResource(
        "profiles.preferences.currentProfile",
        defaultValue: "Current Profile",
        comment: "Leading label for the read-only row showing the active profile in preferences"
    )

    static let guestName = LocalizedStringResource(
        "profiles.guestName",
        defaultValue: "Guest",
        comment: "Display name for the built-in Guest profile (profile id 1), shown regardless of the stored row name"
    )

    // MARK: - Editor titles

    static let editorCreateTitle = LocalizedStringResource(
        "profiles.editor.createTitle",
        defaultValue: "New Profile",
        comment: "Title of the profile editor when creating a new profile"
    )

    static let editorEditTitle = LocalizedStringResource(
        "profiles.editor.editTitle",
        defaultValue: "Edit Profile",
        comment: "Title of the profile editor when editing an existing profile"
    )

    // MARK: - Editor identity fields

    static let editorSectionIdentity = LocalizedStringResource(
        "profiles.editor.section.identity",
        defaultValue: "Identity",
        comment: "Header for the profile editor's name and description section"
    )

    static let editorNameLabel = LocalizedStringResource(
        "profiles.editor.name.label",
        defaultValue: "Name",
        comment: "Label for the required profile name field"
    )

    static let editorNamePrompt = LocalizedStringResource(
        "profiles.editor.name.prompt",
        defaultValue: "Name",
        comment: "Placeholder for the profile name field"
    )

    static let editorNameRequiredError = LocalizedStringResource(
        "profiles.editor.name.requiredError",
        defaultValue: "Name is required",
        comment: "Inline error shown when the profile name field is left empty"
    )

    static let editorLastNameLabel = LocalizedStringResource(
        "profiles.editor.lastName.label",
        defaultValue: "Last Name",
        comment: "Label for the optional profile last-name field"
    )

    static let editorLastNamePrompt = LocalizedStringResource(
        "profiles.editor.lastName.prompt",
        defaultValue: "Optional",
        comment: "Placeholder for the optional profile last-name field"
    )

    static let editorBioLabel = LocalizedStringResource(
        "profiles.editor.bio.label",
        defaultValue: "Description",
        comment: "Label for the optional multi-line profile description field"
    )

    // MARK: - Editor avatar picker

    static let editorSectionAvatar = LocalizedStringResource(
        "profiles.editor.section.avatar",
        defaultValue: "Avatar",
        comment: "Header for the profile editor's avatar picker section"
    )

    static let editorAvatarPickerLabel = LocalizedStringResource(
        "profiles.editor.avatar.pickerLabel",
        defaultValue: "Choose an avatar",
        comment: "Accessibility label for the profile avatar preset picker grid"
    )

    static let editorChoosePhoto = LocalizedStringResource(
        "profiles.editor.avatar.choosePhoto",
        defaultValue: "Choose Photo…",
        comment: "Button in the profile editor that opens a file importer to pick a custom avatar image"
    )

    static let editorPhotoImportFailed = LocalizedStringResource(
        "profiles.editor.avatar.importFailed",
        defaultValue: "Couldn't import that image.",
        comment: "Toast shown when importing a picked custom avatar image fails"
    )

    static let editorCustomPhotoTile = LocalizedStringResource(
        "profiles.editor.avatar.customTile",
        defaultValue: "Custom photo",
        comment: "Accessibility label for the selected custom-photo tile in the avatar picker"
    )

    // MARK: - Editor actions

    static let editorSave = LocalizedStringResource(
        "profiles.editor.save",
        defaultValue: "Save",
        comment: "Button that saves edits to an existing profile"
    )

    static let editorCreate = LocalizedStringResource(
        "profiles.editor.create",
        defaultValue: "Create",
        comment: "Button that creates a new profile"
    )

    static let editorCancel = LocalizedStringResource(
        "profiles.editor.cancel",
        defaultValue: "Cancel",
        comment: "Button that dismisses the profile editor without saving"
    )

    // MARK: - Editor delete

    static let editorDelete = LocalizedStringResource(
        "profiles.editor.delete",
        defaultValue: "Delete Profile",
        comment: "Button that deletes the profile being edited"
    )

    static let editorDeleteConfirmTitle = LocalizedStringResource(
        "profiles.editor.delete.confirmTitle",
        defaultValue: "Delete Profile?",
        comment: "Title of the destructive confirmation shown before deleting a profile"
    )

    static func editorDeleteConfirmMessage(name: String) -> LocalizedStringResource {
        LocalizedStringResource(
            "profiles.editor.delete.confirmMessage",
            defaultValue: "\"\(name)\" and its playlists, favourites and statistics will be removed. This can't be undone.",
            comment: "Body of the delete-profile confirmation; argument is the profile name"
        )
    }

    static let editorDeleteConfirmButton = LocalizedStringResource(
        "profiles.editor.delete.confirmButton",
        defaultValue: "Delete",
        comment: "Destructive confirm button in the delete-profile dialog"
    )
}

// MARK: - Editor PIN management copy

extension ProfileStrings {
    static let editorSectionPIN = LocalizedStringResource(
        "profiles.editor.section.pin",
        defaultValue: "PIN",
        comment: "Header for the optional profile-lock PIN section in the editor"
    )

    static let editorPINStatusSet = LocalizedStringResource(
        "profiles.editor.pin.statusSet",
        defaultValue: "PIN is set",
        comment: "Status text shown when the profile currently has a PIN"
    )

    static let editorSetPIN = LocalizedStringResource(
        "profiles.editor.pin.set",
        defaultValue: "Set PIN",
        comment: "Label for the field that sets a new profile PIN"
    )

    static let editorChangePIN = LocalizedStringResource(
        "profiles.editor.pin.change",
        defaultValue: "Change PIN",
        comment: "Label for the field that changes an existing profile PIN"
    )

    static let editorRemovePIN = LocalizedStringResource(
        "profiles.editor.pin.remove",
        defaultValue: "Remove PIN",
        comment: "Button that clears an existing profile PIN"
    )

    static let editorKeepPIN = LocalizedStringResource(
        "profiles.editor.pin.keep",
        defaultValue: "Keep PIN",
        comment: "Button that undoes a pending PIN removal"
    )

    static let editorPINWillRemove = LocalizedStringResource(
        "profiles.editor.pin.willRemove",
        defaultValue: "The PIN will be removed when you save",
        comment: "Note shown when the user has chosen to clear the profile PIN on save"
    )

    static let editorPINPrompt = LocalizedStringResource(
        "profiles.editor.pin.prompt",
        defaultValue: "\(ProfilePIN.minLength)–\(ProfilePIN.maxLength) letters or digits",
        comment: "Placeholder describing the allowed PIN format as a min-max character range"
    )

    /// Maps each ``ProfilePINError`` case to a distinct localized inline message.
    static func pinErrorMessage(for error: ProfilePINError) -> LocalizedStringResource {
        switch error {
        case .tooShort:
            LocalizedStringResource(
                "profiles.editor.pin.error.tooShort",
                defaultValue: "PIN must be at least \(ProfilePIN.minLength) characters",
                comment: "Inline PIN error: the entered PIN is shorter than the minimum length"
            )
        case .tooLong:
            LocalizedStringResource(
                "profiles.editor.pin.error.tooLong",
                defaultValue: "PIN must be at most \(ProfilePIN.maxLength) characters",
                comment: "Inline PIN error: the entered PIN is longer than the maximum length"
            )
        case .invalidCharacters:
            LocalizedStringResource(
                "profiles.editor.pin.error.invalidCharacters",
                defaultValue: "PIN may contain only letters and digits",
                comment: "Inline PIN error: the entered PIN contains a disallowed character"
            )
        }
    }
}

// MARK: - Select overlay + PIN prompt copy

extension ProfileStrings {
    static let overlayTitle = LocalizedStringResource(
        "profiles.overlay.title",
        defaultValue: "Who's Listening?",
        comment: "Title at the top of the Netflix-style profile-select overlay"
    )

    static let overlayClose = LocalizedStringResource(
        "profiles.overlay.close",
        defaultValue: "Close",
        comment: "Accessibility label and tooltip for the button that closes the profile-select overlay"
    )

    static let overlayCreate = LocalizedStringResource(
        "profiles.overlay.create",
        defaultValue: "Add Profile",
        comment: "Label for the tile that opens the editor to create a new profile"
    )

    static func overlayEditLabel(profileName: String) -> LocalizedStringResource {
        LocalizedStringResource(
            "profiles.overlay.edit",
            defaultValue: "Edit \(profileName)",
            comment: "Accessibility label for a profile tile's pencil edit badge; argument is the profile name"
        )
    }

    static let tileLockedLabel = LocalizedStringResource(
        "profiles.tile.locked",
        defaultValue: "PIN protected",
        comment: "Accessibility label for the lock badge shown on a PIN-protected profile tile"
    )

    static func pinTitle(profileName: String) -> LocalizedStringResource {
        LocalizedStringResource(
            "profiles.pin.title",
            defaultValue: "Enter \(profileName)'s PIN",
            comment: "Title of the PIN entry prompt; argument is the profile being unlocked"
        )
    }

    static let pinFieldLabel = LocalizedStringResource(
        "profiles.pin.fieldLabel",
        defaultValue: "PIN",
        comment: "Accessibility label for the secure PIN entry field"
    )

    static let pinError = LocalizedStringResource(
        "profiles.pin.error",
        defaultValue: "Incorrect PIN. Try again.",
        comment: "Error shown under the PIN entry field after a wrong PIN"
    )

    static let pinCancel = LocalizedStringResource(
        "profiles.pin.cancel",
        defaultValue: "Cancel",
        comment: "Button that dismisses the PIN prompt and returns to the profile grid"
    )

    static let pinUnlock = LocalizedStringResource(
        "profiles.pin.unlock",
        defaultValue: "Unlock",
        comment: "Button that submits the entered PIN to unlock or edit a profile"
    )
}
