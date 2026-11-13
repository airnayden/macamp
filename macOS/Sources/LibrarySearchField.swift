import DesignSystem
import SwiftUI

/// The global library search field at the top of the sidebar. Typing drives the
/// shared `SearchViewModel` (FTS5); the detail pane swaps to search results while
/// the text is non-empty. Clearing it restores the selected destination.
struct LibrarySearchField: View {
    @Binding var text: String

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: tokens.spacing.xSmall) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
            TextField(String(localized: MacAMPStrings.searchPrompt), text: $text)
                .textFieldStyle(.plain)
                .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
                .accessibilityIdentifier("library.searchField")
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(MacAMPStrings.searchClear))
            }
        }
        .font(tokens.typography.body.font)
        .padding(.horizontal, tokens.spacing.small)
        .padding(.vertical, tokens.spacing.xSmall)
        .background(
            RoundedRectangle(cornerRadius: tokens.radii.small, style: .continuous)
                .fill(tokens.colors.surfaceRaised.resolve(scheme))
        )
        .padding(.horizontal, tokens.spacing.small)
        .frame(maxWidth: .infinity)
        .frame(height: MainWindowMetrics.topBarHeight)
        .onChange(of: text) { _, newValue in
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                environment.search.clear()
            } else {
                environment.search.search(trimmed)
            }
        }
    }
}
