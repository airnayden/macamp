// DownloadsPreferencesEngineSection — the Engine section of the Downloads pane.
//
// Split out of `DownloadsPreferencesPane.swift` for the SwiftLint 400-line file budget,
// and named with the same `Downloads` prefix so it stays inside the
// `macOS/Sources/Preferences/Downloads*` scan of `scripts/check-downloader-boundary.sh`.
//
// ── NO UPDATE LOGIC LIVES HERE ───────────────────────────────────────────────
//
// The version string, the release-feed check and the install are all
// `DownloadToolProviding` calls on the ONE `DownloadToolManager` the queue already runs
// on (`AppEnvironment.downloadTools`). This section owns the presentation and nothing
// else: no `Process`, no `URLSession`, no second manager over the tools directory.
//
// The update result is reported through `AppEnvironment.showDownloadEngineUpdateToast(_:)`
// — the third leg of the download toast policy, which lives beside the other two in
// `DownloadsUIWiring.swift` rather than being spelled a fourth time here.
//
// ── THE BUTTON IS DISABLED AS WELL AS REFUSED ────────────────────────────────
//
// `DownloadToolManager.applyUpdate()` already refuses while the queue reports an
// in-flight item — replacing the binary underneath a running child is the failure this
// prevents. The button is ALSO disabled, with a caption saying why, because a control
// that silently declines is worse than one that explains itself. Belt and braces: the
// refusal is the guarantee, the disabled state is the courtesy.
import DesignSystem
import Foundation
import Services
import SwiftUI

/// The installed engine version, a manual update check, and the update itself.
struct DownloadsEngineSection: View {
    let settings: AppSettings

    @Environment(AppEnvironment.self) private var environment
    @State private var version: String?
    @State private var status: DownloadsEngineStatus = .idle

    var body: some View {
        Section {
            versionRow
            HStack {
                checkButton
                updateButton
            }
            if isDownloadInFlight {
                PreferenceCaption(text: PreferencesStrings.downloadsEngineBusyCaption)
                    .accessibilityIdentifier("preferences.downloads.engineBusyCaption")
            }
            lastCheckedRow
            if isStale {
                DownloadsNoticeLabel(kind: .warning, text: Text(PreferencesStrings.downloadsEngineStale))
                    .accessibilityIdentifier("preferences.downloads.engineStaleCaption")
            }
            if let message = status.message {
                DownloadsNoticeLabel(kind: status.isFailure ? .warning : .info, text: Text(message))
                    .accessibilityIdentifier("preferences.downloads.engineStatus")
            }
        }
        .task { await loadVersion() }
    }

    private var versionRow: some View {
        LabeledContent {
            Text(verbatim: version ?? "—")
        } label: {
            Text(PreferencesStrings.downloadsEngineVersion)
        }
        .accessibilityIdentifier("preferences.downloads.engineVersion")
    }

    private var lastCheckedRow: some View {
        LabeledContent {
            lastCheckedValue
        } label: {
            Text(PreferencesStrings.downloadsEngineLastChecked)
        }
        .accessibilityIdentifier("preferences.downloads.engineLastChecked")
    }

    @ViewBuilder
    private var lastCheckedValue: some View {
        if let checked = settings.downloads.lastEngineUpdateCheck {
            Text(verbatim: checked.formatted(date: .abbreviated, time: .shortened))
        } else {
            Text(PreferencesStrings.downloadsEngineNeverChecked)
        }
    }

    private var checkButton: some View {
        Button(action: checkForUpdate) {
            Text(PreferencesStrings.downloadsEngineCheck)
        }
        .disabled(status.isBusy)
        .pointingHandCursor()
        .help(PreferencesStrings.downloadsEngineCheckHelp)
        .accessibilityIdentifier("preferences.downloads.engineCheckButton")
    }

    /// Disabled while a download is running — see the file header for why that is a
    /// courtesy on top of the manager's own refusal, not the guarantee itself.
    @ViewBuilder
    private var updateButton: some View {
        let button = Button(action: applyUpdate) {
            Text(PreferencesStrings.downloadsEngineUpdate)
        }
        .help(PreferencesStrings.downloadsEngineUpdateHelp)
        .accessibilityIdentifier("preferences.downloads.engineUpdateButton")
        if isUpdateBlocked {
            button.disabled(true)
        } else {
            button.pointingHandCursor()
        }
    }

    private var isUpdateBlocked: Bool {
        status.isBusy || isDownloadInFlight
    }

    /// Mirrors the manager's own refusal condition, read from the queue projection the
    /// Downloads pane already maintains: an engine update is refused while ANY download
    /// is active, not merely while a single in-flight row exists.
    ///
    /// `hasActiveDownloads`, never `isWorking`: a paused queue still has its already-
    /// running transfers in flight, and those are exactly the children whose binary must
    /// not be swapped underneath them.
    private var isDownloadInFlight: Bool {
        environment.downloadsModel?.hasActiveDownloads ?? false
    }

    private var isStale: Bool {
        version.map { DownloadEngineVersionAge.isStale($0) } ?? false
    }

    private func loadVersion() async {
        guard let tools = environment.downloadTools else { return }
        version = try? await tools.version()
    }

    private func checkForUpdate() {
        guard let tools = environment.downloadTools else { return }
        status = .checking
        Task {
            do {
                let availability = try await tools.checkForUpdate()
                version = availability.installedVersion
                settings.downloads.lastEngineUpdateCheck = Date()
                switch availability {
                case .upToDate:
                    status = .upToDate
                case let .updateAvailable(_, latest):
                    status = .updateAvailable(latest)
                }
            } catch {
                status = .checkFailed
            }
        }
    }

    private func applyUpdate() {
        guard let tools = environment.downloadTools else { return }
        status = .updating
        Task {
            do {
                let installed = try await tools.applyUpdate()
                version = installed
                status = .upToDate
                settings.downloads.lastEngineUpdateCheck = Date()
                environment.showDownloadEngineUpdateToast(.success(installed))
            } catch {
                status = .checkFailed
                environment.showDownloadEngineUpdateToast(.failure(error))
            }
        }
    }
}

/// What the engine section last did, and what it should say about it.
enum DownloadsEngineStatus: Equatable {
    case idle
    case checking
    case updating
    case upToDate
    case updateAvailable(String)
    case checkFailed

    /// Whether a check or an install is in flight, which disables both buttons.
    var isBusy: Bool {
        self == .checking || self == .updating
    }

    var isFailure: Bool {
        self == .checkFailed
    }

    var message: LocalizedStringResource? {
        switch self {
        case .idle: nil
        case .checking: PreferencesStrings.downloadsEngineChecking
        case .updating: PreferencesStrings.downloadsEngineUpdating
        case .upToDate: PreferencesStrings.downloadsEngineUpToDate
        case let .updateAvailable(latest): PreferencesStrings.downloadsEngineUpdateAvailable(latest)
        case .checkFailed: PreferencesStrings.downloadsEngineCheckFailed
        }
    }
}

/// How old the installed engine is, read from its own version string.
///
/// yt-dlp tags releases `YYYY.MM.DD[.rev]`, so the tag IS the release date — which is a
/// better staleness signal than the last-check timestamp, because checking and finding
/// nothing new does not make an old engine current. An unparseable tag is reported as
/// NOT stale: a false alarm about a version this code does not understand would be worse
/// than staying quiet.
enum DownloadEngineVersionAge {
    /// YouTube's breakage cadence, not the engine's release cadence — the engine ships
    /// far more often than this; ninety days is when silence starts to be suspicious.
    static let staleAfterDays = 90

    static func isStale(_ version: String, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard let released = releaseDate(from: version),
              let days = calendar.dateComponents([.day], from: released, to: now).day
        else { return false }
        return days > staleAfterDays
    }

    /// The date encoded in a `YYYY.MM.DD[.rev]` tag, or `nil` for any other shape.
    static func releaseDate(from version: String, calendar: Calendar = .current) -> Date? {
        let fields = version.split(separator: ".").prefix(3).compactMap { Int($0) }
        guard fields.count == 3, isPlausibleDate(fields) else { return nil }
        return calendar.date(from: DateComponents(year: fields[0], month: fields[1], day: fields[2]))
    }

    private static func isPlausibleDate(_ fields: [Int]) -> Bool {
        fields[0] >= 2000 && (1 ... 12).contains(fields[1]) && (1 ... 31).contains(fields[2])
    }
}
