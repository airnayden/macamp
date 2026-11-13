// Test doubles for the lazy folder-sidebar tree.
//
// `FakeFolderTreeRepository` stands in for `TrackRepository`'s three folder reads
// over a canned set of folder paths, recording every `childFolders` call and every
// `hasSubfolders` probe so the load-exactly-once and probe-once-per-unknown-root
// contracts are both assertable. `InMemoryFolderTreeStore` backs the
// `FolderTreePersistence` closure seam with a profile-keyed dictionary, standing in
// for the shell's `UserDefaults` wiring.
import Foundation
import Persistence
import ViewModels

/// A canned folder tree plus per-root availability tally, standing in for
/// ``FolderTreeReading``'s production conformer.
final class FakeFolderTreeRepository: FolderTreeReading, @unchecked Sendable {
    private let lock = NSLock()
    private var folders: Set<String>
    private var rootTotals: [String: Int]
    private var missingRoots: Set<String>
    private var newestDates: [String: Double]
    private var calls: [String] = []
    private var probes: [String] = []
    private var probeFailure: (any Error)?

    /// `newestDates` is keyed by folder path and stands in for the `MAX(dateAdded)`
    /// the real folder queries derive; an absent path reads back as `nil`, which is
    /// the "no track beneath carries a date" case the sort must place last.
    init(
        folders: [String],
        rootTotals: [String: Int],
        missingRoots: Set<String> = [],
        newestDates: [String: Double] = [:]
    ) {
        self.folders = Set(folders)
        self.rootTotals = rootTotals
        self.missingRoots = missingRoots
        self.newestDates = newestDates
    }

    var childFolderCalls: [String] {
        lock.withLock { calls }
    }

    func callCount(for parentPath: String) -> Int {
        lock.withLock { calls.count(where: { $0 == parentPath }) }
    }

    func probeCount(for rootPath: String) -> Int {
        lock.withLock { probes.count(where: { $0 == rootPath }) }
    }

    /// Makes every later subfolder probe throw, so the view model's "assume a
    /// chevron" fallback is exercised rather than asserted about in the abstract.
    func failSubfolderProbes(with error: any Error = FolderTreeProbeFailure.unreadable) {
        lock.withLock { probeFailure = error }
    }

    func setRootTotal(_ total: Int, for rootPath: String) {
        lock.withLock { rootTotals[rootPath] = total }
    }

    func setFolders(_ paths: [String]) {
        lock.withLock { folders = Set(paths) }
    }

    func rootSummary(rootPath: String) throws -> RootTrackSummary {
        let (total, isMissing, newest) = lock.withLock {
            (rootTotals[rootPath] ?? 0, missingRoots.contains(rootPath), newestDates[rootPath])
        }
        return RootTrackSummary(
            total: total,
            present: isMissing ? 0 : total,
            missing: isMissing ? total : 0,
            externalOffline: 0,
            newestDateAdded: newest
        )
    }

    func childFolders(profileId _: Int64, parentPath: String) throws -> [FolderChildSummary] {
        let (known, dates) = lock.withLock { () -> (Set<String>, [String: Double]) in
            calls.append(parentPath)
            return (folders, newestDates)
        }
        let prefix = parentPath.hasSuffix("/") ? parentPath : parentPath + "/"
        let immediate = known
            .filter { $0.hasPrefix(prefix) && !$0.dropFirst(prefix.count).contains("/") }
            .sorted()
        return immediate.map { path in
            FolderChildSummary(
                name: String(path.dropFirst(prefix.count)),
                path: path,
                trackCount: 1,
                hasChildren: known.contains { $0.hasPrefix(path + "/") },
                newestDateAdded: dates[path]
            )
        }
    }

    func hasSubfolders(profileId _: Int64, rootPath: String) throws -> Bool {
        let (failure, known) = lock.withLock { () -> ((any Error)?, Set<String>) in
            probes.append(rootPath)
            return (probeFailure, folders)
        }
        if let failure {
            throw failure
        }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return known.contains { $0.hasPrefix(prefix) }
    }
}

/// The failure ``FakeFolderTreeRepository/failSubfolderProbes(with:)`` throws by
/// default — an unreadable database stands in for any probe that cannot answer.
enum FolderTreeProbeFailure: Error {
    case unreadable
}

/// A profile-keyed in-memory backing for the ``FolderTreePersistence`` seam.
final class InMemoryFolderTreeStore: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [Int64: FolderTreeState] = [:]

    var persistence: FolderTreePersistence {
        FolderTreePersistence(
            load: { [self] profileId in lock.withLock { states[profileId] ?? .empty } },
            save: { [self] profileId, state in lock.withLock { states[profileId] = state } }
        )
    }

    func state(for profileId: Int64) -> FolderTreeState {
        lock.withLock { states[profileId] ?? .empty }
    }

    func seed(_ state: FolderTreeState, for profileId: Int64) {
        lock.withLock { states[profileId] = state }
    }
}

enum FolderTreeFixture {
    static let library = "/Music/Lib"
    static let other = "/Music/Other"
    static let rock = "/Music/Lib/Rock"
    static let jazz = "/Music/Lib/Jazz"
    static let sub = "/Music/Lib/Rock/Sub"
    static let deep = "/Music/Lib/Rock/Sub/DeepFolder"
    static let live = "/Music/Other/Live"
    static let leaf = "/Music/Leaf"

    static var folders: [String] {
        [rock, jazz, sub, deep, live]
    }

    static func makeRepository() -> FakeFolderTreeRepository {
        FakeFolderTreeRepository(
            folders: folders,
            rootTotals: [library: 5, other: 2]
        )
    }

    /// Two roots that own tracks but differ in shape: `/Music/Lib` nests, and
    /// `/Music/Leaf` holds files only — the pair a chevron probe has to tell apart
    /// before either has been expanded.
    static func makeLeafAndNestedRepository() -> FakeFolderTreeRepository {
        FakeFolderTreeRepository(
            folders: folders,
            rootTotals: [library: 5, leaf: 3]
        )
    }

    static func url(_ path: String) -> URL {
        URL(fileURLWithPath: path)
    }

    static func nodeID(_ path: String) -> Int64 {
        FolderSidebarViewModel.stableRootId(forPath: path)
    }
}
