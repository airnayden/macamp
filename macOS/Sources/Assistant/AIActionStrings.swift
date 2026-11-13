// Localized copy for the AI actions wired into the shell's EXISTING menus — the
// track context menu, the library toolbar and the playlist context menu.
//
// Same namespace rule as ``AssistantPaneStrings``: shell-only copy keeps the shell's
// `app.*` prefix, because PlayerCore's `AssistantStrings` owns `assistant.*` and a
// re-runnable checker extracts that prefix mechanically out of `PlayerCore/Sources`.
//
// The two INTERPOLATED resources at the bottom are deliberately not hand-synced into
// `Localizable.xcstrings`: an interpolated `defaultValue` needs `%1$@` placeholders
// plus substitution metadata that only Xcode's extraction gets right, which is why
// the existing `app.preferences.enrichment.count` is absent from the catalog too.
import Foundation

enum AIActionStrings {
    // MARK: Track context menu

    static let moreLikeThis = LocalizedStringResource(
        "app.ai.action.moreLikeThis",
        defaultValue: "More Like This",
        comment: "Track context-menu item that proposes a playlist of similar tracks"
    )
    static let moreLikeThisHelp = LocalizedStringResource(
        "app.ai.action.moreLikeThisHelp",
        defaultValue: "Suggest a playlist built around this track, to review before it is saved",
        comment: "Tooltip on the More Like This context-menu item"
    )
    static let moreLikeThisUnavailable = LocalizedStringResource(
        "app.ai.action.moreLikeThisUnavailable",
        defaultValue: "This track's file is missing, so it cannot seed a playlist",
        comment: "Why More Like This is greyed out for a track whose file is gone"
    )

    // MARK: Library toolbar

    static let surpriseMe = LocalizedStringResource(
        "app.ai.action.surpriseMe",
        defaultValue: "Surprise Me",
        comment: "Library toolbar button that proposes a mix of forgotten favourites"
    )
    static let surpriseMeHelp = LocalizedStringResource(
        "app.ai.action.surpriseMeHelp",
        defaultValue: "Suggest a mix of favourites you have not played in a while",
        comment: "Tooltip on the Surprise Me toolbar button"
    )

    // MARK: Playlist context menu

    static let organize = LocalizedStringResource(
        "app.ai.action.organize",
        defaultValue: "Organize…",
        comment: "Playlist context-menu submenu holding the AI organisation actions"
    )
    static let organizeDeduplicate = LocalizedStringResource(
        "app.ai.action.organizeDeduplicate",
        defaultValue: "Remove Duplicates",
        comment: "Organize submenu item that proposes dropping repeated tracks from the playlist"
    )
    static let organizeSplit = LocalizedStringResource(
        "app.ai.action.organizeSplit",
        defaultValue: "Split by Theme",
        comment: "Organize submenu item that proposes one playlist per genre found in this playlist"
    )
    static let organizeEnergy = LocalizedStringResource(
        "app.ai.action.organizeEnergy",
        defaultValue: "Reorder by Energy",
        comment: "Organize submenu item that proposes a rise-peak-fall running order"
    )
    static let organizeRename = LocalizedStringResource(
        "app.ai.action.organizeRename",
        defaultValue: "Suggest a Name",
        comment: "Organize submenu item that proposes a new name for the playlist"
    )
    static let organizeEnergyUnavailable = LocalizedStringResource(
        "app.ai.action.organizeEnergyUnavailable",
        defaultValue: "Analyze your library in Settings ▸ Intelligence to reorder by energy",
        comment: "Why Reorder by Energy is greyed out when too little of the library has been analyzed"
    )

    // MARK: Outcomes

    static let nothingToPropose = LocalizedStringResource(
        "app.ai.action.nothingToPropose",
        defaultValue: "Nothing to suggest here yet",
        comment: "Toast shown when an AI action found no change worth proposing"
    )
    static let noDuplicates = LocalizedStringResource(
        "app.ai.action.noDuplicates",
        defaultValue: "This playlist lists nothing twice",
        comment: "Toast shown when the duplicate pass found no redundant entry"
    )
    static let noThemes = LocalizedStringResource(
        "app.ai.action.noThemes",
        defaultValue: "This playlist has no genre big enough to split out",
        comment: "Toast shown when no genre in the playlist holds enough tracks to become its own playlist"
    )
    static let alreadyInOrder = LocalizedStringResource(
        "app.ai.action.alreadyInOrder",
        defaultValue: "This playlist is already in energy order",
        comment: "Toast shown when an energy reorder would move nothing"
    )
    static let notEnoughAnalyzed = LocalizedStringResource(
        "app.ai.action.notEnoughAnalyzed",
        defaultValue: "Not enough of this playlist has been analyzed yet — run Analyze in Settings ▸ Intelligence",
        comment: "Toast shown when too few tracks in this playlist carry audio analysis for an energy arc"
    )
    static let actionBusy = LocalizedStringResource(
        "app.ai.action.busy",
        defaultValue: "Another suggestion is still being prepared",
        comment: "Toast shown when an AI action is requested while one is already running"
    )
    static let namingUnavailable = LocalizedStringResource(
        "app.ai.action.namingUnavailable",
        defaultValue: "Name suggestions are not available right now",
        comment: "Toast shown when no naming tier could suggest a playlist name"
    )

    // MARK: Generated names (interpolated — see the file header)

    /// The track menu item, naming the ONE track the mix would be seeded from.
    ///
    /// A multi-row selection seeds from the first row in display order and ignores the
    /// rest (see `seedTrack(for:)`). An unqualified "More Like This" hides that, so a
    /// listener who right-clicks eight songs reasonably expects a mix from all eight.
    /// Naming the seed makes the single-track semantics visible before the click.
    ///
    /// Deliberately NOT the same sentence as ``moreLikeName(track:)``: that one becomes
    /// the created playlist's stored name, and two identical strings on screen at once
    /// would be ambiguous to read and to assert on.
    static func moreLikeThisNamed(track: String) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.ai.action.moreLikeThisNamed",
            defaultValue: "More Like “\(track)”",
            comment: "Track context-menu item naming the single track a similarity mix would be seeded from"
        )
    }

    /// The name a "More Like This" mix is created under. Chrome shape, listener
    /// data pushed into it — the assembled string is persisted into `playlist.name`
    /// and rendered `Text(verbatim:)`, exactly like a model-generated name.
    static func moreLikeName(track: String) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.ai.action.moreLikeName",
            defaultValue: "More Like \(track)",
            comment: "Generated name of a playlist seeded from one track; the track title is substituted"
        )
    }

    /// The name a "Split by Theme" cluster is created under. Same data rule.
    static func themeName(playlist: String, genre: String) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.ai.action.themeName",
            defaultValue: "\(playlist) — \(genre)",
            comment: "Generated name of a split-out genre playlist; playlist name and genre are substituted"
        )
    }

    /// Why a selection is too short for an energy arc. The minimum comes from
    /// ``MixRanking/minimumArcLength`` rather than being spelled into the copy, so
    /// the sentence cannot drift from the rule it describes.
    static func tooShortToReorder(minimum: Int) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.ai.action.tooShortToReorder",
            defaultValue: "A playlist needs at least \(minimum) tracks to reorder by energy",
            comment: "Toast explaining an energy reorder was refused because the playlist is too short"
        )
    }

    /// Why a selection is too long. Same rule: the limit is ``MixSpec/maxTargetCount``.
    static func tooLongToReorder(limit: Int) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.ai.action.tooLongToReorder",
            defaultValue: "This playlist is too long to reorder by energy (limit \(limit) tracks)",
            comment: "Toast explaining an energy reorder was refused because the playlist exceeds the ranking limit"
        )
    }

    /// How many split-by-theme proposals were filed.
    static func themesProposed(count: Int) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.ai.action.themesProposed",
            defaultValue: "\(count) playlists to review",
            comment: "Toast reporting how many split-by-theme proposals are waiting"
        )
    }
}
