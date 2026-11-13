// FakeSmartPlaylistRepository — a scripted ``SmartPlaylistRepositoryProviding``.
//
// No database, no compiler, no materialisation: a consumer states the rules and
// evaluations it wants back and asserts on the calls it made. A `struct` over a lock
// box rather than an `actor`, matching ``FakeSimilarityService`` — an actor's methods
// hop to the actor's own executor, which would make "this ran off the main thread"
// true by construction and therefore worthless as an assertion.
//
// ``setRules(_:forPlaylist:)`` records the rules AND stores them, so a test can drive
// a full set-then-read round trip without scripting both halves.
import Foundation
import os
import Persistence

/// Thrown by ``FakeSmartPlaylistRepository`` when a test arms a failure.
public enum FakeSmartPlaylistError: Error, Sendable, Equatable {
    case forcedFailure
}

/// A scripted smart-playlist repository for hermetic tests and previews.
public struct FakeSmartPlaylistRepository: SmartPlaylistRepositoryProviding {
    /// One recorded staleness question.
    public struct StalenessRequest: Sendable, Equatable {
        public var playlistId: Int64
        public var ttl: TimeInterval

        public init(playlistId: Int64, ttl: TimeInterval) {
            self.playlistId = playlistId
            self.ttl = ttl
        }
    }

    /// One recorded read-only preview.
    public struct PreviewRequest: Sendable, Equatable {
        public var rules: SmartPlaylistRules
        public var profileId: Int64

        public init(rules: SmartPlaylistRules, profileId: Int64) {
            self.rules = rules
            self.profileId = profileId
        }
    }

    /// Everything the fake returns and observes, guarded as one unit.
    public struct Recording: Sendable {
        /// Rules by playlist id — seeded up front, and written by `setRules`.
        public var rules: [Int64: SmartPlaylistRules] = [:]
        /// Returned by `evaluate`; a playlist with no entry evaluates to no tracks.
        public var evaluations: [Int64: SmartPlaylistEvaluation] = [:]
        /// Returned by `isStale`; a playlist with no entry is stale.
        public var staleness: [Int64: Bool] = [:]
        /// The profile stamped on a synthesised ``SmartPlaylistEvaluation``.
        public var profileId: Int64 = ProfileRecord.guestID
        /// Rule writes, in call order.
        public var setRulesRequests: [Int64] = []
        /// Rule reads, in call order.
        public var rulesRequests: [Int64] = []
        /// Evaluations, in call order.
        public var evaluateRequests: [Int64] = []
        /// Staleness questions, in call order.
        public var stalenessRequests: [StalenessRequest] = []
        /// Served by every `previewTrackIds` call — one shared pool, not a
        /// per-rules map, so a fanned-out request asserts its variants through
        /// ``previewRequests`` instead of having to script each one.
        public var previewTrackIds: [Int64] = []
        /// Read-only previews, in call order.
        public var previewRequests: [PreviewRequest] = []
        /// When `true`, every call throws ``FakeSmartPlaylistError/forcedFailure``.
        public var shouldFail = false
    }

    private let state: OSAllocatedUnfairLock<Recording>

    public init(
        rules: [Int64: SmartPlaylistRules] = [:],
        evaluations: [Int64: SmartPlaylistEvaluation] = [:],
        staleness: [Int64: Bool] = [:]
    ) {
        var recording = Recording()
        recording.rules = rules
        recording.evaluations = evaluations
        recording.staleness = staleness
        state = OSAllocatedUnfairLock(initialState: recording)
    }

    /// A snapshot of everything recorded so far.
    public var recording: Recording {
        state.withLock { $0 }
    }

    /// Mutates the script — arm a failure, seed rules, change the profile.
    public func configure(_ mutate: @Sendable (inout Recording) -> Void) {
        state.withLock { mutate(&$0) }
    }

    @_disfavoredOverload
    @discardableResult
    public func setRules(
        _ rules: SmartPlaylistRules,
        forPlaylist playlistId: Int64
    ) throws -> SmartPlaylistRecord {
        try performSetRules(rules, playlistId: playlistId)
    }

    @discardableResult
    public func setRules(
        _ rules: SmartPlaylistRules,
        forPlaylist playlistId: Int64
    ) async throws -> SmartPlaylistRecord {
        try performSetRules(rules, playlistId: playlistId)
    }

    @_disfavoredOverload
    public func rules(forPlaylist playlistId: Int64) throws -> SmartPlaylistRules? {
        try performRules(playlistId: playlistId)
    }

    public func rules(forPlaylist playlistId: Int64) async throws -> SmartPlaylistRules? {
        try performRules(playlistId: playlistId)
    }

    @_disfavoredOverload
    @discardableResult
    public func evaluate(playlistId: Int64) throws -> SmartPlaylistEvaluation {
        try performEvaluate(playlistId: playlistId)
    }

    @discardableResult
    public func evaluate(playlistId: Int64) async throws -> SmartPlaylistEvaluation {
        try performEvaluate(playlistId: playlistId)
    }

    @_disfavoredOverload
    public func isStale(playlistId: Int64, ttl: TimeInterval) throws -> Bool {
        try performIsStale(playlistId: playlistId, ttl: ttl)
    }

    public func isStale(playlistId: Int64, ttl: TimeInterval) async throws -> Bool {
        try performIsStale(playlistId: playlistId, ttl: ttl)
    }

    @_disfavoredOverload
    public func previewTrackIds(matching rules: SmartPlaylistRules, profileId: Int64) throws -> [Int64] {
        try performPreview(rules: rules, profileId: profileId)
    }

    public func previewTrackIds(matching rules: SmartPlaylistRules, profileId: Int64) async throws -> [Int64] {
        try performPreview(rules: rules, profileId: profileId)
    }
}

// MARK: - Shared bodies

///
/// Both overloads of each requirement funnel through these. A sync twin cannot simply
/// be called from its `async` sibling: overload resolution inside an `async` context
/// picks the `async` one and the function recurses into itself.
private extension FakeSmartPlaylistRepository {
    func performSetRules(_ rules: SmartPlaylistRules, playlistId: Int64) throws -> SmartPlaylistRecord {
        try state.withLock { recording in
            recording.setRulesRequests.append(playlistId)
            guard !recording.shouldFail else { throw FakeSmartPlaylistError.forcedFailure }
            recording.rules[playlistId] = rules
            return SmartPlaylistRecord(
                playlistId: playlistId,
                rulesJson: (try? rules.encodedJSON()) ?? "",
                rulesVersion: rules.schemaVersion
            )
        }
    }

    func performRules(playlistId: Int64) throws -> SmartPlaylistRules? {
        try state.withLock { recording in
            recording.rulesRequests.append(playlistId)
            guard !recording.shouldFail else { throw FakeSmartPlaylistError.forcedFailure }
            return recording.rules[playlistId]
        }
    }

    func performEvaluate(playlistId: Int64) throws -> SmartPlaylistEvaluation {
        try state.withLock { recording in
            recording.evaluateRequests.append(playlistId)
            guard !recording.shouldFail else { throw FakeSmartPlaylistError.forcedFailure }
            if let scripted = recording.evaluations[playlistId] { return scripted }
            return SmartPlaylistEvaluation(
                playlistId: playlistId,
                profileId: recording.profileId,
                trackIds: [],
                evaluatedAt: 0
            )
        }
    }

    func performPreview(rules: SmartPlaylistRules, profileId: Int64) throws -> [Int64] {
        try state.withLock { recording in
            recording.previewRequests.append(PreviewRequest(rules: rules, profileId: profileId))
            guard !recording.shouldFail else { throw FakeSmartPlaylistError.forcedFailure }
            return recording.previewTrackIds
        }
    }

    func performIsStale(playlistId: Int64, ttl: TimeInterval) throws -> Bool {
        try state.withLock { recording in
            recording.stalenessRequests.append(StalenessRequest(playlistId: playlistId, ttl: ttl))
            guard !recording.shouldFail else { throw FakeSmartPlaylistError.forcedFailure }
            return recording.staleness[playlistId] ?? true
        }
    }
}
