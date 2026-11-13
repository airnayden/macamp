import DesignSystem
import SwiftUI
import ViewModels

/// The iOS genre-filter chip bar shown under the Songs scope. A thin shell adapter
/// over the reusable ``GenreFilterBarView`` (PlayerCore DesignSystem): it maps the
/// shared ``GenreFilter`` selection model and this shell's localized labels onto
/// plain chips, and reports the tapped chip back by id.
///
/// iOS uses `large` horizontal padding, adds a per-chip VoiceOver hint, and clips
/// each chip's hit area to a capsule — matching the prior in-shell component
/// byte-for-byte. Genre NAMES are non-translatable and render verbatim; only the
/// "All Genres" / "(no genre)" chrome labels are localized (definitions stay in
/// this shell's String Catalog).
struct GenreFilterChipBar: View {
    let options: [GenreFilter]
    @Binding var selection: GenreFilter

    var body: some View {
        GenreFilterBarView(
            chips: options.map { option in
                GenreFilterChip(
                    id: option.id,
                    title: chipTitle(for: option),
                    isSelected: option == selection
                )
            },
            accessibilityLabel: MacAMPStrings.genreFilterAccessibilityLabel,
            accessibilityHint: MacAMPStrings.a11yHintGenreFilter,
            horizontalPadding: \.large,
            appliesContentShape: true
        ) { id in
            if let match = options.first(where: { $0.id == id }) {
                selection = match
            }
        }
    }

    private func chipTitle(for option: GenreFilter) -> GenreFilterChip.Title {
        switch option {
        case .all: .localized(MacAMPStrings.genreFilterAll)
        case .untagged: .localized(MacAMPStrings.genreFilterUntagged)
        case let .genre(name): .verbatim(name)
        }
    }
}

#Preview {
    GenreFilterChipBar(
        options: [.all, .genre("Ambient"), .genre("Jazz"), .genre("Techno"), .untagged],
        selection: .constant(.genre("Jazz"))
    )
    .designTokens(.standard)
    .padding(.vertical)
}
