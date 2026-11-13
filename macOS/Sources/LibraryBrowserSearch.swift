// LibraryBrowserSearch — wires ``LibraryBrowserView``'s in-view filter field to
// the DB-backed ``LibraryLocalSearchModel``.
//
// The field used to narrow the rows already paged into memory, and only in the
// folder List branch — All Tracks had no in-view filtering whatsoever. It now
// runs a real FTS5 query, narrowed to the browsed folder's subtree when one is
// selected. The keyset browse window is left completely alone while a search
// runs: `sourceTracks`, `folderModel`, `genreModel` and the shared
// `LibraryViewModel` all keep their pages, so clearing the field restores the
// list without refetching anything.
//
// A separate file from `LibraryBrowserView.swift` / `LibraryBrowserActions.swift`
// purely to keep both sources inside the SwiftLint file- and type-length budgets
// — the `LibraryBrowserPagination.swift` precedent. Members are internal because
// the sibling view file invokes them.
import Persistence
import SwiftUI
import ViewModels

extension LibraryBrowserView {
    /// The corpus the in-view field searches: the browsed folder's subtree when a
    /// library root is selected, otherwise every track visible to the profile.
    var localSearchScope: LibraryLocalSearchScope {
        if let filterRootPath {
            return .folder(rootPath: filterRootPath)
        }
        return .allTracks
    }

    /// Points the search model at the current repository, corpus and profile.
    ///
    /// Called from ``load()``, which re-fires on every `loadKey` change, so
    /// selecting a different folder or switching profile re-targets the search —
    /// and re-runs a live query against the new corpus.
    func configureLocalSearch() {
        localSearch.configure(
            reader: TrackRepository(environment.database),
            scope: localSearchScope,
            activeProfileId: activeProfileId
        )
    }

    /// The filter field's binding.
    ///
    /// Writing through it hands the text to the search model (which debounces,
    /// then queries) and clears the selection whenever the browser crosses
    /// between browse and search mode — the displayed row set is replaced
    /// wholesale at that boundary, so a carried-over selection would address rows
    /// nobody can see.
    var localFilterBinding: Binding<String> {
        Binding(
            get: { localFilter },
            set: { newValue in
                if localFilter.isEmpty != newValue.isEmpty {
                    selection.removeAll()
                }
                localFilter = newValue
                localSearch.search(newValue)
            }
        )
    }

    /// The tracks the list renders: ranked search results while the field holds a
    /// term, the paged browse window otherwise.
    ///
    /// Reading `localSearch.results` here is what republishes the list when a
    /// debounced query lands — the model is `@Observable` and held directly in
    /// `@State`, so `body` re-evaluates without an explicit `onChange`.
    var displayedTracks: [TrackRecord] {
        guard localSearch.isActive else { return sourceTracks }
        return applyingGenreFilter(localSearch.results)
    }

    /// Narrows tracks to the selected genre chip.
    ///
    /// Applied to search results **client-side**. The result window is
    /// `LIMIT`-capped (50 rows, growing by 50 per page), so this filters at most a
    /// few hundred rows — far too little to justify a second, genre-aware FTS5
    /// query. It is the same rule ``syncSourceTracks()`` applies to browse rows,
    /// so both modes narrow identically.
    func applyingGenreFilter(_ tracks: [TrackRecord]) -> [TrackRecord] {
        guard !selectedGenre.isAll else { return tracks }
        return tracks.filter { track in
            switch selectedGenre {
            case .all: true
            case .untagged: track.genre == nil || (track.genre ?? "").isEmpty
            case let .genre(name): track.genre == name
            }
        }
    }
}
