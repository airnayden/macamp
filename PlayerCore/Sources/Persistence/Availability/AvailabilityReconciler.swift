import Foundation
import GRDB

/// Reconciles every track's ``Availability`` against the current state of the
/// file system **without ever deleting a row**.
///
/// A reconciliation pass walks the `track` table and, for each row, derives a
/// new availability from two facts supplied by an injected ``FileSystemProbing``
/// seam:
///
/// * whether the backing file is reachable on disk, and
/// * if it is not, whether the file's volume is an *external* volume that is
///   merely *unmounted* (offline) rather than genuinely gone.
///
/// The state machine is:
///
/// | file reachable | volume external | volume mounted | result |
/// |---|---|---|---|
/// | yes | – | – | ``Availability/present`` |
/// | no  | yes | no  | ``Availability/externalOffline`` |
/// | no  | otherwise | – | ``Availability/missing`` |
///
/// Rows are **never** deleted: an unplugged drive or a temporarily missing file
/// keeps its library entry so the *user* — never the scanner — decides when to
/// remove a track. Only the `availability` column is rewritten, and only for
/// rows whose state actually changed.
public protocol AvailabilityReconciling: Sendable {
    /// Runs one reconciliation pass over the whole library.
    /// - Returns: A tally of what changed.
    @discardableResult
    func reconcile() throws -> AvailabilityReconcileSummary

    /// Marks every track under a deliberately removed library root as missing.
    /// Rows remain recoverable and can return to ``Availability/present`` when the
    /// root is added again and scanned.
    @discardableResult
    func markMissing(rootPath: String) throws -> Int

    /// Removes the tracks under a library folder the user just removed, unless a
    /// folder still configured in any profile covers them. See
    /// `AvailabilityReconciler+Pruning.swift`.
    @discardableResult
    func removeTracks(underRemovedRoot rootPath: String) throws -> Int

    /// Removes missing tracks that no configured folder in any profile covers.
    @discardableResult
    func pruneOrphanedMissingTracks() throws -> Int
}

/// The outcome of a single ``AvailabilityReconciling/reconcile()`` pass.
public struct AvailabilityReconcileSummary: Sendable, Equatable {
    /// Total rows visited.
    public var scanned: Int
    /// Rows whose availability was already correct.
    public var unchanged: Int
    /// Rows transitioned to ``Availability/present``.
    public var markedPresent: Int
    /// Rows transitioned to ``Availability/missing``.
    public var markedMissing: Int
    /// Rows transitioned to ``Availability/externalOffline``.
    public var markedExternalOffline: Int

    /// Rows whose `availability` column was rewritten this pass.
    public var changed: Int {
        markedPresent + markedMissing + markedExternalOffline
    }

    public init(
        scanned: Int = 0,
        unchanged: Int = 0,
        markedPresent: Int = 0,
        markedMissing: Int = 0,
        markedExternalOffline: Int = 0
    ) {
        self.scanned = scanned
        self.unchanged = unchanged
        self.markedPresent = markedPresent
        self.markedMissing = markedMissing
        self.markedExternalOffline = markedExternalOffline
    }
}

/// The concrete ``AvailabilityReconciling`` over a GRDB writer.
///
/// Holds `any DatabaseWriter` (a writer is also a reader) and an injected
/// ``FileSystemProbing`` so tests never touch the real file system or real
/// volumes.
///
/// A pass runs in **three phases**, and the split is load-bearing:
///
/// 1. **READ** — a cursor streams only `id` / `filePath` / `availability` into a
///    lightweight snapshot (a few MB at 100k tracks). No full ``TrackRecord`` is
///    decoded; the read transaction closes before any file is touched.
/// 2. **PROBE** — the file system is consulted with **no transaction held**.
///    `fileExists` can block for seconds on a stalled network mount or a drive
///    spinning up; doing that inside the write transaction pinned SQLite's single
///    writer for the whole pass and stalled every other writer in the app.
/// 3. **WRITE** — one short transaction rewrites only the changed `availability`
///    columns. Deliberately a *single* transaction, never a batch of them, so
///    `rootSummary` (the sidebar's "missing" badge) can never read a half-applied
///    pass.
///
/// The cursor streams the table — it never `fetchAll`s the whole library,
/// honouring the windowed-query budget at 100k scale.
public struct AvailabilityReconciler: AvailabilityReconciling {
    let dbWriter: any DatabaseWriter
    private let fileSystem: any FileSystemProbing

    /// - Parameters:
    ///   - appDatabase: The application database to reconcile.
    ///   - fileSystem: The file-system seam (defaults to the real system).
    public init(
        _ appDatabase: AppDatabase,
        fileSystem: any FileSystemProbing = SystemFileSystem()
    ) {
        dbWriter = appDatabase.writer
        self.fileSystem = fileSystem
    }

    /// - Parameters:
    ///   - dbWriter: A GRDB writer (production pool or in-memory test queue).
    ///   - fileSystem: The file-system seam (defaults to the real system).
    public init(
        _ dbWriter: any DatabaseWriter,
        fileSystem: any FileSystemProbing = SystemFileSystem()
    ) {
        self.dbWriter = dbWriter
        self.fileSystem = fileSystem
    }

    @discardableResult
    public func reconcile() throws -> AvailabilityReconcileSummary {
        let snapshot = try readSnapshot()
        let (summary, pending) = probe(snapshot)
        try applyChanges(pending)
        return summary
    }

    /// Phase 1 — stream the three columns the state machine reads.
    ///
    /// A full ``TrackRecord`` carries 31 columns for a decision that reads exactly
    /// one (`filePath`), so only the id/path/availability triple is materialised.
    private func readSnapshot() throws -> [AvailabilitySnapshotRow] {
        try dbWriter.read { db in
            var rows: [AvailabilitySnapshotRow] = []
            let cursor = try Row.fetchCursor(
                db,
                sql: "SELECT id, filePath, availability FROM \(TrackRecord.databaseTableName)"
            )
            while let row = try cursor.next() {
                rows.append(
                    AvailabilitySnapshotRow(
                        id: row["id"],
                        filePath: row["filePath"],
                        availability: row["availability"]
                    )
                )
            }
            return rows
        }
    }

    /// Phase 2 — resolve every row against the file system with no transaction held.
    private func probe(
        _ snapshot: [AvailabilitySnapshotRow]
    ) -> (summary: AvailabilityReconcileSummary, pending: [PendingAvailabilityChange]) {
        var summary = AvailabilityReconcileSummary()
        var pending: [PendingAvailabilityChange] = []
        let probes = PassProbeCache(fileSystem)
        for row in snapshot {
            summary.scanned += 1
            // A stand-in record: ``resolvedAvailability(for:using:)`` reads only
            // `filePath`, so every other defaulted field is inert and no row is
            // decoded twice.
            let track = TrackRecord(id: row.id, filePath: row.filePath)
            let resolved = Self.resolvedAvailability(for: track, using: probes)
            guard resolved != row.availability else {
                summary.unchanged += 1
                continue
            }
            guard let id = row.id else { continue }
            pending.append(PendingAvailabilityChange(id: id, availability: resolved))
            switch resolved {
            case .present: summary.markedPresent += 1
            case .missing: summary.markedMissing += 1
            case .externalOffline: summary.markedExternalOffline += 1
            }
        }
        return (summary, pending)
    }

    /// Phase 3 — one transaction, changed rows only.
    ///
    /// A row deleted between phases 1 and 3 matches nothing, so its update is a
    /// silent no-op. Only the `availability` column is touched — rows are never
    /// deleted.
    private func applyChanges(_ pending: [PendingAvailabilityChange]) throws {
        guard !pending.isEmpty else { return }
        try dbWriter.write { db in
            for change in pending {
                try db.execute(
                    sql: "UPDATE \(TrackRecord.databaseTableName) SET availability = ? WHERE id = ?",
                    arguments: [change.availability, change.id]
                )
            }
        }
    }

    @discardableResult
    public func markMissing(rootPath: String) throws -> Int {
        try dbWriter.write { db in
            try db.execute(
                sql: """
                UPDATE \(TrackRecord.databaseTableName)
                SET availability = ?
                WHERE filePath LIKE ? ESCAPE '\\' AND availability != ?
                """,
                arguments: [
                    Availability.missing,
                    TrackRepository.likePrefixPattern(forRoot: rootPath),
                    Availability.missing,
                ]
            )
            return db.changesCount
        }
    }

    /// Pure decision function: the availability a track *should* have given the
    /// file system's current view. Free of any database dependency so the state
    /// machine itself stays trivially testable.
    static func resolvedAvailability(
        for track: TrackRecord,
        using fileSystem: any FileSystemProbing
    ) -> Availability {
        if fileSystem.fileExists(atPath: track.filePath) {
            return .present
        }
        let volume = fileSystem.volume(forPath: track.filePath)
        if volume.isExternal, !volume.isMounted {
            return .externalOffline
        }
        return .missing
    }
}

// MARK: - Pass-local value types

/// The three columns phase 1 streams out of the `track` table.
private struct AvailabilitySnapshotRow {
    var id: Int64?
    var filePath: String
    var availability: Availability
}

/// One row whose `availability` column phase 3 will rewrite.
private struct PendingAvailabilityChange {
    var id: Int64
    var availability: Availability
}

// MARK: - Pass-scoped probe memoisation

/// A ``FileSystemProbing`` decorator that memoises both file existence and volume
/// identity **for the duration of one reconciliation pass**.
///
/// `volume(forPath:)` is keyed per mount root: every track on one drive shares a
/// single ``VolumeIdentity``, yet ``SystemFileSystem`` walks the whole mounted-volume
/// set on every call, so memoising turns the ejected-drive pass from
/// O(tracks × volumes) into O(volumes). It is consulted only for a file that already
/// failed `fileExists`, so an all-present library never pays for it. The key is the
/// macOS mount-point convention — `/Volumes/<name>` for anything on an external drive
/// (attached or not), `/` for everything else, which is exactly the root
/// ``SystemFileSystem`` reports for a non-`/Volumes` path.
///
/// `fileExists(atPath:)` is keyed on the path itself. Before v20 that would have been
/// pure overhead, because `track.filePath` was unique. A CUE sheet breaks that: every
/// segment of a disc image is its own `track` row on ONE audio file, so a 12-track
/// image cost 12 `stat(2)` calls for a single yes/no answer — and `stat` is the part
/// of a pass that blocks for seconds on a spinning-up drive or a stalled network
/// mount. Memoising collapses those N probes into one. The cost is one dictionary
/// entry per DISTINCT path for the life of the pass, on top of the snapshot that
/// already holds those same (COW-shared) strings.
///
/// **The scope is the whole point, and it is structural rather than a convention:**
/// ``AvailabilityReconciler/probe(_:)`` constructs a fresh instance per
/// ``AvailabilityReconciler/reconcile()`` call and never lets it escape, so no answer
/// can outlive the pass that observed it. A drive unmounted between two passes is
/// re-probed by the second one, which is exactly the correctness this cache must not
/// trade away. The lock honours `Sendable` rather than serialising real contention.
private final class PassProbeCache: FileSystemProbing, @unchecked Sendable {
    private let base: any FileSystemProbing
    private let lock = NSLock()
    private var identities: [String: VolumeIdentity] = [:]
    private var existence: [String: Bool] = [:]

    init(_ base: any FileSystemProbing) {
        self.base = base
    }

    func fileExists(atPath path: String) -> Bool {
        if let cached = lock.withLock({ existence[path] }) {
            return cached
        }
        let exists = base.fileExists(atPath: path)
        lock.withLock { existence[path] = exists }
        return exists
    }

    func mountedVolumeURLs() -> [URL] {
        base.mountedVolumeURLs()
    }

    func volume(forPath path: String) -> VolumeIdentity {
        let key = Self.volumeKey(forPath: path)
        if let cached = lock.withLock({ identities[key] }) {
            return cached
        }
        let identity = base.volume(forPath: path)
        lock.withLock { identities[key] = identity }
        return identity
    }

    static func volumeKey(forPath path: String) -> String {
        let components = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        guard components.count >= 3, components[1] == "Volumes" else { return "/" }
        return "/Volumes/\(components[2])"
    }
}
