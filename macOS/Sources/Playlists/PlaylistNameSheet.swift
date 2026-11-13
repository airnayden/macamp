// PlaylistNameSheet — a reusable text-field sheet for creating or renaming a
// playlist on macOS.
//
// One small modal used by both flows: the browser's "New Playlist" toolbar action
// (create) and a row's "Rename" context action seed it with a `title`, a
// `confirmLabel` and an `initialName`, and receive the trimmed, non-empty name back
// through `onCommit`. The confirm button is disabled until the field holds
// non-whitespace text, so an empty playlist name can never be committed. All chrome
// is token-localized; the field text is user data, so it binds verbatim.
import DesignSystem
import SwiftUI

struct PlaylistNameSheet: View {
    let title: LocalizedStringResource
    let confirmLabel: LocalizedStringResource
    var initialName: String = ""
    let onCommit: (String) -> Void

    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: tokens.spacing.large) {
            Text(title)
                .font(tokens.typography.headline.font)
                .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
            TextField(text: $name, prompt: Text(MacAMPStrings.playlistsNamePlaceholder)) {
                Text(MacAMPStrings.playlistsNamePlaceholder)
            }
            .textFieldStyle(.roundedBorder)
            .focused($fieldFocused)
            .onSubmit(commit)
            actions
        }
        .padding(tokens.spacing.large)
        .frame(width: 360)
        .onAppear {
            name = initialName
            fieldFocused = true
        }
    }

    private var actions: some View {
        HStack(spacing: tokens.spacing.small) {
            Spacer()
            Button(role: .cancel) { dismiss() } label: {
                Text(MacAMPStrings.playlistCancel)
            }
            Button(action: commit) { Text(confirmLabel) }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedName.isEmpty)
        }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func commit() {
        let value = trimmedName
        guard !value.isEmpty else { return }
        onCommit(value)
        dismiss()
    }
}

#Preview {
    PlaylistNameSheet(
        title: MacAMPStrings.playlistsNew,
        confirmLabel: MacAMPStrings.playlistsCreate
    ) { _ in }
        .designTokens(.standard)
}
