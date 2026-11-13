// FakeGeneratedPlaylistService — a scripted ``GeneratedPlaylistProviding``.
//
// No database, no generator, no refresh: a consumer states what the auto-mixes
// look like and asserts which profiles it asked about. That is what a composition
// root needs ("a launch with the master toggle off refreshes nothing") and what an
// iOS surface that only LISTS generated playlists needs, neither of which should
// have to migrate a database to be tested.
import Services

/// A canned ``GeneratedPlaylistProviding`` that refreshes nothing and remembers
/// everything.
@MainActor
public final class FakeGeneratedPlaylistService: GeneratedPlaylistProviding {
    /// Every profile ``refreshIfStale(profileId:)`` was called for, in call order.
    /// Empty proves a gated path never ran.
    public private(set) var refreshedProfileIds: [Int64] = []

    /// Every profile ``generatedPlaylists(profileId:)`` was asked about.
    public private(set) var listedProfileIds: [Int64] = []

    /// Served by ``refreshIfStale(profileId:)``.
    public var refreshes: [GeneratedPlaylistRefresh] = []

    /// Served by ``generatedPlaylists(profileId:)``.
    public var summaries: [GeneratedPlaylistSummary] = []

    /// Thrown by both methods AFTER the call is recorded, so a test can assert the
    /// call happened and still exercise the caller's failure path.
    public var error: (any Error)?

    public init() {}

    @discardableResult
    public func refreshIfStale(profileId: Int64) async throws -> [GeneratedPlaylistRefresh] {
        refreshedProfileIds.append(profileId)
        if let error { throw error }
        return refreshes
    }

    public func generatedPlaylists(profileId: Int64) async throws -> [GeneratedPlaylistSummary] {
        listedProfileIds.append(profileId)
        if let error { throw error }
        return summaries
    }
}
