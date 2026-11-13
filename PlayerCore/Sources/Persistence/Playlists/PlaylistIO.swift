import Foundation

// MARK: - PlaylistFormat

/// A supported on-disk playlist container.
///
/// `m3u` and `m3u8` are content-equivalent (they differ only by file extension
/// and intended encoding — `m3u8` is UTF-8); both parse and render identically.
public enum PlaylistFormat: String, Sendable, CaseIterable {
    case m3u
    case m3u8
    case pls
    case json
}

// MARK: - PlaylistPathStyle

/// Whether exported entries carry absolute paths or paths relative to a base.
public enum PlaylistPathStyle: Sendable {
    case absolute
    case relative
}

// MARK: - UnresolvedPlaylistEntry

/// A playlist line whose path did not resolve to any library track.
///
/// Unresolved entries are *reported*, never silently dropped, so the caller can
/// surface "3 of 12 tracks could not be found" with the offending line numbers.
public struct UnresolvedPlaylistEntry: Sendable, Equatable {
    public let lineNumber: Int
    public let rawPath: String
    public let resolvedPath: String

    public init(lineNumber: Int, rawPath: String, resolvedPath: String) {
        self.lineNumber = lineNumber
        self.rawPath = rawPath
        self.resolvedPath = resolvedPath
    }
}

// MARK: - PlaylistImportResult

/// The outcome of importing a playlist: the tracks that resolved, plus every
/// entry that did not (with its source line).
public struct PlaylistImportResult: Sendable, Equatable {
    public let tracks: [TrackRecord]
    public let unresolved: [UnresolvedPlaylistEntry]

    public init(tracks: [TrackRecord], unresolved: [UnresolvedPlaylistEntry]) {
        self.tracks = tracks
        self.unresolved = unresolved
    }
}

// MARK: - PlaylistIOError

public enum PlaylistIOError: Error, Equatable {
    case missingBasePathForRelativeExport
    case malformedPlaylist
}

// MARK: - PlaylistIO

/// Imports and exports M3U / M3U8 / PLS playlists, resolving entries against the
/// library's `track` table.
public protocol PlaylistIO: Sendable {
    func importPlaylist(
        contents: String,
        format: PlaylistFormat,
        basePath: String
    ) throws -> PlaylistImportResult

    func exportPlaylist(
        tracks: [TrackRecord],
        format: PlaylistFormat,
        pathStyle: PlaylistPathStyle,
        basePath: String?
    ) throws -> String
}

// MARK: - PlaylistFileIO

/// The production ``PlaylistIO``. Resolves imported paths to library tracks via a
/// ``TrackRepositoryProviding`` lookup (one indexed `filePath` query per entry).
public struct PlaylistFileIO: PlaylistIO {
    private let trackRepository: any TrackRepositoryProviding

    public init(trackRepository: any TrackRepositoryProviding) {
        self.trackRepository = trackRepository
    }

    public init(_ appDatabase: AppDatabase) {
        trackRepository = TrackRepository(appDatabase)
    }

    public func importPlaylist(
        contents: String,
        format: PlaylistFormat,
        basePath: String
    ) throws -> PlaylistImportResult {
        let parsed = try PlaylistParser.parse(contents: contents, format: format)
        var tracks: [TrackRecord] = []
        var unresolved: [UnresolvedPlaylistEntry] = []

        for entry in parsed {
            let resolvedPath = Self.normalizedPath(entry.rawPath, basePath: basePath)
            if let track = try trackRepository.fetchTrack(filePath: resolvedPath) {
                tracks.append(track)
            } else {
                unresolved.append(UnresolvedPlaylistEntry(
                    lineNumber: entry.lineNumber,
                    rawPath: entry.rawPath,
                    resolvedPath: resolvedPath
                ))
            }
        }
        return PlaylistImportResult(tracks: tracks, unresolved: unresolved)
    }

    public func exportPlaylist(
        tracks: [TrackRecord],
        format: PlaylistFormat,
        pathStyle: PlaylistPathStyle,
        basePath: String?
    ) throws -> String {
        if pathStyle == .relative, basePath == nil {
            throw PlaylistIOError.missingBasePathForRelativeExport
        }
        let rows = tracks.map { track in
            PlaylistRenderRow(
                path: Self.outputPath(for: track.filePath, pathStyle: pathStyle, basePath: basePath),
                title: Self.displayTitle(for: track),
                durationSeconds: track.duration
            )
        }
        switch format {
        case .m3u, .m3u8:
            return PlaylistRenderer.renderM3U(rows)
        case .pls:
            return PlaylistRenderer.renderPLS(rows)
        case .json:
            return try PlaylistRenderer.renderJSPF(rows)
        }
    }
}
