// SidebarDestination — the selectable destinations in the main-window sidebar.
//
// `LibrarySection` is the fixed, `String`-raw set of built-in destinations (all
// tracks, albums, artists, playlists). `SidebarDestination`
// wraps it so the sidebar can ALSO point at a per-folder library root
// (`.folder(rootId:)`) once Task 13 adds dynamic folder nodes — a fixed,
// raw-valued enum can't carry that associated value without losing `rawValue`
// and `CaseIterable`.
//
// The wrapper is `Codable` with a stable, tagged wire format (`{"kind":…}`) plus
// a backward-compatible path that reads a legacy bare `LibrarySection` raw value,
// so the macOS shell can persist + restore the sidebar selection across launches
// without breaking on values written by an older build.
//
// This is PlayerCore code: Foundation only, no AppKit/UIKit (portability
// invariant). The localized `label` lives in an app-shell extension — it needs
// the shell's String Catalog — while everything testable here (identity, icons,
// browser routing, Codable) stays platform-agnostic.
import Foundation

// MARK: - LibrarySection

/// The fixed, built-in sidebar destinations. The library track browser is the
/// detail for ``allTracks``; the remaining destinations are filled in by later
/// tasks (albums/artists grids, playlist editor).
public enum LibrarySection: String, CaseIterable, Identifiable, Hashable, Codable, Sendable {
    case allTracks
    case albums
    case artists
    case favourites
    /// The tracks whose lyrics are already cached. Its `rawValue` (`"lyrics"`) IS
    /// the persisted Codable tag; an older build decodes it as ``allTracks``.
    case lyrics
    case playlists
    case stats
    /// The manual play queue (the user-enqueued tracks), shown as a full-width
    /// screen rather than a right-panel tab. Its `rawValue` (`"queue"`) IS the
    /// persisted Codable tag; an older build decodes it as ``allTracks``.
    case queue
    /// The karaoke ready-tracks destination; dangle-guarded by
    /// ``SidebarDestination/resolvedForKaraokeAvailability(_:)`` when unavailable.
    case karaoke
    /// The karaoke render-queue destination (in-flight + pending renders); like
    /// ``karaoke`` it is dangle-guarded by
    /// ``SidebarDestination/resolvedForKaraokeAvailability(_:)`` when unavailable.
    case karaokeQueue
    /// The local-AI assistant destination: a request field plus a suggestion feed.
    /// Its `rawValue` (`"assistant"`) IS the persisted Codable tag; a build that
    /// predates it decodes the same bytes as ``allTracks``. Dangle-guarded by
    /// ``SidebarDestination/resolvedForAssistantAvailability(_:)`` when the
    /// Intelligence master toggle is off.
    case assistant
    /// The YouTube download queue destination: the in-flight transfer plus the
    /// pending rows. Its `rawValue` (`"downloads"`) IS the persisted Codable tag; a
    /// build that predates it decodes the same bytes as ``allTracks``.
    case downloads

    public var id: String {
        rawValue
    }

    /// SF Symbol name for the row icon. Not user-facing copy (never localized).
    public var systemImage: String {
        switch self {
        case .allTracks: "music.note"
        case .albums: "square.stack"
        case .artists: "music.mic"
        case .favourites: "heart"
        case .lyrics: "text.quote"
        case .playlists: "music.note.list"
        case .stats: "chart.bar"
        case .queue: "list.bullet"
        case .karaoke: "music.mic"
        case .karaokeQueue: "list.bullet.clipboard"
        case .assistant: "sparkles"
        case .downloads: "arrow.down.circle"
        }
    }

    /// Whether selecting this destination shows the library track browser.
    ///
    /// Exhaustive with no `default:`, so a new case is CLASSIFIED here rather than
    /// silently inheriting "not a browser" from an `==` comparison. Only
    /// ``allTracks`` renders the shared track browser; every other section owns a
    /// dedicated detail view. The `false` arm is grouped deliberately — one arm per
    /// case would put this property past SwiftLint's `cyclomatic_complexity` ceiling.
    public var showsLibraryBrowser: Bool {
        switch self {
        case .allTracks:
            true
        case .albums, .artists, .favourites, .lyrics, .playlists,
             .stats, .queue, .karaoke, .karaokeQueue, .assistant, .downloads:
            false
        }
    }
}

// MARK: - SidebarDestination

/// A sidebar selection: either a fixed ``LibrarySection`` or a per-folder library
/// root. The folder case carries the persistent root id that a fixed enum can't —
/// the dynamic folder nodes themselves arrive in Task 13.
public enum SidebarDestination: Hashable, Identifiable, Codable, Sendable {
    /// One of the built-in, fixed sidebar sections.
    case fixed(LibrarySection)
    /// A single library-root folder, identified by its persistent row id.
    case folder(rootId: Int64)
    /// A specific playlist, identified by its persistent row id.
    case playlist(id: Int64)

    public var id: String {
        switch self {
        case let .fixed(section): "fixed.\(section.rawValue)"
        case let .folder(rootId): "folder.\(rootId)"
        case let .playlist(id): "playlist.\(id)"
        }
    }

    public var systemImage: String {
        switch self {
        case let .fixed(section): section.systemImage
        case .folder: "folder"
        case .playlist: "music.note.list"
        }
    }

    public var showsLibraryBrowser: Bool {
        switch self {
        case let .fixed(section): section.showsLibraryBrowser
        case .folder: true
        case .playlist: false
        }
    }
}

// MARK: - Karaoke availability

public extension SidebarDestination {
    /// Resolves a restored or live selection against karaoke availability: a
    /// ``LibrarySection/karaoke`` or ``LibrarySection/karaokeQueue`` destination
    /// falls back to `.fixed(.allTracks)` when karaoke is unavailable (feature
    /// disabled or the separator model absent), so a persisted or live selection
    /// never dangles on a hidden Karaoke section. Every other destination is
    /// returned unchanged.
    func resolvedForKaraokeAvailability(_ available: Bool) -> SidebarDestination {
        if case .fixed(.karaoke) = self, !available {
            return .fixed(.allTracks)
        }
        if case .fixed(.karaokeQueue) = self, !available {
            return .fixed(.allTracks)
        }
        return self
    }
}

// MARK: - Assistant availability

public extension SidebarDestination {
    /// Resolves a restored or live selection against assistant availability: a
    /// ``LibrarySection/assistant`` destination falls back to `.fixed(.allTracks)`
    /// when the Intelligence master toggle is off, so a persisted or live selection
    /// never dangles on a hidden Assistant section. Every other destination is
    /// returned unchanged.
    ///
    /// A SEPARATE guard from ``resolvedForKaraokeAvailability(_:)`` rather than a
    /// merged one: the two features have independent toggles and independent
    /// trigger sites, so one combined call would force every caller to know both
    /// answers before it could reconcile either.
    func resolvedForAssistantAvailability(_ available: Bool) -> SidebarDestination {
        if case .fixed(.assistant) = self, !available {
            return .fixed(.allTracks)
        }
        return self
    }
}

// MARK: - Codable (stable, tagged, backward-compatible)

extension SidebarDestination {
    private enum CodingKeys: String, CodingKey {
        case kind, section, rootId, playlistId
    }

    private enum Kind: String, Codable {
        case fixed, folder, playlist
    }

    public init(from decoder: any Decoder) throws {
        if let legacy = try? decoder.singleValueContainer(),
           let raw = try? legacy.decode(String.self)
        {
            self = .fixed(LibrarySection(rawValue: raw) ?? .allTracks)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch (try? container.decode(Kind.self, forKey: .kind)) ?? .fixed {
        case .fixed:
            let raw = (try? container.decode(String.self, forKey: .section)) ?? ""
            self = .fixed(LibrarySection(rawValue: raw) ?? .allTracks)
        case .folder:
            self = .folder(rootId: (try? container.decode(Int64.self, forKey: .rootId)) ?? 0)
        case .playlist:
            self = .playlist(id: (try? container.decode(Int64.self, forKey: .playlistId)) ?? 0)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .fixed(section):
            try container.encode(Kind.fixed, forKey: .kind)
            try container.encode(section.rawValue, forKey: .section)
        case let .folder(rootId):
            try container.encode(Kind.folder, forKey: .kind)
            try container.encode(rootId, forKey: .rootId)
        case let .playlist(id):
            try container.encode(Kind.playlist, forKey: .kind)
            try container.encode(id, forKey: .playlistId)
        }
    }
}
