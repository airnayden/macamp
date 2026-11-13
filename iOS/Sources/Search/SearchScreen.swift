// SearchScreen — the dedicated full-text search tab, bound to `SearchViewModel`.
//
// A `.searchable` field drives the debounced FTS5 search (the same shared
// `SearchViewModel` the library's inline field uses). Ranked results render in a
// `PlayableTrackList` (windowed — `loadMore()` grows the result LIMIT as the user
// scrolls), under a token-styled results header that floats on the `canvas`. Idle,
// loading and no-result states are centered token-styled `StateView`s. The whole
// surface sits on the token `canvas` for the streaming-player look (matching the
// Library browser); the result list's own background is hidden so it shows through.
import DesignSystem
import SwiftUI

/// The search screen.
struct SearchScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(tokens.colors.canvas.resolve(scheme))
                .navigationTitle(Text(MacAMPStrings.searchTitle))
                .searchable(text: $searchText, prompt: Text(MacAMPStrings.searchPrompt))
                .onChange(of: searchText) { _, value in environment.search.search(value) }
        }
    }

    @ViewBuilder
    private var content: some View {
        if trimmedQuery.isEmpty {
            idleState
        } else if environment.search.results.isEmpty {
            noResults
        } else {
            results
        }
    }

    private var trimmedQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Results

private extension SearchScreen {
    var results: some View {
        VStack(spacing: 0) {
            resultsHeader
            PlayableTrackList(tracks: environment.search.results) {
                environment.search.loadMore()
            }
            .scrollContentBackground(.hidden)
        }
    }

    /// A token-styled section header floating on the canvas: a "Results" label, a
    /// count badge for the loaded window, and a trailing spinner while a debounced
    /// search is still in flight.
    var resultsHeader: some View {
        HStack(spacing: tokens.spacing.xSmall) {
            Text(MacAMPStrings.searchResultsHeader)
                .font(tokens.typography.headline.font)
                .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))

            Text(verbatim: "\(environment.search.results.count)")
                .font(tokens.typography.caption.font)
                .monospacedDigit()
                .foregroundStyle(tokens.colors.accent.resolve(scheme))
                .padding(.horizontal, tokens.spacing.xSmall)
                .padding(.vertical, tokens.spacing.xxSmall / 2)
                .background(
                    Capsule(style: .continuous)
                        .fill(tokens.colors.accentMuted.resolve(scheme))
                )

            Spacer(minLength: 0)

            if environment.search.isSearching {
                ProgressView()
                    .controlSize(.small)
                    .tint(tokens.colors.accent.resolve(scheme))
            }
        }
        .padding(.horizontal, tokens.spacing.large)
        .padding(.top, tokens.spacing.small)
        .padding(.bottom, tokens.spacing.xSmall)
    }
}

// MARK: - Empty / loading states

private extension SearchScreen {
    var idleState: some View {
        StateView(
            systemImage: "magnifyingglass",
            title: MacAMPStrings.searchIdleTitle,
            message: MacAMPStrings.searchIdleMessage
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    var noResults: some View {
        if environment.search.isSearching {
            StateView.loading()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            StateView(
                systemImage: "questionmark.circle",
                title: MacAMPStrings.searchEmptyTitle,
                message: MacAMPStrings.searchEmptyMessage
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

#Preview {
    SearchScreen()
        .environment(AppEnvironment.preview())
        .designTokens(.standard)
}
