import DesignSystem
import Persistence
import SwiftUI

/// A compact client-side filter field for narrowing an already-loaded list
/// (folders, playlists) in memory, without hitting the database.
struct LocalFilterField: View {
    @Binding var text: String

    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: tokens.spacing.xSmall) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
            TextField(String(localized: MacAMPStrings.searchFilterPrompt), text: $text)
                .textFieldStyle(.plain)
                .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(MacAMPStrings.searchClear))
            }
        }
        .font(tokens.typography.caption.font)
        .padding(.horizontal, tokens.spacing.small)
        .padding(.vertical, tokens.spacing.xSmall)
        .background(
            RoundedRectangle(cornerRadius: tokens.radii.small, style: .continuous)
                .fill(tokens.colors.surfaceRaised.resolve(scheme))
        )
        .frame(maxWidth: 260)
    }
}

extension TrackRecord {
    func matchesFilter(_ query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        return [title, artistName, albumTitle].contains { field in
            guard let field, !field.isEmpty else { return false }
            return field.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}
