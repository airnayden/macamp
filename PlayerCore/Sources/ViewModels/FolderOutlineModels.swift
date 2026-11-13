// FolderOutlineModels — the read seam and the row value types behind
// ``FolderOutlineViewModel``, the main window's hierarchical folder browser.
//
// Split out of the view model exactly as `FolderTreeModels.swift` was split out of
// ``FolderSidebarViewModel``: the value types are what the shell renders and what
// the tests assert over, and keeping them here holds both files inside SwiftLint's
// file- and type-length budgets.
import Foundation

// Load-bearing despite no GRDB symbol appearing here: `PageCursor<String>` needs
// `String: DatabaseValueConvertible` visible in THIS file (`LibraryViewModel.swift`
// carries the same import for the same reason).
import GRDB
import Models
import Persistence

// MARK: - Read seam

/// The three repository calls the folder outline needs.
///
/// A NEW narrow protocol rather than a `TrackRepositoryProviding` requirement —
/// the ``FolderTreeReading`` / ``LibraryLocalSearchReading`` precedent. Two of the
/// three members (`childFolders`, `tracksDirectlyIn`) live only on the concrete
/// ``TrackRepository``, so adding them to the shared repository protocol would
/// force a forwarding method into every unrelated test decorator for no benefit.
/// The empty conformance below works because the concrete methods' default
/// arguments do not change their function types — which is also why `sort` carries
/// no default here (Swift forbids one on a protocol requirement) while
/// ``TrackRepository/tracksDirectlyIn(profileId:dirPath:after:limit:sort:)`` keeps
/// its own. Every call through `any FolderOutlineReading` passes `sort` explicitly.
public protocol FolderOutlineReading: Sendable {
    func childFolders(profileId: Int64, parentPath: String) throws -> [FolderChildSummary]
    func tracksDirectlyIn(
        profileId: Int64,
        dirPath: String,
        after cursor: PageCursor<String>?,
        limit: Int,
        sort: FolderFilesSort
    ) throws -> Page<TrackRecord, String>
    func updateFolderPositions(
        profileId: Int64,
        rootPath: String,
        _ updates: [(trackId: Int64, position: Int)]
    ) async throws
}

extension TrackRepository: FolderOutlineReading {}

// MARK: - Rows

/// A subfolder row in the outline.
///
/// `trackCount` is the **recursive** total ``FolderChildSummary`` reports — every
/// visible track anywhere beneath the folder — because that is the number a
/// collapsed row has to show.
public struct FolderOutlineFolder: Sendable, Equatable, Hashable, Identifiable {
    public let path: String
    public let name: String
    public let trackCount: Int
    public let hasChildren: Bool
    /// Indentation level; the browsed folder's own subfolders are `0`.
    public let depth: Int
    public let isExpanded: Bool

    public var id: String {
        path
    }

    public init(
        path: String,
        name: String,
        trackCount: Int,
        hasChildren: Bool,
        depth: Int,
        isExpanded: Bool
    ) {
        self.path = path
        self.name = name
        self.trackCount = trackCount
        self.hasChildren = hasChildren
        self.depth = depth
        self.isExpanded = isExpanded
    }
}

/// A file row in the outline: one track sitting **directly** in `levelPath`.
///
/// `indexInLevel` / `levelFileCount` are that level's own window coordinates, which
/// is what makes the threshold prefetch per-level: a row near the end of ITS
/// directory's loaded page schedules that directory's next page, never another
/// level's.
public struct FolderOutlineFile: Sendable, Identifiable {
    public let track: TrackRecord
    /// The directory whose page this row came from — the level it plays with,
    /// pages from, and (at the browsed root only) reorders within.
    public let levelPath: String
    public let depth: Int
    public let indexInLevel: Int
    public let levelFileCount: Int

    public var id: String {
        "\(levelPath)#\(track.id ?? 0)"
    }

    /// The row's selection tag — the same `Int64` the flat browser list uses.
    public var trackId: Int64 {
        track.id ?? 0
    }

    public init(
        track: TrackRecord,
        levelPath: String,
        depth: Int,
        indexInLevel: Int,
        levelFileCount: Int
    ) {
        self.track = track
        self.levelPath = levelPath
        self.depth = depth
        self.indexInLevel = indexInLevel
        self.levelFileCount = levelFileCount
    }
}

/// One rendered outline row: a subfolder, or a file directly inside a level.
public enum FolderOutlineRow: Identifiable, Sendable {
    case folder(FolderOutlineFolder)
    case file(FolderOutlineFile)

    /// Prefixed so a folder and a file can never collide on a shared path string.
    public var id: String {
        switch self {
        case let .folder(folder): "d:" + folder.id
        case let .file(file): "f:" + file.id
        }
    }
}

// MARK: - Level state

/// One directory's loaded state: its subfolders (loaded once) and its own keyset
/// window of direct files.
///
/// `isLoading` doubles as that level's one-fetch-in-flight gate — the per-level
/// equivalent of the flat browser's `LibraryPrefetchGate`, so a burst of
/// `onAppear` events collapses into a single page fetch.
struct FolderOutlineLevel {
    var subfolders: [FolderChildSummary] = []
    var files: [TrackRecord] = []
    var cursor: PageCursor<String>?
    var hasMore = false
    var isLoading = false
    var isLoaded = false
}
