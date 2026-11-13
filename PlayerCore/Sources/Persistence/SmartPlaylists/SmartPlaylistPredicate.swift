import Foundation

/// One condition in a ``SmartPlaylistRules`` set.
///
/// Grouped by **where the data lives** rather than flattened into one wide enum:
/// each group maps to exactly one source in the compiled query — the `track` row, the
/// `profileTrackState` join, an `EXISTS` over `playEvent`, or the `trackAudioFeature`
/// join. That keeps the compiler's per-group `switch` exhaustive *and* small, so a new
/// predicate is a compile error in precisely one place.
public enum SmartPlaylistPredicate: Codable, Sendable, Equatable, Hashable {
    /// A condition on the `track` row itself.
    case metadata(SmartPlaylistMetadataPredicate)
    /// A condition on this profile's per-track state (`profileTrackState`).
    case profileStat(SmartPlaylistProfileStatPredicate)
    /// A condition on this profile's recent plays (`playEvent`).
    case recency(SmartPlaylistRecencyPredicate)
    /// A condition on cached audio analysis (`trackAudioFeature`).
    case audioFeature(SmartPlaylistAudioFeaturePredicate)
}

/// Conditions read straight off the `track` row.
///
/// Text matches are exact and case-insensitive (`= ? COLLATE NOCASE`), matching the
/// `tracksByGenre` convention — a rule says "genre is Rock", never "genre contains
/// roc". A `NULL` column never satisfies a metadata predicate: a track with no `year`
/// is not in "1990–1999".
public enum SmartPlaylistMetadataPredicate: Codable, Sendable, Equatable, Hashable {
    case genre(equals: String)
    case artistName(equals: String)
    case albumTitle(equals: String)
    case year(range: SmartPlaylistRange<Int>)
    /// Duration in seconds.
    case duration(range: SmartPlaylistRange<Double>)
    /// Date added, as seconds since the Unix epoch.
    case dateAdded(range: SmartPlaylistRange<Double>)
    case availability(equals: Availability)
}

/// Conditions on the active profile's own per-track state.
///
/// Always resolved through `profileTrackState`, **never** the frozen
/// `track.playCount` / `listenedCount` / `isFavourite` columns. Those rows are sparse,
/// so the compiler `LEFT JOIN`s them and reads an absent row as `0` / `false`.
public enum SmartPlaylistProfileStatPredicate: Codable, Sendable, Equatable, Hashable {
    case playCount(range: SmartPlaylistRange<Int>)
    case listenedCount(range: SmartPlaylistRange<Int>)
    case isFavourite(equals: Bool)
}

/// Conditions on how recently the active profile played a track.
///
/// Compiled as an `EXISTS` over raw `playEvent` rows, which `PlayEventCompactor`
/// prunes after ~24 months (`playEventRollup` keeps only artist/genre granularity and
/// has no `trackId`). A window longer than that is therefore answerable only from the
/// events that survive — `notPlayedWithin(days:)` over a very long window degrades
/// toward "true for everything" rather than lying about a specific play.
public enum SmartPlaylistRecencyPredicate: Codable, Sendable, Equatable, Hashable {
    /// The profile played the track at least once within the last `days`.
    case playedWithin(days: Int)
    /// The profile played the track **not once** within the last `days`.
    case notPlayedWithin(days: Int)
}

/// Conditions on cached audio analysis.
///
/// Audio analysis is opt-in and may never have run, so every one of these compiles to
/// `(<column> IS NULL OR <range>)`: an un-analysed track is **never excluded** by a
/// feature predicate. `bpm` is additionally nullable within an analysed row (no
/// reliable beat found), which the same `IS NULL` arm covers.
public enum SmartPlaylistAudioFeaturePredicate: Codable, Sendable, Equatable, Hashable {
    /// Tempo in beats per minute.
    case bpm(range: SmartPlaylistRange<Double>)
    /// Perceived intensity, normalised to `0...1`.
    case energy(range: SmartPlaylistRange<Double>)
    /// Spectral brightness, normalised to `0...1`.
    case brightness(range: SmartPlaylistRange<Double>)
}
