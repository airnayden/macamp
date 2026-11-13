// DownloadsPreferencesStrings — user-facing copy for the Downloads settings pane.
//
// Split out of `PreferencesStrings` (which sits at the 400-line file ceiling) so the
// Downloads pane's copy lives beside the pane, exactly as `KaraokePreferencesStrings`
// does. Same conventions as its parent: every label is a `LocalizedStringResource`
// with an English `defaultValue` and a dotted `app.preferences.downloads.*` key, which
// together are the single handoff list for Task 44's translations.
//
// NAMESPACE NOTE: this extends `PreferencesStrings` — the SETTINGS namespace — while
// the Downloads sidebar/toast copy stays on `MacAMPStrings` (`macOS/Sources/Downloads/
// DownloadsStrings.swift`). The split follows the surface, not the feature: a pane
// label and a toast are read in different places and translated in different contexts.
import Foundation
import Services

extension PreferencesStrings {
    // MARK: - Pane chrome

    static let tabDownloads = LocalizedStringResource(
        "app.preferences.tab.downloads",
        defaultValue: "Downloads",
        comment: "Preferences tab: where YouTube downloads are saved and in which format"
    )
    static let downloadsSubtitle = LocalizedStringResource(
        "app.preferences.downloads.subtitle",
        defaultValue: "Choose where downloads are saved and how they sound.",
        comment: "One-line subtitle under the Downloads preferences pane title"
    )

    // MARK: - Destination

    static let downloadsDestination = LocalizedStringResource(
        "app.preferences.downloads.destination",
        defaultValue: "Save downloads to",
        comment: "Label for the readout showing the folder finished downloads are written to"
    )
    static let downloadsChooseDestination = LocalizedStringResource(
        "app.preferences.downloads.destination.choose",
        defaultValue: "Choose…",
        comment: "Button that opens a folder picker to choose the downloads destination"
    )
    static let downloadsChooseDestinationHelp = LocalizedStringResource(
        "app.preferences.downloads.destination.choose.help",
        defaultValue: "Pick the folder finished downloads are saved into.",
        comment: "Tooltip for the button that opens the downloads destination folder picker"
    )
    static let downloadsResetDestination = LocalizedStringResource(
        "app.preferences.downloads.destination.reset",
        defaultValue: "Reset to Default",
        comment: "Button that restores the default downloads destination folder"
    )
    static let downloadsResetDestinationHelp = LocalizedStringResource(
        "app.preferences.downloads.destination.reset.help",
        defaultValue: "Save downloads to the default folder in your Music folder again.",
        comment: "Tooltip for the button that restores the default downloads destination"
    )
    static let downloadsDestinationCaption = LocalizedStringResource(
        "app.preferences.downloads.destination.caption",
        defaultValue: """
        Downloads are saved here. This folder stays yours — MacAMP never scans or watches \
        it on its own.
        """,
        comment: "Explains that the downloads folder is the listener's own and is not watched by the app"
    )
    static let downloadsAutoImport = LocalizedStringResource(
        "app.preferences.downloads.autoImport",
        defaultValue: "Add finished downloads to my library",
        comment: "Toggle that adds each finished download to the music library automatically"
    )
    static let downloadsAutoImportCaption = LocalizedStringResource(
        "app.preferences.downloads.autoImport.caption",
        defaultValue: "Each finished download is added to your library as soon as it is saved.",
        comment: "Caption shown while automatic import of finished downloads is switched on"
    )
    static let downloadsAutoImportOffCaption = LocalizedStringResource(
        "app.preferences.downloads.autoImport.offCaption",
        defaultValue: """
        Downloads are still saved to the folder above, but they will not appear in your \
        library. Turn this on, or add that folder in Settings ▸ Library.
        """,
        comment: "Caption shown while automatic import is off, naming both ways to reach the files"
    )
    static let downloadsDestinationAppInternal = LocalizedStringResource(
        "app.preferences.downloads.destination.rejected.appInternal",
        defaultValue: "That folder is one MacAMP keeps its own files in. Choose a folder of your own.",
        comment: "Shown when a chosen downloads folder sits inside the app's Application Support or Caches"
    )
    static let downloadsDestinationKaraokeCache = LocalizedStringResource(
        "app.preferences.downloads.destination.rejected.karaokeCache",
        defaultValue: "That folder overlaps the karaoke cache. Choose a folder outside it.",
        comment: "Shown when a chosen downloads folder contains, or sits inside, the karaoke cache directory"
    )
    static let downloadsDestinationNotWritable = LocalizedStringResource(
        "app.preferences.downloads.destination.rejected.notWritable",
        defaultValue: """
        MacAMP can't write to that folder. Choose a different one, or grant access in \
        System Settings ▸ Privacy & Security ▸ Files and Folders.
        """,
        comment: "Shown when the app's own write probe into a chosen downloads folder was refused"
    )

    // MARK: - Format

    static let downloadsFormat = LocalizedStringResource(
        "app.preferences.downloads.format",
        defaultValue: "Format",
        comment: "Label for the picker choosing the container downloads are saved as"
    )
    static let downloadsFormatHelp = LocalizedStringResource(
        "app.preferences.downloads.format.help",
        defaultValue: "The audio container finished downloads are saved as.",
        comment: "Tooltip for the downloads format picker"
    )
    static let downloadsQuality = LocalizedStringResource(
        "app.preferences.downloads.quality",
        defaultValue: "Quality",
        comment: "Label for the picker choosing how aggressively the download engine chases bitrate"
    )
    static let downloadsQualityHelp = LocalizedStringResource(
        "app.preferences.downloads.quality.help",
        defaultValue: "How much bitrate the engine asks for when it has a choice.",
        comment: "Tooltip for the downloads quality picker"
    )
    static let downloadsFormatCaption = LocalizedStringResource(
        "app.preferences.downloads.format.caption",
        defaultValue: """
        Applies to downloads you add from now on. Items already queued or downloading \
        keep the settings they started with.
        """,
        comment: "Explains that format and quality changes reach future downloads only"
    )
    static let downloadsQualityLosslessCaption = LocalizedStringResource(
        "app.preferences.downloads.quality.lossless.caption",
        defaultValue: "FLAC is lossless, so it takes no quality setting.",
        comment: "Explains why the quality picker is disabled while the FLAC format is chosen"
    )

    // MARK: - Concurrency

    static let downloadsConcurrency = LocalizedStringResource(
        "app.preferences.downloads.concurrency",
        defaultValue: "Simultaneous downloads",
        comment: "Label for the picker choosing how many downloads transfer at the same time"
    )
    static let downloadsConcurrencyHelp = LocalizedStringResource(
        "app.preferences.downloads.concurrency.help",
        defaultValue: "How many downloads transfer at the same time.",
        comment: "Tooltip for the picker choosing how many downloads transfer at once"
    )
    static let downloadsConcurrencyCaption = LocalizedStringResource(
        "app.preferences.downloads.concurrency.caption",
        defaultValue: """
        More at once is not always faster: every transfer shares your connection, and \
        asking YouTube for several at a time can make it slow down or temporarily refuse \
        requests from your IP address. If downloads start failing, set this back to 1. \
        A change applies to downloads that start from now on — anything already \
        transferring finishes.
        """,
        comment: """
        Explains the honest tradeoff of parallel downloads: shared bandwidth plus \
        possible YouTube rate-limiting of the listener's IP, and that the change is not \
        retroactive
        """
    )

    /// The display name of one download container.
    static func downloadsFormatName(_ format: DownloadAudioFormat) -> LocalizedStringResource {
        switch format {
        case .m4a: downloadsFormatM4A
        case .mp3: downloadsFormatMP3
        case .opus: downloadsFormatOpus
        case .flac: downloadsFormatFLAC
        }
    }

    /// The display name of one download quality tier.
    static func downloadsQualityName(_ quality: DownloadAudioQuality) -> LocalizedStringResource {
        switch quality {
        case .best: downloadsQualityBest
        case .high: downloadsQualityHigh
        case .medium: downloadsQualityMedium
        }
    }

    static let downloadsFormatM4A = LocalizedStringResource(
        "app.preferences.downloads.format.m4a",
        defaultValue: "M4A (AAC) — no re-encode",
        comment: "Download format option: AAC in an MP4 container, which YouTube serves natively"
    )
    static let downloadsFormatMP3 = LocalizedStringResource(
        "app.preferences.downloads.format.mp3",
        defaultValue: "MP3",
        comment: "Download format option: MPEG-1 Layer III"
    )
    static let downloadsFormatOpus = LocalizedStringResource(
        "app.preferences.downloads.format.opus",
        defaultValue: "Opus",
        comment: "Download format option: Opus in an Ogg container"
    )
    static let downloadsFormatFLAC = LocalizedStringResource(
        "app.preferences.downloads.format.flac",
        defaultValue: "FLAC (Lossless)",
        comment: "Download format option: Free Lossless Audio Codec"
    )
    static let downloadsQualityBest = LocalizedStringResource(
        "app.preferences.downloads.quality.best",
        defaultValue: "Best",
        comment: "Download quality option: the highest bitrate the source offers"
    )
    static let downloadsQualityHigh = LocalizedStringResource(
        "app.preferences.downloads.quality.high",
        defaultValue: "High",
        comment: "Download quality option: a high bitrate, trading a little fidelity for size"
    )
    static let downloadsQualityMedium = LocalizedStringResource(
        "app.preferences.downloads.quality.medium",
        defaultValue: "Medium",
        comment: "Download quality option: a mid bitrate, prioritizing file size"
    )

    // MARK: - Engine

    static let downloadsEngineVersion = LocalizedStringResource(
        "app.preferences.downloads.engine.version",
        defaultValue: "Download engine",
        comment: "Label for the readout showing the installed download-engine version"
    )
    static let downloadsEngineCheck = LocalizedStringResource(
        "app.preferences.downloads.engine.check",
        defaultValue: "Check for Updates",
        comment: "Button that asks the engine's release feed whether a newer build exists"
    )
    static let downloadsEngineCheckHelp = LocalizedStringResource(
        "app.preferences.downloads.engine.check.help",
        defaultValue: "Ask whether a newer download engine has been published.",
        comment: "Tooltip for the download-engine update check button"
    )
    static let downloadsEngineUpdate = LocalizedStringResource(
        "app.preferences.downloads.engine.update",
        defaultValue: "Update Engine",
        comment: "Button that downloads and installs the newest download engine"
    )
    static let downloadsEngineUpdateHelp = LocalizedStringResource(
        "app.preferences.downloads.engine.update.help",
        defaultValue: "Download and install the newest engine. Your app is not replaced.",
        comment: "Tooltip for the download-engine update button"
    )
    static let downloadsEngineBusyCaption = LocalizedStringResource(
        "app.preferences.downloads.engine.busy.caption",
        defaultValue: "The engine can't be replaced while a download is running. Try again once the queue finishes.",
        comment: "Explains why the engine update button is disabled during a download"
    )
    static let downloadsEngineLastChecked = LocalizedStringResource(
        "app.preferences.downloads.engine.lastChecked",
        defaultValue: "Last checked",
        comment: "Label for the readout showing when the engine was last checked for updates"
    )
    static let downloadsEngineNeverChecked = LocalizedStringResource(
        "app.preferences.downloads.engine.lastChecked.never",
        defaultValue: "Never",
        comment: "Shown in place of a date when the download engine has never been checked for updates"
    )
    static let downloadsEngineStale = LocalizedStringResource(
        "app.preferences.downloads.engine.stale",
        defaultValue: """
        This engine is more than 90 days old. YouTube changes often, so an old engine \
        may start failing — check for an update.
        """,
        comment: "Warning shown when the installed download engine's own release date is over 90 days ago"
    )
    static let downloadsEngineChecking = LocalizedStringResource(
        "app.preferences.downloads.engine.checking",
        defaultValue: "Checking for a newer engine…",
        comment: "Status shown while the download engine's release feed is being read"
    )
    static let downloadsEngineUpdating = LocalizedStringResource(
        "app.preferences.downloads.engine.updating",
        defaultValue: "Installing the newer engine…",
        comment: "Status shown while a download-engine update is being installed"
    )
    static let downloadsEngineUpToDate = LocalizedStringResource(
        "app.preferences.downloads.engine.upToDate",
        defaultValue: "The download engine is up to date.",
        comment: "Status shown when the installed download engine is the newest published build"
    )
    static let downloadsEngineCheckFailed = LocalizedStringResource(
        "app.preferences.downloads.engine.checkFailed",
        defaultValue: "Couldn't reach the engine's release feed. Check your connection, then try again.",
        comment: "Status shown when the download-engine update check could not complete"
    )

    /// The status line naming a published engine build newer than the installed one.
    static func downloadsEngineUpdateAvailable(_ latest: String) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.preferences.downloads.engine.updateAvailable",
            defaultValue: "Version \(latest) is available.",
            comment: "Status naming the newer download-engine version that can be installed"
        )
    }
}
