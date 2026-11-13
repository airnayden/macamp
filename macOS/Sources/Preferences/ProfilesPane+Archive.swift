// ProfilesPane+Archive — the `.macampprofile` export/import entry.
//
// Both actions are two-phase: an AppKit panel on the main actor (which must block
// on `runModal`), then the gathering/encoding/import in a `Task` whose work runs
// off-main inside `ProfileArchiveExporter` / `ProfileArchiveImporter`.
//
// Import is deliberately a TWO-STEP gesture. Listening history restores into a new
// profile unconditionally, but settings and equalizer presets are global to this
// Mac, so applying them is an explicit choice with the consequence spelled out —
// never the default and never silent.
import Persistence
import SwiftUI

extension ProfilesPreferencesPane {
    var archiveSection: some View {
        Section {
            Button { exportActiveProfile() } label: {
                Text(ProfileArchiveStrings.exportButton)
            }
            .accessibilityIdentifier("preferences.profiles.exportButton")
            .disabled(isArchiveBusy)
            Button { beginImport() } label: {
                Text(ProfileArchiveStrings.importButton)
            }
            .accessibilityIdentifier("preferences.profiles.importButton")
            .disabled(isArchiveBusy)
            PreferenceCaption(text: ProfileArchiveStrings.sectionFooter)
        } header: {
            Text(ProfileArchiveStrings.sectionHeader)
        }
    }
}

// MARK: - Export

extension ProfilesPreferencesPane {
    func exportActiveProfile() {
        let profile = environment.profileService.activeProfile
        guard let profileId = profile.id else { return }
        let suggested = ProfileArchiveExporter.suggestedFileName(for: displayName(profile))
        guard let destination = ProfileArchivePanels.chooseExportDestination(suggestedFileName: suggested) else {
            return
        }
        let exporter = ProfileArchiveExporter(environment.database)
        let snapshot = PortableSettings(settings)
        let toast = environment.toast
        isArchiveBusy = true
        Task {
            defer { isArchiveBusy = false }
            do {
                try await exporter.export(profileId: profileId, settings: snapshot, to: destination)
                toast.show(
                    text: String(localized: ProfileArchiveStrings.exportSucceeded),
                    icon: "checkmark.circle.fill"
                )
            } catch {
                toast.show(
                    text: String(localized: ProfileArchiveStrings.exportFailed),
                    icon: "exclamationmark.triangle"
                )
            }
        }
    }
}

// MARK: - Import

extension ProfilesPreferencesPane {
    func beginImport() {
        guard let source = ProfileArchivePanels.chooseImportFile() else { return }
        pendingImportURL = source
    }

    func performImport(applyingGlobals: Bool) {
        guard let source = pendingImportURL else { return }
        pendingImportURL = nil
        let importer = ProfileArchiveImporter(environment.database)
        let suffix = String(localized: ProfileArchiveStrings.importedPresetSuffix)
        let profileService = environment.profileService
        let toast = environment.toast
        isArchiveBusy = true
        Task {
            defer { isArchiveBusy = false }
            do {
                let summary = try await importer.importArchive(
                    at: source,
                    applyingSettingsAndEQPresets: applyingGlobals,
                    importedPresetSuffix: suffix
                )
                profileService.reload()
                summary.settings?.apply(to: settings)
                toast.show(text: Self.importOutcomeText(summary), icon: "checkmark.circle.fill")
            } catch {
                toast.show(
                    text: String(localized: ProfileArchiveStrings.importFailed),
                    icon: "exclamationmark.triangle"
                )
            }
        }
    }

    /// Reports the unmatched-counter drop count when there is one, so a partially
    /// matched import never looks like a complete one.
    static func importOutcomeText(_ summary: ProfileArchiveImportSummary) -> String {
        guard summary.droppedTrackStates > 0 else {
            return String(localized: ProfileArchiveStrings.importSucceeded)
        }
        let resource = ProfileArchiveStrings.importSucceededWithDrops(count: summary.droppedTrackStates)
        return String(AttributedString(localized: resource).characters)
    }
}
