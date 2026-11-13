// PlaylistViewModelConcurrencyTests — deterministic regression for the playlist
// first-paint race that Task 4 fixed (commit 577d7b6).
//
// The OLD `loadInitialPlaylists()` used the reset-then-guarded-delegate shape:
// it synchronously did `playlists = []` and then delegated to the
// `isLoadingPlaylists`-guarded `loadMorePlaylists()`. Because the reset is
// synchronous (no suspension before it), when several concurrent callers race on
// the ONE shared `@MainActor` view model, the first to reach `loadMorePlaylists()`
// sets `isLoadingPlaylists = true` and suspends on the real database read; every
// OTHER concurrent caller then runs its own synchronous `playlists = []` wipe,
// finds the guard already tripped, and returns as a silent no-op — completing its
// `loadInitialPlaylists()` on an EMPTY window. That is the empty first paint.
//
// The NOW-FIXED atomic version fetches page 1 first, then assigns
// `playlists = page.items` in one shot (no pre-wipe, no delegation to the guarded
// pager), so no caller can ever observe — or leave — an empty window.
//
// Determinism note: the race is driven purely by real `async let` suspension
// points on the shared main actor (the same technique proven in
// `GenreBrowserViewModelTests` / `FolderBrowserViewModelTests`). There is NO
// `sleep` / `Task.sleep` / wall-clock waiting anywhere — exactly one caller wins
// the guard and suspends on the GRDB read while the rest are already enqueued on
// the serial main-actor executor, so they deterministically run (and, on the old
// code, bail) before the winner resumes.
import Foundation
import Persistence
import Testing
@testable import ViewModels

@MainActor
struct PlaylistViewModelConcurrencyTests {
    private func makeModel(
        _ database: AppDatabase,
        pageSize: Int = 100
    ) -> PlaylistViewModel {
        PlaylistViewModel(
            repository: PlaylistRepository(database),
            pageSize: pageSize
        )
    }

    /// Runs one initial load and reports whether the window was empty at the
    /// exact moment THIS caller's `loadInitialPlaylists()` returned. On the old
    /// reset-then-guarded-delegate code a bailed caller returns having wiped
    /// `playlists = []` and no-op'd on the guard, so it reports `true`; the
    /// atomic fix always leaves a populated window, so it reports `false`.
    private func loadInitialReportingEmptiness(_ model: PlaylistViewModel) async throws -> Bool {
        try await model.loadInitialPlaylists()
        return model.playlists.isEmpty
    }

    // MARK: - Concurrent initial loads on one shared instance

    @Test func concurrentInitialLoadsNeverExposeAnEmptyWindow() async throws {
        let database = try AppDatabase.makeEmpty()
        let model = makeModel(database)
        _ = try await model.createPlaylist(named: "One")
        _ = try await model.createPlaylist(named: "Two")
        _ = try await model.createPlaylist(named: "Three")

        // Fire several concurrent initial loads on the ONE shared view model.
        // Each reports whether it observed an empty window at its own completion.
        async let loadOne = loadInitialReportingEmptiness(model)
        async let loadTwo = loadInitialReportingEmptiness(model)
        async let loadThree = loadInitialReportingEmptiness(model)
        async let loadFour = loadInitialReportingEmptiness(model)
        async let loadFive = loadInitialReportingEmptiness(model)
        let observedEmpty = try await [loadOne, loadTwo, loadThree, loadFour, loadFive]

        // Invariant the atomic fix guarantees: no concurrent caller ever returns
        // on an empty window, and the final window is populated.
        #expect(!observedEmpty.contains(true))
        #expect(!model.playlists.isEmpty)
        #expect(model.playlists.count == 3)
    }

    // MARK: - Reentrant initial load during in-flight pagination

    @Test func reentrantLoadInitialDuringLoadMoreNeverEmptiesPlaylistWindow() async throws {
        let database = try AppDatabase.makeEmpty()
        let model = makeModel(database, pageSize: 2)
        for index in 0 ..< 5 {
            _ = try await model.createPlaylist(named: String(format: "List %02d", index))
        }

        try await model.loadInitialPlaylists()
        #expect(model.playlists.count == 2)

        // Page forward while simultaneously reloading the first page. On the old
        // code the reload wipes the window and then bails on the guard the pager
        // is holding, returning empty; the atomic reload cannot.
        async let paging: Void = model.loadMorePlaylists()
        async let reloadObservedEmpty: Bool = loadInitialReportingEmptiness(model)
        let (_, observedEmpty) = try await (paging, reloadObservedEmpty)

        #expect(!observedEmpty)
        #expect(!model.playlists.isEmpty)
        #expect(model.playlists.count >= 2)
    }
}
