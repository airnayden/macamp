// PlaylistNameSheet — a reusable text-field sheet for creating or renaming a
// playlist.
//
// One small modal used by both flows: the browser's "+" (create) and a row's
// "Rename" action seed it with a `title`, a `confirmLabel` and an `initialName`,
// and receive the trimmed, non-empty name back through `onCommit`. The confirm
// button is disabled until the field holds non-whitespace text, so an empty
// playlist name can never be committed. All copy is token-localized; the field
// text is user data, so it binds verbatim.
import DesignSystem
import SwiftUI

/// A modal that collects a playlist name and hands the trimmed value to a caller.
struct PlaylistNameSheet: View {
    let title: LocalizedStringResource
    let confirmLabel: LocalizedStringResource
    var initialName: String = ""
    let onCommit: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                TextField(
                    text: $name,
                    prompt: Text(MacAMPStrings.playlistsNamePlaceholder)
                ) {
                    Text(MacAMPStrings.playlistsNamePlaceholder)
                }
                .focused($fieldFocused)
                .submitLabel(.done)
                .onSubmit(commit)
            }
            .navigationTitle(Text(title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .onAppear {
                name = initialName
                fieldFocused = true
            }
        }
        .presentationDetents([.height(180)])
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(role: .cancel) { dismiss() } label: {
                Text(MacAMPStrings.playlistsCancel)
            }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button(action: commit) { Text(confirmLabel) }
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
}
