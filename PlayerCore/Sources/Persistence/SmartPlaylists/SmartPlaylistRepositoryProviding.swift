import Foundation

/// Read/write access to `smartPlaylist` rules and the materialisation they drive.
///
/// **Smart playlists materialise.** Evaluating a rule set rewrites ordinary
/// `playlistTrack` rows, so every existing seam keeps working untouched: track counts
/// (`PlaylistRepository.playlistsWithTrackCounts`), membership paging, playlist export
/// and playback all see a normal playlist. Nothing downstream needs to know a playlist
/// is rule-driven.
///
/// **A manual reorder of a smart playlist is allowed** and persists — it is just a
/// `playlistTrack` rewrite — **until the next evaluation**, which restores the rule
/// set's own `sort` order. That is a deliberate trade: preserving the manual order
/// would mean either never refreshing membership or reconciling two orderings on every
/// evaluation. `lastEvaluatedAt` (surfaced through ``isStale(playlistId:ttl:)``) is
/// what lets a caller decide when that rewrite happens.
///
/// Like ``PlaylistRepositoryProviding``, every method comes in a synchronous form for
/// off-actor callers and tests, plus an `async` twin that runs on a GRDB
/// reader/writer **off** the calling actor. The sync overloads carry
/// `@_disfavoredOverload` so an `await` call site resolves to the async twin.
public protocol SmartPlaylistRepositoryProviding: Sendable {
    /// Stores `rules` for a playlist, creating the row on first write and replacing
    /// it afterwards (`smartPlaylist.playlistId` is `UNIQUE`, so create and update
    /// are the same operation).
    ///
    /// Writing new rules resets `lastEvaluatedAt` to `nil`: the existing
    /// materialisation no longer reflects the stored rules, so the playlist is stale
    /// by definition until it is evaluated again.
    @_disfavoredOverload
    @discardableResult
    func setRules(_ rules: SmartPlaylistRules, forPlaylist playlistId: Int64) throws -> SmartPlaylistRecord
    @discardableResult
    func setRules(_ rules: SmartPlaylistRules, forPlaylist playlistId: Int64) async throws -> SmartPlaylistRecord

    /// The playlist's rules, or `nil` when it has none (an ordinary playlist).
    ///
    /// - Throws: ``SmartPlaylistError`` when a row exists but cannot be read.
    @_disfavoredOverload
    func rules(forPlaylist playlistId: Int64) throws -> SmartPlaylistRules?
    func rules(forPlaylist playlistId: Int64) async throws -> SmartPlaylistRules?

    /// Evaluates the playlist's rules and rewrites its membership in one transaction.
    ///
    /// The profile is read from `playlist.profileId`, never supplied by the caller,
    /// so results are always scoped to the owning profile's library.
    @_disfavoredOverload
    @discardableResult
    func evaluate(playlistId: Int64) throws -> SmartPlaylistEvaluation
    @discardableResult
    func evaluate(playlistId: Int64) async throws -> SmartPlaylistEvaluation

    /// Whether the materialisation is older than `ttl`.
    ///
    /// A playlist that has never been evaluated is stale.
    ///
    /// - Throws: ``SmartPlaylistError/rulesNotFound(playlistId:)`` when the playlist
    ///   has no rules — "is it stale?" is not a question an ordinary playlist can
    ///   answer.
    @_disfavoredOverload
    func isStale(playlistId: Int64, ttl: TimeInterval) throws -> Bool
    func isStale(playlistId: Int64, ttl: TimeInterval) async throws -> Bool

    /// The ids a rule set WOULD materialise, in the order it would write them —
    /// **without writing anything**.
    ///
    /// This is the read-only half of ``evaluate(playlistId:)``: same compiler, same
    /// visibility scoping, same `LIMIT`, but it stops after the `SELECT` instead of
    /// rewriting `playlistTrack`. It exists because a propose-and-preview caller
    /// (the assistant) must be able to ask "what would these rules select?" without
    /// the question having a side effect — the same reason
    /// ``MixCandidateSource/rulesResult(trackIds:)`` takes ids rather than a
    /// playlist id.
    ///
    /// The rules are passed in rather than read from a row, so a caller can preview
    /// rules that have never been stored — an assistant request is not a playlist
    /// until the listener applies it.
    ///
    /// - Parameters:
    ///   - rules: The rule set to lower. Not persisted by this call.
    ///   - profileId: The profile the results are scoped to. Supplied by the caller
    ///     because there is no owning playlist row to derive it from.
    @_disfavoredOverload
    func previewTrackIds(matching rules: SmartPlaylistRules, profileId: Int64) throws -> [Int64]
    func previewTrackIds(matching rules: SmartPlaylistRules, profileId: Int64) async throws -> [Int64]
}
