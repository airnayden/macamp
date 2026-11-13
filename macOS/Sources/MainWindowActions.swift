// MainWindowActions — the drop-import, folder-refresh and playlist-import
// behaviour behind ``MainWindowView``. Split out (like LibraryBrowserActions) to
// keep the view file under the SwiftLint length budget; the members are internal
// (not private) because the view's body invokes them.
import Persistence
import Services
import SwiftUI
import ViewModels

extension MainWindowView {
    /// Whether the library toolbar offers "Surprise Me".
    ///
    /// ABSENT rather than disabled when the bundle is off — the whole point of a
    /// per-bundle switch is that the surface disappears. `intelligence` is `nil`
    /// exactly while the Intelligence master toggle is off, so the two conditions
    /// together are the complete gate.
    var showsSurpriseMe: Bool {
        environment.intelligence != nil && settings.isEnabled(.rediscovery)
    }

    /// Proposes a rediscovery mix, then hands it to the window's review sheet.
    ///
    /// Writes NOTHING: `proposeMix` reads, ranks and files a proposal, and only the
    /// sheet's Apply button reaches a repository.
    func surpriseMe() {
        guard let assistant = environment.intelligence?.assistant else { return }
        let profileId = environment.profileService.activeProfile.id ?? ProfileRecord.guestID
        Task { @MainActor in
            let proposal = await assistant.proposeMix(
                from: .rediscovery(list: .forgottenFavourites),
                named: String(localized: AIActionStrings.surpriseMe),
                profileId: profileId
            )
            guard let proposal else {
                environment.toast.show(text: String(localized: AIActionStrings.nothingToPropose))
                return
            }
            nav.pendingProposal = proposal
        }
    }

    func handleDrop(_ urls: [URL]) -> Bool {
        let importer = DropImporter(scanner: environment.scanner)
        let access = environment.libraryAccess
        let plan = importer.plan(for: urls, existingRoots: access.roots.map(\.url))
        guard !plan.isEmpty else { return false }
        Task { await environment.libraryFolders.importDrop(plan) }
        return true
    }

    /// Reached only from a ROOT row's context menu — subfolder rows carry no menu —
    /// so the registry path this resolves is always a configured library root.
    func removeFolder(rootId: Int64) {
        guard let path = environment.libraryFolders.sidebar.path(forId: rootId) else { return }
        environment.libraryAccess.removeRoot(matchingPath: path)
    }

    func handlePlaylistImport(_ result: Result<[URL], any Error>) {
        switch result {
        case let .success(urls):
            guard let url = urls.first else { return }
            do {
                let data = try Data(contentsOf: url)
                _ = try JSONSerialization.jsonObject(with: data)
                Task {
                    do {
                        try await environment.playlistImportExport.importPlaylist(
                            from: url,
                            profileId: environment.profileService.activeProfile.id ?? ProfileRecord.guestID
                        )
                    } catch {
                        importError = error.localizedDescription
                    }
                }
            } catch {
                importError = String(localized: MacAMPStrings.playlistImportFailed)
            }
        case let .failure(error):
            importError = error.localizedDescription
        }
    }
}
