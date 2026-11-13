// FakeSimilarityService — a scripted ``SimilarityProviding``.
//
// No database, no scan, no scoring: a consumer states the neighbours it wants back
// and asserts on the requests it made. It is a `struct` over a lock box rather than
// an `actor`, matching ``FakePlaySegmentHeatRepository`` — an actor's methods hop to
// the actor's own executor, which would make "this ran off the main thread" true by
// construction and therefore worthless as an assertion.
//
// ``similar(to:profileId:limit:)`` is implemented EXPLICITLY rather than inherited
// from the protocol's default, so a test can script the fallback decision itself
// instead of re-deriving it from the two other stubs.
import Foundation
import os
import Services

/// Thrown by ``FakeSimilarityService`` when a test arms a failure.
public enum FakeSimilarityError: Error, Sendable, Equatable {
    case forcedFailure
}

/// A scripted similarity source for hermetic tests and previews.
public struct FakeSimilarityService: SimilarityProviding {
    /// One recorded call.
    public struct Request: Sendable, Equatable {
        public var trackId: Int64
        public var profileId: Int64
        public var limit: Int

        public init(trackId: Int64, profileId: Int64, limit: Int) {
            self.trackId = trackId
            self.profileId = profileId
            self.limit = limit
        }
    }

    /// Everything the fake returns and observes, guarded as one unit.
    public struct Recording: Sendable {
        /// Returned by ``coOccurring(with:profileId:limit:)``, truncated to `limit`.
        public var coOccurring: [SimilarTrack] = []
        /// Returned by ``metadataNeighbors(for:profileId:limit:)``, truncated to `limit`.
        public var metadataNeighbors: [SimilarTrack] = []
        /// Co-session requests, in call order.
        public var coOccurringRequests: [Request] = []
        /// Cold-start requests, in call order.
        public var metadataRequests: [Request] = []
        /// Combined requests, in call order.
        public var similarRequests: [Request] = []
        /// When `true`, every call throws ``FakeSimilarityError/forcedFailure``.
        public var shouldFail = false
    }

    private let state: OSAllocatedUnfairLock<Recording>

    public init(
        coOccurring: [SimilarTrack] = [],
        metadataNeighbors: [SimilarTrack] = []
    ) {
        var recording = Recording()
        recording.coOccurring = coOccurring
        recording.metadataNeighbors = metadataNeighbors
        state = OSAllocatedUnfairLock(initialState: recording)
    }

    /// A snapshot of everything recorded so far.
    public var recording: Recording {
        state.withLock { $0 }
    }

    public func setCoOccurring(_ neighbours: [SimilarTrack]) {
        state.withLock { $0.coOccurring = neighbours }
    }

    public func setMetadataNeighbors(_ neighbours: [SimilarTrack]) {
        state.withLock { $0.metadataNeighbors = neighbours }
    }

    public func setShouldFail(_ shouldFail: Bool) {
        state.withLock { $0.shouldFail = shouldFail }
    }

    public func coOccurring(with trackId: Int64, profileId: Int64, limit: Int) async throws -> [SimilarTrack] {
        let request = Request(trackId: trackId, profileId: profileId, limit: limit)
        return try state.withLock { recording in
            recording.coOccurringRequests.append(request)
            guard !recording.shouldFail else { throw FakeSimilarityError.forcedFailure }
            return Array(recording.coOccurring.prefix(max(0, limit)))
        }
    }

    public func metadataNeighbors(for trackId: Int64, profileId: Int64, limit: Int) async throws -> [SimilarTrack] {
        let request = Request(trackId: trackId, profileId: profileId, limit: limit)
        return try state.withLock { recording in
            recording.metadataRequests.append(request)
            guard !recording.shouldFail else { throw FakeSimilarityError.forcedFailure }
            return Array(recording.metadataNeighbors.prefix(max(0, limit)))
        }
    }

    /// Mirrors the production fallback — co-session unless it is empty — while
    /// recording the combined call separately from the two it delegates to.
    public func similar(to trackId: Int64, profileId: Int64, limit: Int) async throws -> [SimilarTrack] {
        let request = Request(trackId: trackId, profileId: profileId, limit: limit)
        state.withLock { $0.similarRequests.append(request) }
        let coPlayed = try await coOccurring(with: trackId, profileId: profileId, limit: limit)
        guard coPlayed.isEmpty else { return coPlayed }
        return try await metadataNeighbors(for: trackId, profileId: profileId, limit: limit)
    }
}
