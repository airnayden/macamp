import Foundation
import Persistence
import Testing
@testable import ViewModels

/// Task 3 acceptance (d): the karaoke queue view model resolves display rows for the
/// current + pending source paths through the profile-scoped ``KaraokeReadyPaging``
/// seam, reorders the `(sortTitle, id)`-sorted query result back into QUEUE order, and
/// re-scopes to the active profile on a switch. Uses a fake paging seam (no GRDB) that
/// returns rows in sort order so the reorder is the thing under test.
@MainActor
struct KaraokeQueueViewModelTests {
    @Test func resolvesRowsInQueueOrderNotSortOrder() async throws {
        // sortTitles deliberately disagree with queue order: current sorts first,
        // pending[0] sorts LAST and pending[1] sorts MIDDLE — so a sort-ordered
        // result would put pending in [2, 1], but the queue order is [1, 2].
        let rows = [
            scoped(id: 3, path: "/m/3.flac", sortTitle: "aaa"),
            scoped(id: 1, path: "/m/1.flac", sortTitle: "zzz"),
            scoped(id: 2, path: "/m/2.flac", sortTitle: "mmm"),
        ]
        let fake = FakeQueuePaging(rowsByProfile: [1: rows])
        let model = KaraokeQueueViewModel(repository: fake, activeProfileId: 1)

        try await model.resolve(currentPath: "/m/3.flac", pendingPaths: ["/m/1.flac", "/m/2.flac"])

        #expect(model.currentRow?.track.id == 3)
        #expect(model.pendingRows.map(\.track.id) == [1, 2])
    }

    @Test func dropsPendingPathsWithNoRow() async throws {
        let rows = [
            scoped(id: 1, path: "/m/1.flac", sortTitle: "a"),
            scoped(id: 2, path: "/m/2.flac", sortTitle: "b"),
        ]
        let fake = FakeQueuePaging(rowsByProfile: [1: rows])
        let model = KaraokeQueueViewModel(repository: fake, activeProfileId: 1)

        try await model.resolve(currentPath: "/m/1.flac", pendingPaths: ["/m/missing.flac", "/m/2.flac"])

        #expect(model.currentRow?.track.id == 1)
        #expect(model.pendingRows.map(\.track.id) == [2])
    }

    @Test func reScopesToNewProfileOnSwitch() async throws {
        let guestRows = [scoped(id: 1, path: "/m/1.flac", sortTitle: "a")]
        let otherRows = [scoped(id: 2, path: "/m/2.flac", sortTitle: "b")]
        let fake = FakeQueuePaging(rowsByProfile: [1: guestRows, 42: otherRows])
        let model = KaraokeQueueViewModel(repository: fake, activeProfileId: 1)

        try await model.resolve(currentPath: "/m/1.flac", pendingPaths: [])
        #expect(model.currentRow?.track.id == 1)

        model.activeProfileId = 42
        try await model.resolve(currentPath: "/m/2.flac", pendingPaths: [])

        #expect(model.currentRow?.track.id == 2)
        #expect(fake.calls.last?.profileId == 42)
    }

    @Test func emptyQueueClearsRows() async throws {
        let fake = FakeQueuePaging(rowsByProfile: [1: [scoped(id: 1, path: "/m/1.flac", sortTitle: "a")]])
        let model = KaraokeQueueViewModel(repository: fake, activeProfileId: 1)

        try await model.resolve(currentPath: "/m/1.flac", pendingPaths: [])
        #expect(model.currentRow?.track.id == 1)

        try await model.resolve(currentPath: nil, pendingPaths: [])
        #expect(model.currentRow == nil)
        #expect(model.pendingRows.isEmpty)
    }

    /// Todo 31: post-v20 one audio file backs N rows, so the old
    /// `Dictionary(_:uniquingKeysWith:)` collapse rendered a whole cue album as ONE
    /// queue row. Sort titles are deliberately in the opposite order to the segments
    /// so the reorder to `(cueStartFrame, id)` is what is under test.
    @Test func resolvesEverySegmentOfOneFile() async throws {
        let path = "/m/disc.flac"
        let rows = [
            segment(id: 3, path: path, sortTitle: "aaa", cueStartFrame: 1500),
            segment(id: 1, path: path, sortTitle: "zzz", cueStartFrame: 0),
            segment(id: 2, path: path, sortTitle: "mmm", cueStartFrame: 750),
        ]
        let fake = FakeQueuePaging(rowsByProfile: [1: rows])
        let model = KaraokeQueueViewModel(repository: fake, activeProfileId: 1)

        try await model.resolve(currentPath: nil, pendingPaths: [path])

        #expect(model.pendingRows.count == 3)
        #expect(model.pendingRows.map(\.track.id) == [1, 2, 3])
    }

    @Test func aSuppressedWholeFileRowLeadsItsOwnSegments() async throws {
        let path = "/m/disc.flac"
        let rows = [
            segment(id: 2, path: path, sortTitle: "b", cueStartFrame: 0),
            scoped(id: 1, path: path, sortTitle: "a"),
        ]
        let fake = FakeQueuePaging(rowsByProfile: [1: rows])
        let model = KaraokeQueueViewModel(repository: fake, activeProfileId: 1)

        try await model.resolve(currentPath: path, pendingPaths: [])

        #expect(model.currentRow?.track.cueStartFrame == TrackRecord.wholeFileCueStartFrame)
        #expect(model.currentRow?.track.id == 1)
    }

    @Test func idleCurrentStillResolvesPending() async throws {
        let rows = [
            scoped(id: 1, path: "/m/1.flac", sortTitle: "z"),
            scoped(id: 2, path: "/m/2.flac", sortTitle: "a"),
        ]
        let fake = FakeQueuePaging(rowsByProfile: [1: rows])
        let model = KaraokeQueueViewModel(repository: fake, activeProfileId: 1)

        try await model.resolve(currentPath: nil, pendingPaths: ["/m/1.flac", "/m/2.flac"])

        #expect(model.currentRow == nil)
        #expect(model.pendingRows.map(\.track.id) == [1, 2]) // queue order, not sort order
    }
}

private func scoped(id: Int64, path: String, sortTitle: String) -> ProfileScopedTrack {
    ProfileScopedTrack(track: TrackRecord(id: id, filePath: path, title: sortTitle, sortTitle: sortTitle))
}

private func segment(
    id: Int64,
    path: String,
    sortTitle: String,
    cueStartFrame: Int64
) -> ProfileScopedTrack {
    ProfileScopedTrack(
        track: TrackRecord(
            id: id,
            filePath: path,
            title: sortTitle,
            sortTitle: sortTitle,
            cueSheetPath: "\(path).cue",
            cueStartFrame: cueStartFrame
        )
    )
}

/// Records each call's profile and returns the requested paths' rows in
/// `(sortTitle, id)` order — the same shape `TrackRepository.tracksByPaths` returns,
/// so the view model's reorder-to-queue-order is the thing under test.
private final class FakeQueuePaging: KaraokeReadyPaging, @unchecked Sendable {
    struct Call {
        let profileId: Int64
    }

    private let rowsByProfile: [Int64: [ProfileScopedTrack]]
    private let lock = NSLock()
    private var recorded: [Call] = []

    init(rowsByProfile: [Int64: [ProfileScopedTrack]]) {
        self.rowsByProfile = rowsByProfile
    }

    var calls: [Call] {
        lock.withLock { recorded }
    }

    func readyTracks(
        profileId: Int64,
        paths: [String],
        after _: PageCursor<String>?,
        limit: Int
    ) throws -> [ProfileScopedTrack] {
        lock.withLock { recorded.append(Call(profileId: profileId)) }
        let wanted = Set(paths)
        let ordered = (rowsByProfile[profileId] ?? [])
            .filter { wanted.contains($0.track.filePath) }
            .sorted(by: Self.keysetBefore)
        return Array(ordered.prefix(limit))
    }

    private static func keysetBefore(_ lhs: ProfileScopedTrack, _ rhs: ProfileScopedTrack) -> Bool {
        let leftKey = lhs.track.sortTitle ?? ""
        let rightKey = rhs.track.sortTitle ?? ""
        if leftKey != rightKey { return leftKey < rightKey }
        return (lhs.track.id ?? 0) < (rhs.track.id ?? 0)
    }
}
