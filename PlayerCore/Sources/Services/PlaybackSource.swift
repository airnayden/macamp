// PlaybackSource — stable context metadata for a user-initiated queue replacement.
//
// The tagged JSON representation is persisted independently of sidebar navigation.
// Library sections therefore carry their stable raw string rather than importing
// ViewModels (which depends on Services and would create a module cycle).
import Foundation

/// Identifies the surface that supplied the current playback queue.
///
/// This enum is frozen because its encoded form is persisted across app versions.
/// New app versions must reject unknown tags rather than silently restoring a queue
/// under the wrong source.
@frozen
public enum PlaybackSource: Sendable, Equatable, Hashable, Codable {
    case librarySection(String)
    case folder(path: String)
    case playlist(id: Int64)
    case favourites
    case karaokeReady
    case search
    case albumDetail(id: Int64)
    case artistDetail(id: Int64)
    case stats
}

// MARK: - Codable (stable, tagged)

extension PlaybackSource {
    private enum CodingKeys: String, CodingKey {
        case kind, section, path, playlistId, albumId, artistId
    }

    private enum Kind: String, Codable {
        case librarySection, folder, playlist, favourites, karaokeReady
        case search, albumDetail, artistDetail, stats
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .librarySection:
            self = try .librarySection(container.decode(String.self, forKey: .section))
        case .folder:
            self = try .folder(path: container.decode(String.self, forKey: .path))
        case .playlist:
            self = try .playlist(id: container.decode(Int64.self, forKey: .playlistId))
        case .favourites:
            self = .favourites
        case .karaokeReady:
            self = .karaokeReady
        case .search:
            self = .search
        case .albumDetail:
            self = try .albumDetail(id: container.decode(Int64.self, forKey: .albumId))
        case .artistDetail:
            self = try .artistDetail(id: container.decode(Int64.self, forKey: .artistId))
        case .stats:
            self = .stats
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .librarySection(section):
            try container.encode(Kind.librarySection, forKey: .kind)
            try container.encode(section, forKey: .section)
        case let .folder(path):
            try container.encode(Kind.folder, forKey: .kind)
            try container.encode(path, forKey: .path)
        case let .playlist(id):
            try container.encode(Kind.playlist, forKey: .kind)
            try container.encode(id, forKey: .playlistId)
        case .favourites:
            try container.encode(Kind.favourites, forKey: .kind)
        case .karaokeReady:
            try container.encode(Kind.karaokeReady, forKey: .kind)
        case .search:
            try container.encode(Kind.search, forKey: .kind)
        case let .albumDetail(id):
            try container.encode(Kind.albumDetail, forKey: .kind)
            try container.encode(id, forKey: .albumId)
        case let .artistDetail(id):
            try container.encode(Kind.artistDetail, forKey: .kind)
            try container.encode(id, forKey: .artistId)
        case .stats:
            try container.encode(Kind.stats, forKey: .kind)
        }
    }
}
