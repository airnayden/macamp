// FolderSort — how a folder listing is ordered, and the ONE comparator that
// orders it.
//
// This lives in `Models` rather than `ViewModels` because the sorted keyset
// variants of `tracksDirectlyIn` take a ``FolderFilesSort`` as a repository
// parameter, and `Persistence` depends on `Models` + GRDB only.
//
// The `String` tokens below are persisted in settings, so they are a frozen wire
// format: add cases, never rename an existing token.
//
// This file imports only Foundation (PlayerCore portability invariant).
import Foundation

/// Which column a folder listing is ordered by.
public enum FolderSortKey: String, Codable, CaseIterable, Sendable {
    /// The folder or file's display name, compared the way Finder compares names.
    case name
    /// When the newest track under the entry entered the library.
    case dateAdded
}

/// Which way a ``FolderSortKey`` runs.
public enum FolderSortDirection: String, Codable, Sendable {
    case ascending
    case descending
}

/// A folder listing's ordering: one key, one direction.
public struct FolderSort: Equatable, Codable, Sendable {
    public var key: FolderSortKey
    public var direction: FolderSortDirection

    public init(key: FolderSortKey, direction: FolderSortDirection) {
        self.key = key
        self.direction = direction
    }

    /// The ordering used when nothing is configured: by name, A→Z.
    public static let `default` = FolderSort(key: .name, direction: .ascending)

    /// The persisted token, spelled `"<key>.<direction>"` — e.g. `"name.ascending"`.
    public var rawValue: String {
        "\(key.rawValue).\(direction.rawValue)"
    }

    /// Decodes a persisted token, or `nil` when it names no ordering this build knows.
    ///
    /// Returning `nil` rather than ``default`` is deliberate: the caller owns the
    /// fallback, so a token written by a newer build is never silently re-saved as
    /// something else.
    public init?(rawValue: String) {
        let parts = rawValue.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let key = FolderSortKey(rawValue: String(parts[0])),
              let direction = FolderSortDirection(rawValue: String(parts[1]))
        else { return nil }
        self.init(key: key, direction: direction)
    }
}

/// How a folder's direct files are ordered.
///
/// Files — unlike subfolders — have a user-owned manual order (the profile's
/// `folderTrackOrder` rows), which is the default and the only order a drag may
/// rewrite.
public enum FolderFilesSort: Equatable, Codable, Sendable {
    /// The user's own drag order.
    case manual
    /// A query-derived order, which a drag must not rewrite.
    case sorted(FolderSort)

    /// The order used when nothing is configured: the user's own drag order.
    public static let `default`: FolderFilesSort = .manual

    /// The token ``manual`` persists as. Never collides with a ``FolderSort``
    /// token, which always carries a `"."`.
    public static let manualRawValue = "manual"

    /// The persisted token: `"manual"`, or the wrapped sort's own token.
    public var rawValue: String {
        switch self {
        case .manual: Self.manualRawValue
        case let .sorted(sort): sort.rawValue
        }
    }

    /// Decodes a persisted token, or `nil` when it names no ordering this build knows.
    public init?(rawValue: String) {
        if rawValue == Self.manualRawValue {
            self = .manual
            return
        }
        guard let sort = FolderSort(rawValue: rawValue) else { return nil }
        self = .sorted(sort)
    }
}

// MARK: - Comparator

public extension FolderSort {
    /// Whether `lhs` is ordered before `rhs` under this sort.
    ///
    /// Two rules hold across BOTH directions, because `direction` flips only the
    /// primary key:
    ///
    /// - An entry with no `newestDateAdded` sorts **last** — ascending and
    ///   descending alike. This is the epic's single nil policy; the sorted SQL
    ///   variants of `tracksDirectlyIn` order by the same rule, so the in-memory
    ///   order and the paged order agree.
    /// - A `dateAdded` tie breaks by name **ascending**, so a folder of tracks
    ///   imported in one scan still reads alphabetically.
    static func compare(
        _ lhs: (name: String, newestDateAdded: Double?),
        _ rhs: (name: String, newestDateAdded: Double?),
        by sort: FolderSort
    ) -> Bool {
        switch sort.key {
        case .name:
            compareByName(lhs.name, rhs.name, direction: sort.direction)
        case .dateAdded:
            compareByDateAdded(lhs, rhs, direction: sort.direction)
        }
    }
}

private extension FolderSort {
    /// Finder-style name ordering: case-, width- and diacritic-insensitive, with
    /// embedded numbers compared numerically.
    static func compareByName(_ lhs: String, _ rhs: String, direction: FolderSortDirection) -> Bool {
        switch lhs.localizedStandardCompare(rhs) {
        case .orderedAscending: direction == .ascending
        case .orderedDescending: direction == .descending
        case .orderedSame: false
        }
    }

    static func compareByDateAdded(
        _ lhs: (name: String, newestDateAdded: Double?),
        _ rhs: (name: String, newestDateAdded: Double?),
        direction: FolderSortDirection
    ) -> Bool {
        switch (lhs.newestDateAdded, rhs.newestDateAdded) {
        case let (lhsDate?, rhsDate?):
            guard lhsDate != rhsDate else {
                return compareByName(lhs.name, rhs.name, direction: .ascending)
            }
            return direction == .ascending ? lhsDate < rhsDate : lhsDate > rhsDate
        case (nil, nil):
            return compareByName(lhs.name, rhs.name, direction: .ascending)
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        }
    }
}
