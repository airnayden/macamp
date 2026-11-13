// ProfileArchiveStrings — copy for the `.macampprofile` export/import entry.
//
// Split out of `ProfileStrings` (already 344 of the 400-line SwiftLint budget)
// rather than appended to it, following the repo's sibling-split remedy.
import Foundation

enum ProfileArchiveStrings {
    // MARK: - Preferences section

    static let sectionHeader = LocalizedStringResource(
        "profiles.archive.section",
        defaultValue: "Backup & Transfer",
        comment: "Header of the preferences section holding profile export and import"
    )

    static let sectionFooter = LocalizedStringResource(
        "profiles.archive.sectionFooter",
        defaultValue: "A profile file carries your listening history and replay heatmaps. It never includes your PIN, your library folders, or your profile photo.",
        comment: "Explanatory footer under the profile export/import buttons"
    )

    static let exportButton = LocalizedStringResource(
        "profiles.archive.exportButton",
        defaultValue: "Export Current Profile…",
        comment: "Button that writes the active profile to a .macampprofile file"
    )

    static let importButton = LocalizedStringResource(
        "profiles.archive.importButton",
        defaultValue: "Import Profile…",
        comment: "Button that reads a .macampprofile file in as a new profile"
    )

    // MARK: - Import opt-in

    static let importOptInTitle = LocalizedStringResource(
        "profiles.archive.importOptIn.title",
        defaultValue: "Also apply settings and equalizer presets?",
        comment: "Title of the dialog asking whether an import should apply global settings too"
    )

    static let importOptInMessage = LocalizedStringResource(
        "profiles.archive.importOptIn.message",
        defaultValue: "Listening history is always imported into a new profile. Settings and equalizer presets are shared by everyone on this Mac — applying them changes your current preferences. Existing presets are kept; imported ones are added under a new name.",
        comment: "Body of the dialog warning that imported settings apply to the whole app"
    )

    static let importEverything = LocalizedStringResource(
        "profiles.archive.importOptIn.everything",
        defaultValue: "Import Everything",
        comment: "Dialog button that imports the profile plus settings and equalizer presets"
    )

    static let importStatsOnly = LocalizedStringResource(
        "profiles.archive.importOptIn.statsOnly",
        defaultValue: "Import Listening History Only",
        comment: "Dialog button that imports the profile without touching global settings"
    )

    static let importCancel = LocalizedStringResource(
        "profiles.archive.importOptIn.cancel",
        defaultValue: "Cancel",
        comment: "Dialog button that abandons the profile import"
    )

    /// Appended to an imported equalizer preset whose name is already taken, so an
    /// existing preset is never overwritten.
    static let importedPresetSuffix = LocalizedStringResource(
        "profiles.archive.importedPresetSuffix",
        defaultValue: "(imported)",
        comment: "Suffix added to an imported equalizer preset whose name already exists"
    )

    // MARK: - Outcomes

    static let exportSucceeded = LocalizedStringResource(
        "profiles.archive.exportSucceeded",
        defaultValue: "Profile exported",
        comment: "Toast shown after a profile file is written successfully"
    )

    static let exportFailed = LocalizedStringResource(
        "profiles.archive.exportFailed",
        defaultValue: "Couldn't export this profile",
        comment: "Toast shown when writing a profile file fails"
    )

    static let importSucceeded = LocalizedStringResource(
        "profiles.archive.importSucceeded",
        defaultValue: "Profile imported",
        comment: "Toast shown after a profile file is imported successfully"
    )

    static func importSucceededWithDrops(count: Int) -> LocalizedStringResource {
        LocalizedStringResource(
            "profiles.archive.importSucceededWithDrops",
            defaultValue: "Profile imported — ^[\(count) song](inflect: true) isn't in this library, so its play counts were skipped",
            comment: "Toast shown after an import that could not match every track to the local library"
        )
    }

    static let importFailed = LocalizedStringResource(
        "profiles.archive.importFailed",
        defaultValue: "Couldn't read this profile file",
        comment: "Toast shown when a profile file is missing, corrupt, or from a newer version"
    )
}
