//
//  NowPlayingSnapshot.swift
//  Models
//
//  The tiny, Codable now-playing payload published through the App Group, plus
//  the injectable writer seam it is published with. A snapshot carries display
//  text and small references only — never a `DatabasePool`, a `TrackRecord` or
//  file bytes — so any App-Group reader stays entirely off the live database.
//
//  Lives in `Models` (Foundation-only) so the app's `Services` layer can write it
//  without pulling GRDB into whatever reads it.
//
//  STATUS: the seam is currently DORMANT. Both app shells construct
//  ``NowPlayingService`` with `snapshotWriter: nil`, so nothing is published at
//  runtime; the types below stay as the ready-made publish path (and remain
//  covered by `NowPlayingTests`). ``AppGroup/identifier`` is NOT dormant — the
//  iOS shell's `AppSettings` is backed by that suite, so this enum is load-bearing.
//

import Foundation

/// A minimal, serialisable description of what is playing, written to the App
/// Group for the widget to render. Deliberately text + small references only:
/// it carries NO database handle, no `TrackRecord`, no file bytes.
public struct NowPlayingSnapshot: Codable, Sendable, Equatable {
    /// Display title.
    public var title: String
    /// Display artist, if known.
    public var artist: String?
    /// Display album, if known.
    public var album: String?
    /// A stable artwork reference (cache key / file path) the widget resolves.
    public var artworkRef: String?
    /// Track duration in seconds.
    public var duration: TimeInterval
    /// Current playback position in seconds.
    public var elapsed: TimeInterval
    /// Whether the transport is playing.
    public var isPlaying: Bool

    public init(
        title: String,
        artist: String? = nil,
        album: String? = nil,
        artworkRef: String? = nil,
        duration: TimeInterval = 0,
        elapsed: TimeInterval = 0,
        isPlaying: Bool = false
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.artworkRef = artworkRef
        self.duration = duration
        self.elapsed = elapsed
        self.isPlaying = isPlaying
    }
}

/// Persists a ``NowPlayingSnapshot`` somewhere the widget can read it.
///
/// Injected into ``NowPlayingService`` so production writes to the App Group and
/// tests use an in-memory fake — keeping the live database entirely out of the
/// snapshot path.
public protocol SnapshotWriting {
    /// Writes `snapshot`, replacing any previous value.
    func write(_ snapshot: NowPlayingSnapshot) throws
}

/// Errors a ``SnapshotWriting`` implementation can surface.
public enum SnapshotWriterError: Error, Equatable {
    /// The App-Group `UserDefaults` suite could not be opened.
    case unavailableSuite(String)
}

/// Shared constants for the MacAMP App Group.
public enum AppGroup {
    /// The App Group identifier shared by the app, extensions and widget.
    public static let identifier = "group.si.macamp.MacAMP"
    /// The default key/file name the now-playing snapshot is stored under.
    public static let snapshotKey = "nowPlayingSnapshot"
    /// The App-Group `UserDefaults` key the widget posts transport commands under
    /// (must match `Widget/Sources/NowPlayingIntents.swift`).
    public static let commandKey = "nowPlayingCommand"
    /// The Darwin notification name the widget can post to wake the app's command
    /// observer immediately (cross-process notifications carry no payload — the
    /// record itself is read from ``commandKey``).
    public static let commandDarwinName = "si.macamp.MacAMP.nowPlayingCommand"
}

/// Writes the snapshot as JSON into an App-Group `UserDefaults` suite.
///
/// Stores only the suite name + key (both `Sendable`) and resolves the suite per
/// write, so the writer itself is a trivially `Sendable` value type.
public struct UserDefaultsSnapshotWriter: SnapshotWriting, Sendable {
    private let suiteName: String
    private let key: String

    public init(
        suiteName: String = AppGroup.identifier,
        key: String = AppGroup.snapshotKey
    ) {
        self.suiteName = suiteName
        self.key = key
    }

    public func write(_ snapshot: NowPlayingSnapshot) throws {
        let data = try JSONEncoder().encode(snapshot)
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw SnapshotWriterError.unavailableSuite(suiteName)
        }
        defaults.set(data, forKey: key)
    }
}

/// Writes the snapshot as a JSON file inside the shared App-Group container.
public struct FileSnapshotWriter: SnapshotWriting, Sendable {
    private let fileURL: URL

    /// Writes to an explicit file URL (used in tests with a temp path).
    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Resolves the shared App-Group container, or returns `nil` if the group is
    /// not provisioned (so the caller can fall back to ``UserDefaultsSnapshotWriter``).
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

    public func write(_ snapshot: NowPlayingSnapshot) throws {
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: fileURL, options: .atomic)
    }
}
