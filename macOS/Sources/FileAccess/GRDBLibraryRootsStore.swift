// GRDBLibraryRootsStore — the per-profile library roots store, backed by GRDB.
//
// The profiles feature moves library roots out of `UserDefaults` and into the
// `libraryRoot` table so every profile owns its own set of folders. This store is
// a drop-in ``LibraryRootsStoring`` — the SAME `load()` / `save(_:)` contract the
// legacy ``UserDefaultsLibraryRootsStore`` implemented — that delegates to
// ``LibraryRootRepository``, scoped to the ACTIVE profile.
//
// Roots are plain filesystem paths (macOS is unsandboxed — no security-scoped
// bookmarks), exactly as the legacy store persisted them.
//
// ``activeProfileId`` is mutable and lock-guarded so a single shared instance can
// serve the access controller, the watch service AND the sidebar refresh: a
// profile switch (a later task) assigns it, then retargets the watcher via
// `watchService.updateRoots(load())`. Reads/writes always resolve the CURRENT
// profile, never a value captured at construction.
import Foundation
import Persistence

// MARK: - GRDBLibraryRootsStore

/// A ``LibraryRootsStoring`` over the `libraryRoot` table, scoped to one profile.
public final class GRDBLibraryRootsStore: LibraryRootsStoring, @unchecked Sendable {
    private let repository: any LibraryRootRepositoryProviding
    private let lock = NSLock()
    private var profileId: Int64

    /// - Parameters:
    ///   - repository: the per-profile roots repository (GRDB-backed).
    ///   - profileId: the profile whose roots this store initially reads and writes.
    public init(repository: any LibraryRootRepositoryProviding, profileId: Int64) {
        self.repository = repository
        self.profileId = profileId
    }

    /// The profile whose roots this store reads/writes. A profile switch assigns
    /// this, then calls `watchService.updateRoots(load())` to retarget the watcher.
    public var activeProfileId: Int64 {
        get { lock.withLock { profileId } }
        set { lock.withLock { profileId = newValue } }
    }

    /// The active profile's roots as filesystem URLs (empty on error or when none).
    public func load() -> [URL] {
        let profileId = activeProfileId
        let records = (try? repository.rootsForProfile(profileId, limit: LibraryRootRepository.fetchLimit)) ?? []
        return records.map { URL(fileURLWithPath: $0.path) }
    }

    /// Replaces the active profile's stored roots with `roots`: removes rows no
    /// longer present and inserts newly-added paths (a set-diff, since the
    /// repository exposes add/remove, not replace-all). Paths are standardised to
    /// match the legacy store's on-disk format.
    public func save(_ roots: [URL]) {
        let profileId = activeProfileId
        let desiredSet = Set(roots.map(\.path))
        guard let current = try? repository.rootsForProfile(profileId, limit: LibraryRootRepository.fetchLimit)
        else { return }
        let currentPaths = Set(current.map(\.path))
        for record in current where !desiredSet.contains(record.path) {
            guard let id = record.id else { continue }
            _ = try? repository.removeRoot(id: id)
        }
        for path in desiredSet where !currentPaths.contains(path) {
            _ = try? repository.addRoot(profileId: profileId, path: path)
        }
    }
}

// MARK: - Live factory

extension GRDBLibraryRootsStore {
    /// Builds the live store over `database` scoped to `activeProfileId`, running
    /// the one-time legacy-roots import first: the old ``UserDefaultsLibraryRootsStore``
    /// paths are READ (never deleted — rollback safety) and imported onto Guest,
    /// guarded by a persisted flag so it happens exactly once across launches.
    static func live(database: AppDatabase, activeProfileId: Int64) -> GRDBLibraryRootsStore {
        let repository = LibraryRootRepository(database)
        let legacyPaths = UserDefaults.standard
            .array(forKey: UserDefaultsLibraryRootsStore.defaultKey) as? [String] ?? []
        try? repository.importLegacyRootsIfNeeded(
            from: legacyPaths,
            flagStore: UserDefaultsLegacyRootsImportFlagStore()
        )
        return GRDBLibraryRootsStore(repository: repository, profileId: activeProfileId)
    }
}

// MARK: - UserDefaultsLegacyRootsImportFlagStore

/// The production ``LegacyRootsImportFlagStore`` over `UserDefaults` — persists the
/// one-shot "legacy roots already imported" flag so the migration runs exactly once
/// across launches, never resurrecting roots a user later deletes. Stores only the
/// `Sendable` suite name + key and resolves the defaults object per call (mirroring
/// ``UserDefaultsLibraryRootsStore``); `Persistence` never touches `UserDefaults`.
public struct UserDefaultsLegacyRootsImportFlagStore: LegacyRootsImportFlagStore {
    /// The default `UserDefaults` key under which the one-shot flag is stored.
    public static let defaultKey = "com.example.macamp.legacyRootsImported"

    private let suiteName: String?
    private let key: String

    /// - Parameters:
    ///   - suiteName: a `UserDefaults` suite (nil ⇒ `.standard`).
    ///   - key: the defaults key for the one-shot flag.
    public init(suiteName: String? = nil, key: String = UserDefaultsLegacyRootsImportFlagStore.defaultKey) {
        self.suiteName = suiteName
        self.key = key
    }

    public var legacyRootsImported: Bool {
        defaults.bool(forKey: key)
    }

    public func markLegacyRootsImported() {
        defaults.set(true, forKey: key)
    }

    private var defaults: UserDefaults {
        if let suiteName, let suite = UserDefaults(suiteName: suiteName) {
            return suite
        }
        return .standard
    }
}
