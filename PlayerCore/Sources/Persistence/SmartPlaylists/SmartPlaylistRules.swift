import Foundation

/// A bounded numeric window used by the range predicates.
///
/// Both bounds are optional so a rule can express "at least", "at most" or "between"
/// with one type. Two `nil` bounds mean *no constraint at all* — the compiler emits a
/// tautology for that predicate rather than an impossible one, so an under-specified
/// rule widens the result instead of silently emptying the playlist.
public struct SmartPlaylistRange<Bound: Codable & Sendable & Equatable & Hashable>:
    Codable, Sendable, Equatable, Hashable
{
    /// Inclusive lower bound, or `nil` for unbounded below.
    public var lower: Bound?
    /// Inclusive upper bound, or `nil` for unbounded above.
    public var upper: Bound?

    public init(lower: Bound? = nil, upper: Bound? = nil) {
        self.lower = lower
        self.upper = upper
    }
}

/// How a rule set's predicates combine.
public enum SmartPlaylistMatchMode: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    /// Every predicate must hold (`AND`).
    case all
    /// At least one predicate must hold (`OR`).
    case any
}

/// The field a rule set orders its materialised tracks by.
///
/// Deliberately a small, closed set: every case must map to a single SQL expression
/// the compiler can also index-seek. `playCount`/`listenedCount` resolve through
/// `profileTrackState` — never the frozen `track` columns.
public enum SmartPlaylistSortField: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    case title
    case artistName
    case albumTitle
    case year
    case duration
    case dateAdded
    case playCount
    case listenedCount
}

/// Ascending or descending order for ``SmartPlaylistSort``.
public enum SmartPlaylistSortDirection: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    case ascending
    case descending
}

/// The ordering applied to a rule set's results before the `LIMIT` truncates them.
///
/// The compiler always appends `track.id` as a tie-break, so two evaluations of the
/// same library produce the same order — materialisation is deterministic.
public struct SmartPlaylistSort: Codable, Sendable, Equatable, Hashable {
    public var field: SmartPlaylistSortField
    public var direction: SmartPlaylistSortDirection

    public init(
        field: SmartPlaylistSortField = .title,
        direction: SmartPlaylistSortDirection = .ascending
    ) {
        self.field = field
        self.direction = direction
    }
}

/// A versioned, JSON-serialisable smart-playlist rule set.
///
/// This is the payload of `smartPlaylist.rulesJson`, and ``schemaVersion`` is the
/// same concept as the `smartPlaylist.rulesVersion` column added by the `v16`
/// migration — **not** a GRDB migration version. The two are written together and
/// validated together: a row whose column or payload declares a version this build
/// does not understand is rejected with a typed
/// ``SmartPlaylistError/unsupportedRulesVersion(found:supported:)`` rather than
/// half-decoded.
///
/// A rule set is always bounded. ``limit`` is mandatory (defaulting to
/// ``defaultLimit``) and ``effectiveLimit`` clamps it to `1...`
/// ``maximumLimit``, so a hand-written or machine-generated rule can never ask the
/// compiler for an unbounded scan.
public struct SmartPlaylistRules: Codable, Sendable, Equatable, Hashable {
    /// The rule schema this build reads and writes.
    public static let currentSchemaVersion = 1
    /// The version assumed for a payload that predates versioning and carries no
    /// `schemaVersion` key — matching the `DEFAULT 1` on `smartPlaylist.rulesVersion`.
    public static let legacySchemaVersion = 1
    /// The `limit` a rule set gets when it does not state one.
    public static let defaultLimit = 500
    /// The hard ceiling on materialised tracks, whatever a rule set asks for.
    public static let maximumLimit = 500

    /// Schema version of this payload. See the type's discussion.
    public var schemaVersion: Int
    /// Whether the predicates are `AND`-composed or `OR`-composed.
    public var match: SmartPlaylistMatchMode
    /// The predicates to compose. An empty list matches every visible track,
    /// regardless of ``match`` — an empty rule set is "the whole library", never
    /// "nothing".
    public var predicates: [SmartPlaylistPredicate]
    /// The ordering applied before truncation.
    public var sort: SmartPlaylistSort
    /// Requested maximum materialised tracks. Read through ``effectiveLimit``.
    public var limit: Int

    public init(
        match: SmartPlaylistMatchMode = .all,
        predicates: [SmartPlaylistPredicate] = [],
        sort: SmartPlaylistSort = SmartPlaylistSort(),
        limit: Int = SmartPlaylistRules.defaultLimit,
        schemaVersion: Int = SmartPlaylistRules.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.match = match
        self.predicates = predicates
        self.sort = sort
        self.limit = limit
    }

    /// ``limit`` clamped into `1...`​``maximumLimit`` — the value the compiler binds.
    public var effectiveLimit: Int {
        min(max(1, limit), Self.maximumLimit)
    }

    /// Decodes a payload, tolerating an absent `schemaVersion` as
    /// ``legacySchemaVersion``.
    ///
    /// Written by hand only for that default: everything else is the synthesised
    /// behaviour, and ``encode(to:)`` stays synthesised so a round-trip always emits
    /// an explicit version.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? Self.legacySchemaVersion
        match = try container.decodeIfPresent(SmartPlaylistMatchMode.self, forKey: .match) ?? .all
        predicates = try container.decodeIfPresent([SmartPlaylistPredicate].self, forKey: .predicates) ?? []
        sort = try container.decodeIfPresent(SmartPlaylistSort.self, forKey: .sort) ?? SmartPlaylistSort()
        limit = try container.decodeIfPresent(Int.self, forKey: .limit) ?? Self.defaultLimit
    }
}
