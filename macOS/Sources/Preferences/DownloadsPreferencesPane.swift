// DownloadsPreferencesPane — the Downloads tab in the macOS Settings window.
//
// Five sections: where finished downloads are written, whether they join the library,
// what container and quality they are written as, how many run at once, and which
// engine writes them (the engine half lives in
// `DownloadsPreferencesEngineSection.swift`, split purely for the 400-line budget).
// Every control binds straight to `AppSettings.downloads`, whose `didSet` persists the
// six flat scalars — so there is no save step and, deliberately, no `.onChange`:
// `AppEnvironment+Downloads.swift` re-reads the preferences through its own
// self-re-arming `withObservationTracking`, and a change handler here would apply the
// same edit twice.
//
// ── A DESTINATION IS VALIDATED BEFORE IT IS PERSISTED ────────────────────────
//
// A chosen folder passes three gates, in this order, and a refusal is surfaced inline
// and NOT written to settings:
//
//   1. app-internal — MacAMP's own Application Support / Caches containers.
//   2. karaoke cache — BIDIRECTIONALLY, through the shared `CacheDirectoryOverlapPolicy`
//      the karaoke pane and `LibraryAccessController` already use, so "overlap" has one
//      definition across all three. The cache is user-relocatable, hence the CURRENT
//      configured directory rather than the default one.
//   3. writability — MacAMP's OWN probe write, because a yt-dlp child cannot raise a TCC
//      prompt (see `DownloadDestination.swift`).
//
// The order is load-bearing: the probe CREATES the directory, so it must run only after
// the two rejections have cleared.
//
// Plain filesystem paths throughout, never a security-scoped bookmark — the macOS shell
// is non-sandboxed, matching `AppSettings.karaokeCacheDirectoryPath`.
//
// This file constructs no `Process` and no `URLSession`; `macOS/Sources/Preferences/
// Downloads*` is scanned by `scripts/check-downloader-boundary.sh`, which is why every
// pane file in this feature must keep the `Downloads` filename prefix.
import AppKit
import DesignSystem
import Foundation
import Models
import Services
import SwiftUI

/// The Downloads settings pane: destination, format/quality, engine.
struct DownloadsPreferencesPane: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        PreferencePane(
            icon: "arrow.down.circle",
            title: PreferencesStrings.tabDownloads,
            subtitle: PreferencesStrings.downloadsSubtitle
        ) {
            DownloadsDestinationSection(settings: settings)
            DownloadsLibrarySection(settings: settings)
            DownloadsFormatSection(settings: settings)
            DownloadsConcurrencySection(settings: settings)
            DownloadsEngineSection(settings: settings)
        }
    }
}

// MARK: - Destination

/// The destination readout with "Choose…" (a folder picker) and "Reset to Default",
/// surfacing a refusal inline rather than silently keeping the old folder.
private struct DownloadsDestinationSection: View {
    @Bindable var settings: AppSettings
    @State private var rejection: DownloadsDestinationRejection?

    var body: some View {
        Section {
            LabeledContent {
                Text(verbatim: displayPath)
            } label: {
                Text(PreferencesStrings.downloadsDestination)
            }
            .accessibilityIdentifier("preferences.downloads.destinationPath")
            HStack {
                chooseButton
                resetButton
            }
            if let rejection {
                DownloadsNoticeLabel(kind: .warning, text: Text(rejection.message))
                    .accessibilityIdentifier("preferences.downloads.destinationRejection")
            }
            PreferenceCaption(text: PreferencesStrings.downloadsDestinationCaption)
        }
    }

    private var chooseButton: some View {
        Button(action: chooseDirectory) {
            Text(PreferencesStrings.downloadsChooseDestination)
        }
        .pointingHandCursor()
        .help(PreferencesStrings.downloadsChooseDestinationHelp)
        .accessibilityIdentifier("preferences.downloads.chooseButton")
    }

    private var resetButton: some View {
        Button(action: resetDirectory) {
            Text(PreferencesStrings.downloadsResetDestination)
        }
        .pointingHandCursor()
        .help(PreferencesStrings.downloadsResetDestinationHelp)
        .accessibilityIdentifier("preferences.downloads.resetButton")
    }

    /// The configured folder, or the default one when nothing is configured — resolved
    /// through `DownloadDestinationLocation` so the readout can never disagree with the
    /// path the queue actually writes to.
    private var displayPath: String {
        DownloadDestinationLocation.resolve(configuredPath: settings.downloads.destinationPath).path
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        validateAndApply(url)
    }

    /// Validation touches the filesystem (and may raise a TCC prompt), so it runs off
    /// the main actor; only the settings write and the inline notice come back.
    private func validateAndApply(_ url: URL) {
        let cacheDirectory = karaokeCacheDirectory
        Task {
            let refusal = await Task.detached {
                DownloadsDestinationRejection.reject(url, karaokeCacheDirectory: cacheDirectory)
            }.value
            rejection = refusal
            settings.downloads = settings.downloads.choosingDestination(url, refusal: refusal)
        }
    }

    private func resetDirectory() {
        rejection = nil
        settings.downloads.destinationPath = nil
    }

    /// The karaoke cache as it is configured RIGHT NOW: the cache is user-relocatable,
    /// so the default directory is only the fallback, never the answer.
    private var karaokeCacheDirectory: URL? {
        settings.karaokeCacheDirectoryPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? InstrumentalCacheLocation.defaultDirectory()
    }
}

/// Why a chosen downloads folder was refused.
enum DownloadsDestinationRejection: Equatable {
    /// MacAMP's own Application Support / Caches containers.
    case appInternal
    /// Equal to, inside, or containing the current karaoke instrumental cache.
    case karaokeCache
    /// MacAMP's own probe write into the folder was refused.
    case notWritable

    var message: LocalizedStringResource {
        switch self {
        case .appInternal: PreferencesStrings.downloadsDestinationAppInternal
        case .karaokeCache: PreferencesStrings.downloadsDestinationKaraokeCache
        case .notWritable: PreferencesStrings.downloadsDestinationNotWritable
        }
    }

    /// The reason `url` cannot be a downloads destination, or `nil` when it can.
    ///
    /// The karaoke check is BIDIRECTIONAL by construction: passing the candidate as the
    /// sole "root" makes `insideRoot` mean "the cache sits under the candidate" and
    /// `containsRoot` mean "the cache contains the candidate", and either is an overlap.
    /// Same call shape `LibraryAccessController.rejectionReason(for:)` uses.
    ///
    /// `nonisolated` and filesystem-only, so the caller can run it off the main actor.
    static func reject(_ url: URL, karaokeCacheDirectory: URL?) -> DownloadsDestinationRejection? {
        if CacheDirectoryOverlapPolicy.isSystemInternalLocation(url) {
            return .appInternal
        }
        if let karaokeCacheDirectory,
           CacheDirectoryOverlapPolicy.overlap(cacheDirectory: karaokeCacheDirectory, roots: [url]) != nil
        {
            return .karaokeCache
        }
        return DownloadDestinationProbe.isWritable(url) ? nil : .notWritable
    }
}

extension DownloadPreferences {
    /// The preferences after choosing `url` as the destination: unchanged when the
    /// choice was refused.
    ///
    /// A function rather than an early `return` in the pane so "a refused folder never
    /// reaches `UserDefaults`" is an invariant a test can drive, instead of a guard
    /// whose absence would only show up as a bad folder already persisted.
    func choosingDestination(_ url: URL, refusal: DownloadsDestinationRejection?) -> DownloadPreferences {
        guard refusal == nil else { return self }
        var updated = self
        updated.destinationPath = url.path
        return updated
    }
}

// MARK: - Library

/// Whether a finished download joins the library, and what happens when it does not.
///
/// The switch ships OFF and the destination is deliberately not a library root, so
/// with no control here a downloaded track lands on disk and appears nowhere in the
/// app — the one failure `DownloadPreferences.autoImportEnabled` can cause, and one a
/// listener has no way to diagnose. The off-state caption therefore names BOTH exits:
/// this toggle, and adding the folder in the Library pane.
private struct DownloadsLibrarySection: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Section {
            Toggle(isOn: $settings.downloads.autoImportEnabled) {
                Text(PreferencesStrings.downloadsAutoImport)
            }
            .pointingHandCursor()
            .accessibilityIdentifier("preferences.downloads.autoImportToggle")
            if settings.downloads.autoImportEnabled {
                PreferenceCaption(text: PreferencesStrings.downloadsAutoImportCaption)
            } else {
                DownloadsNoticeLabel(kind: .info, text: Text(PreferencesStrings.downloadsAutoImportOffCaption))
                    .accessibilityIdentifier("preferences.downloads.autoImportOffCaption")
            }
        }
    }
}

// MARK: - Format

/// The container picker and the quality picker, the latter inert for the one format
/// that takes no quality argument at all.
private struct DownloadsFormatSection: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Section {
            formatPicker
                .pointingHandCursor()
            // The cursor advertises interactivity, so the disabled arm deliberately does
            // not carry it (the shell's disabled-state exclusion).
            if isLossless {
                qualityPicker
                    .disabled(true)
                PreferenceCaption(text: PreferencesStrings.downloadsQualityLosslessCaption)
            } else {
                qualityPicker
                    .pointingHandCursor()
            }
            PreferenceCaption(text: PreferencesStrings.downloadsFormatCaption)
        }
    }

    /// Lossless takes no `--audio-quality` argument at all, so offering the picker would
    /// promise an effect the engine cannot deliver (`YtDlpArgumentTables.audioQuality`).
    private var isLossless: Bool {
        settings.downloads.audioFormat == .flac
    }

    private var formatPicker: some View {
        Picker(selection: $settings.downloads.audioFormat) {
            ForEach(DownloadAudioFormat.allCases, id: \.self) { format in
                Text(PreferencesStrings.downloadsFormatName(format)).tag(format)
            }
        } label: {
            Text(PreferencesStrings.downloadsFormat)
        }
        .help(PreferencesStrings.downloadsFormatHelp)
        .accessibilityIdentifier("preferences.downloads.formatPicker")
    }

    private var qualityPicker: some View {
        Picker(selection: $settings.downloads.audioQuality) {
            ForEach(DownloadAudioQuality.allCases, id: \.self) { quality in
                Text(PreferencesStrings.downloadsQualityName(quality)).tag(quality)
            }
        } label: {
            Text(PreferencesStrings.downloadsQuality)
        }
        .help(PreferencesStrings.downloadsQualityHelp)
        .accessibilityIdentifier("preferences.downloads.qualityPicker")
    }
}

// MARK: - Concurrency

/// How many downloads transfer at once, and an honest account of what raising it costs.
///
/// The caption names YouTube rate-limiting explicitly rather than selling the setting
/// as free speed: parallel requests from one address are what providers throttle, and
/// a listener whose downloads start failing at 4 has no way to connect the two unless
/// this says so. The choices come from `DownloadPreferences.concurrencyChoices`, which
/// derives from `DownloadQueueLimits.maxConcurrentDownloads` — so the picker cannot
/// offer a value the queue would clamp away.
private struct DownloadsConcurrencySection: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Section {
            concurrencyPicker
                .pointingHandCursor()
            PreferenceCaption(text: PreferencesStrings.downloadsConcurrencyCaption)
        }
    }

    private var concurrencyPicker: some View {
        Picker(selection: $settings.downloads.maxConcurrent) {
            ForEach(DownloadPreferences.concurrencyChoices, id: \.self) { count in
                Text(count, format: .number).tag(count)
            }
        } label: {
            Text(PreferencesStrings.downloadsConcurrency)
        }
        .help(PreferencesStrings.downloadsConcurrencyHelp)
        .accessibilityIdentifier("preferences.downloads.concurrencyPicker")
    }
}

// MARK: - Notice row

/// A caption-styled notice row with an info or warning icon, shared by the destination
/// refusal and the engine section's status and staleness lines.
struct DownloadsNoticeLabel: View {
    enum Kind {
        case info
        case warning
    }

    let kind: Kind
    let text: Text

    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Label {
            text
                .font(tokens.typography.caption.font)
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(color)
        }
    }

    private var symbol: String {
        switch kind {
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch kind {
        case .info: tokens.colors.textSecondary.resolve(scheme)
        case .warning: tokens.colors.warning.resolve(scheme)
        }
    }
}

#Preview {
    DownloadsPreferencesPane()
        .environment(AppEnvironment.preview())
        .environment(AppSettings.preview)
        .designTokens(.standard)
}
