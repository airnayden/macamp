// ProfileEditorAvatarSection — the editor's avatar picker: a "Choose Photo…"
// importer plus the preset grid, with an optional custom-photo tile.
//
// `avatarImagePath == nil` renders the selected `avatarId` preset; a non-nil path
// renders the custom image the shell copied into Application Support. Picking any
// preset CLEARS the custom image; importing a photo OVERRIDES the preset. This view
// owns the this-session file churn (deleting an orphaned re-import); the parent's
// Save cleans up the profile's ORIGINAL image when it changes. All image work goes
// through DesignSystem's AppKit-free ``ProfileAvatarImage`` / ``ProfileAvatarImageStore``.
//
// Extracted from ``ProfileEditorView`` (mirroring ``ProfileEditorPINSection``) to
// keep both files under the SwiftLint file-length budget.
import DesignSystem
import Persistence
import SwiftUI
import UniformTypeIdentifiers

struct ProfileEditorAvatarSection: View {
    @Binding var selectedPreset: ProfileAvatarPreset
    @Binding var avatarImagePath: String?
    /// The profile's image path when the editor opened — the ONE path this view must
    /// never delete (the parent's Save owns replacing it). `nil` in create mode.
    let originalAvatarImagePath: String?

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    @State private var isImportingPhoto = false

    private let store = ProfileAvatarImageStore()

    var body: some View {
        Section {
            choosePhotoButton
            avatarGrid
        } header: {
            Text(ProfileStrings.editorSectionAvatar)
        }
    }
}

// MARK: - Rows

private extension ProfileEditorAvatarSection {
    var choosePhotoButton: some View {
        Button {
            isImportingPhoto = true
        } label: {
            Label {
                Text(ProfileStrings.editorChoosePhoto)
            } icon: {
                Image(systemName: "photo.on.rectangle")
            }
        }
        .accessibilityIdentifier("profiles.editor.choosePhotoButton")
        .fileImporter(
            isPresented: $isImportingPhoto,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
    }

    var avatarGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 56), spacing: tokens.spacing.small)],
            spacing: tokens.spacing.small
        ) {
            if avatarImagePath != nil {
                customTile
            }
            ForEach(ProfileAvatarPreset.allCases) { preset in
                avatarTile(preset)
            }
        }
        .padding(.vertical, tokens.spacing.xxSmall)
        .accessibilityLabel(Text(ProfileStrings.editorAvatarPickerLabel))
    }

    var customTile: some View {
        Button {
            // The custom photo is already active; re-tapping it is a no-op. Users
            // switch away by picking a preset, or replace it via "Choose Photo…".
        } label: {
            ProfileAvatarView(preset: selectedPreset, imagePath: avatarImagePath, size: 52)
                .overlay { selectionRing(active: true) }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("profiles.editor.avatarTile.custom")
        .accessibilityAddTraits(.isSelected)
        .accessibilityLabel(Text(ProfileStrings.editorCustomPhotoTile))
    }

    func avatarTile(_ preset: ProfileAvatarPreset) -> some View {
        let isSelected = avatarImagePath == nil && preset == selectedPreset
        return Button {
            selectedPreset = preset
            setAvatarImagePath(nil)
        } label: {
            ProfileAvatarView(preset: preset, size: 52)
                .overlay { selectionRing(active: isSelected) }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("profiles.editor.avatarTile.\(preset.rawValue)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    @ViewBuilder
    func selectionRing(active: Bool) -> some View {
        if active {
            Circle().strokeBorder(
                tokens.colors.accent.resolve(scheme),
                lineWidth: tokens.spacing.xxSmall * 0.75
            )
        }
    }
}

// MARK: - Import + this-session cleanup

private extension ProfileEditorAvatarSection {
    func handleImport(_ result: Result<[URL], Error>) {
        guard case let .success(urls) = result, let url = urls.first else { return }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let path = try store.importImage(from: url)
            setAvatarImagePath(path)
        } catch {
            environment.toast.show(
                text: String(localized: ProfileStrings.editorPhotoImportFailed),
                icon: "exclamationmark.triangle"
            )
        }
    }

    /// Sets the custom-image path, deleting a now-orphaned THIS-SESSION import first
    /// (never the profile's original — the parent's Save handles replacing that).
    func setAvatarImagePath(_ newValue: String?) {
        if let current = avatarImagePath,
           current != originalAvatarImagePath,
           current != newValue
        {
            store.remove(at: current)
        }
        avatarImagePath = newValue
    }
}
