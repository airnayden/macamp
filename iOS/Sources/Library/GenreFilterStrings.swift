// GenreFilterStrings — localized copy for the iOS library genre-filter bar
// (Task 14). Kept in its own file (an `extension MacAMPStrings`) so it never
// clobbers the shared MacAMPStrings.swift while concurrent feature tasks land.
// Genre NAMES are non-translatable display text rendered with `Text(verbatim:)`
// at the call site — only these chrome labels are localized.
import Foundation

extension MacAMPStrings {
    static let genreFilterAll = LocalizedStringResource(
        "ios.library.genre.all",
        defaultValue: "All Genres",
        comment: "Genre-filter chip that clears the filter and shows every track"
    )
    static let genreFilterUntagged = LocalizedStringResource(
        "ios.library.genre.untagged",
        defaultValue: "(no genre)",
        comment: "Genre-filter chip selecting tracks that have no genre tag"
    )
    static let genreFilterAccessibilityLabel = LocalizedStringResource(
        "ios.library.genre.accessibilityLabel",
        defaultValue: "Filter by genre",
        comment: "Accessibility label for the horizontal genre-filter chip bar"
    )
}
