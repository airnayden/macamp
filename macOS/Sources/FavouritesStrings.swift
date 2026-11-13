// FavouritesStrings — user-facing copy for the Favourites sidebar destination and
// the heart toggle, centralized as `LocalizedStringResource` keys with an English
// `defaultValue`, exactly like `FolderSidebarStrings` / `MacAMPStrings`.
import Foundation

/// Localized copy for the Favourites feature (sidebar row, view, heart toggle).
enum FavouritesStrings {
    static let title = LocalizedStringResource(
        "app.favourites.title",
        defaultValue: "Favourites",
        comment: "Sidebar item and view title for the user's favourited tracks"
    )
    static let add = LocalizedStringResource(
        "app.favourites.add",
        defaultValue: "Add to Favourites",
        comment: "Tooltip / command that marks a track as a favourite"
    )
    static let remove = LocalizedStringResource(
        "app.favourites.remove",
        defaultValue: "Remove from Favourites",
        comment: "Tooltip / command that removes a track from favourites"
    )
    static let emptyTitle = LocalizedStringResource(
        "app.favourites.empty.title",
        defaultValue: "No Favourites",
        comment: "Title shown in the Favourites view when no track is favourited"
    )
    static let emptyMessage = LocalizedStringResource(
        "app.favourites.empty.message",
        defaultValue: "Tap the heart on any track to add it here.",
        comment: "Body shown in the Favourites view when no track is favourited"
    )
    static let addedToast = LocalizedStringResource(
        "app.favourites.toast.added",
        defaultValue: "Added to Favourites",
        comment: "Toast shown after a track is added to favourites"
    )
    static let removedToast = LocalizedStringResource(
        "app.favourites.toast.removed",
        defaultValue: "Removed from Favourites",
        comment: "Toast shown after a track is removed from favourites"
    )
}
