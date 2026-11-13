// MenuBarStrings — user-facing copy for the macOS menu-bar mini player.
//
// Every label resolves through a `LocalizedStringResource` with an English
// `defaultValue`, so the running app and previews show real copy now and the
// dotted keys (`app.menubar.<element>`) are the single handoff list for Task 44.
// The MacAMP brand is NEVER localized — the show-main-window action pairs this
// localized verb with a `Text(verbatim:)` brand token at the call site, so the
// brand is never sent to a translator.
import Foundation

/// Localized copy for the menu-bar mini player and its actions.
enum MenuBarStrings {
    /// The verb of the show-main-window action; the non-localized MacAMP brand is
    /// appended verbatim after this word at the call site.
    static let show = LocalizedStringResource(
        "app.menubar.show",
        defaultValue: "Show",
        comment: "Menu-bar action that reveals and focuses the main window; the non-localized MacAMP brand is appended after this word"
    )
    static let quit = LocalizedStringResource(
        "app.menubar.quit",
        defaultValue: "Quit",
        comment: "Menu-bar action that quits the app"
    )
    static let miniPlayer = LocalizedStringResource(
        "app.menubar.miniPlayer",
        defaultValue: "Mini Player",
        comment: "Accessibility label for the menu-bar mini-player popover"
    )
}
