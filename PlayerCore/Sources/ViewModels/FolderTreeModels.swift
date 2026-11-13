// FolderTreeModels — the value types the folder sidebar's lazy tree is built from:
// its read seam, its node, and its per-profile persisted UI state.
//
// Split out of `FolderSidebarViewModel.swift` to stay inside SwiftLint's file
// budget; the behaviour lives in that file and `FolderSidebarViewModel+Tree.swift`.
import Foundation
import Persistence

// MARK: - Read seam

/// The narrow, profile-scoped read seam the folder sidebar needs: a root's
/// availability tally and one level of subfolders.
///
/// The production conformer is ``TrackRepository``; tests inject a fake that counts
/// calls. Deliberately NOT a `TrackRepositoryProviding` requirement — mirroring
/// ``KaraokeReadyPaging``, only this view model needs the seam, and `childFolders`
/// stays a concrete `TrackRepository` extension (Task 2's shipped API is unchanged).
public protocol FolderTreeReading: Sendable {
    /// A bounded availability tally for the tracks beneath a library-root folder.
    func rootSummary(rootPath: String) throws -> RootTrackSummary
    /// The immediate subfolders of `parentPath` visible to `profileId`, each with a
    /// recursive track count and whether it holds subfolders of its own.
    func childFolders(profileId: Int64, parentPath: String) throws -> [FolderChildSummary]
    /// Whether `rootPath` holds any subfolder visible to `profileId` — the chevron
    /// answer for a root, whose child level is not loaded until it is expanded.
    func hasSubfolders(profileId: Int64, rootPath: String) throws -> Bool
}

extension TrackRepository: FolderTreeReading {}

// MARK: - Node

/// One folder sidebar node — a library root or any folder nested beneath one:
/// a stable id, its path + display name, whether all of its tracks are currently
/// unavailable (drives the "Missing" badge), whether it holds subfolders (so a
/// disclosure chevron needs no extra probe), and its depth below the root.
public struct FolderSidebarNode: Identifiable, Sendable, Equatable {
    public let rootId: Int64
    public let path: String
    public let name: String
    public let isMissing: Bool
    /// Whether this folder holds at least one subfolder that owns tracks. Comes
    /// free from ``FolderChildSummary`` for a nested folder, and from
    /// ``FolderTreeReading/hasSubfolders(profileId:rootPath:)`` for a library root,
    /// whose child level is not loaded until it is expanded.
    public let hasChildren: Bool
    /// Rows below the library root: `0` for a root, `1` for its immediate children.
    public let depth: Int
    /// The newest `track.dateAdded` anywhere beneath this folder, or `nil` when no
    /// track under it carries one — the key ``FolderSortKey/dateAdded`` orders by.
    /// Derived per read from the folder summaries (`MAX`), never stored.
    public let newestDateAdded: Double?

    public var id: Int64 {
        rootId
    }

    public var destination: SidebarDestination {
        .folder(rootId: rootId)
    }

    /// The pair ``FolderSort/compare(_:_:by:)`` orders two nodes on.
    var sortFields: (name: String, newestDateAdded: Double?) {
        (name: name, newestDateAdded: newestDateAdded)
    }

    public init(
        rootId: Int64,
        path: String,
        name: String,
        isMissing: Bool,
        hasChildren: Bool = false,
        depth: Int = 0,
        newestDateAdded: Double? = nil
    ) {
        self.rootId = rootId
        self.path = path
        self.name = name
        self.isMissing = isMissing
        self.hasChildren = hasChildren
        self.depth = depth
        self.newestDateAdded = newestDateAdded
    }
}

// MARK: - Persisted state

/// The sidebar's currently selected folder as an id→path pair.
///
/// The pair is stored rather than the id alone because a persisted
/// `.folder(rootId:)` naming a SUBFOLDER cannot be resolved at launch: only the
/// roots are materialized then, so nothing else in the registry maps that id back
/// to a path. Seeding the registry from this pair is what lets the restored
/// destination resolve before any child level has loaded.
public struct FolderTreeSelection: Codable, Sendable, Equatable, Hashable {
    public let rootId: Int64
    public let path: String

    public init(rootId: Int64, path: String) {
        self.rootId = rootId
        self.path = path
    }
}

/// One profile's persisted folder-tree UI state.
public struct FolderTreeState: Codable, Sendable, Equatable {
    /// The folder paths the user left expanded, in a stable (sorted) order.
    public var expandedPaths: [String]
    /// The folder the sidebar selection pointed at, if any.
    public var selection: FolderTreeSelection?

    public init(expandedPaths: [String] = [], selection: FolderTreeSelection? = nil) {
        self.expandedPaths = expandedPaths
        self.selection = selection
    }

    public static let empty = FolderTreeState()
}

/// The injected persistence seam for the folder tree's per-profile UI state.
///
/// Two `@Sendable` closures, **keyed by profile id** exactly as the macOS shell's
/// `SidebarSelectionStore.scoped(to:)` keys the sidebar selection: a single unkeyed
/// record would leave the incoming profile's subfolder unresolvable after a switch.
/// PlayerCore never touches `UserDefaults` — the shell wires the closures.
public struct FolderTreePersistence: Sendable {
    public let load: @Sendable (Int64) -> FolderTreeState
    public let save: @Sendable (Int64, FolderTreeState) -> Void

    public init(
        load: @escaping @Sendable (Int64) -> FolderTreeState,
        save: @escaping @Sendable (Int64, FolderTreeState) -> Void
    ) {
        self.load = load
        self.save = save
    }

    /// A no-op seam: nothing is remembered across launches. The default, so a caller
    /// that does not need restore wires nothing.
    public static let ephemeral = FolderTreePersistence(load: { _ in .empty }, save: { _, _ in })
}
