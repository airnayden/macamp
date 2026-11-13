//
//  NowPlayingSnapshotReader.swift
//  Models
//
//  The read side of the App-Group now-playing snapshot, mirroring the writers in
//  `NowPlayingSnapshot.swift`. The widget extension uses this to render — it reads
//  ONLY this tiny payload, never the live `DatabasePool` / GRDB.
//

import Foundation

/// Reads a ``NowPlayingSnapshot`` previously persisted by a ``SnapshotWriting``.
public protocol SnapshotReading: Sendable {
    /// Returns the latest snapshot, or `nil` if none has been written / it is unreadable.
    func read() -> NowPlayingSnapshot?
}

/// Reads the snapshot from an App-Group `UserDefaults` suite.
///
/// The mirror of ``UserDefaultsSnapshotWriter``: stores only the suite name + key
/// and resolves the suite per read, so it is a trivially `Sendable` value type.
public struct UserDefaultsSnapshotReader: SnapshotReading {
    private let suiteName: String
    private let key: String

    public init(
        suiteName: String = AppGroup.identifier,
        key: String = AppGroup.snapshotKey
    ) {
        self.suiteName = suiteName
        self.key = key
    }

    public func read() -> NowPlayingSnapshot? {
        guard let defaults = UserDefaults(suiteName: suiteName),
              let data = defaults.data(forKey: key)
        else {
            return nil
        }
        return try? JSONDecoder().decode(NowPlayingSnapshot.self, from: data)
    }
}

/// Reads the snapshot from a JSON file inside the shared App-Group container.
public struct FileSnapshotReader: SnapshotReading {
    private let fileURL: URL

    /// Reads from an explicit file URL (used in tests with a temp path).
    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Resolves the shared App-Group container, or returns `nil` if the group is
    /// not provisioned (so the caller can fall back to ``UserDefaultsSnapshotReader``).
    public init?(
        appGroup: String = AppGroup.identifier,
        filename: String = "now-playing.json"
    ) {
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)
        else {
            return nil
        }
        fileURL = container.appendingPathComponent(filename)
    }

    public func read() -> NowPlayingSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(NowPlayingSnapshot.self, from: data)
    }
}

/// The default snapshot reader for the widget: tries the shared file first (the
/// preferred container path when the App Group is provisioned), then falls back to
/// the `UserDefaults` suite — symmetric with the writer's file→defaults fallback.
public struct NowPlayingSnapshotReader: SnapshotReading {
    private let fileReader: FileSnapshotReader?
    private let defaultsReader: UserDefaultsSnapshotReader

    public init(appGroup: String = AppGroup.identifier) {
        fileReader = FileSnapshotReader(appGroup: appGroup)
        defaultsReader = UserDefaultsSnapshotReader(suiteName: appGroup)
    }

    public func read() -> NowPlayingSnapshot? {
        fileReader?.read() ?? defaultsReader.read()
    }
}
