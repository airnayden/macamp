import DesignSystem
import SwiftUI

/// A heart toggle shown on a track row. Filled + accent-tinted when the track is
/// a favourite, hollow + tertiary otherwise. `.plain` button style so a tap inside
/// a `List` row toggles the favourite without selecting the row.
struct FavouriteButton: View {
    let isFavourite: Bool
    let action: () -> Void

    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            Image(systemName: isFavourite ? "heart.fill" : "heart")
                .foregroundStyle(
                    isFavourite
                        ? tokens.colors.accent.resolve(scheme)
                        : tokens.colors.textTertiary.resolve(scheme)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text(label))
        .accessibilityLabel(Text(label))
        .pointingHandCursor()
    }

    private var label: LocalizedStringResource {
        isFavourite ? FavouritesStrings.remove : FavouritesStrings.add
    }
}

#Preview {
    HStack(spacing: 16) {
        FavouriteButton(isFavourite: false) {}
        FavouriteButton(isFavourite: true) {}
    }
    .designTokens(.standard)
    .padding()
}
