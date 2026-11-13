// FakeMixCandidateResolver — scripted artist/duration/energy for a mix pool.
//
// The ranking pipeline is a pure function of these three facts, so a test that
// wants a specific de-clump or arc shape states them here instead of building a
// library that happens to produce them.
//
// The DEFAULT is deliberately permissive: an id with no scripted entry resolves
// to an empty ``MixTrackFacts`` rather than to nothing. ``MixGeneratorService``
// DROPS candidates the resolver cannot resolve (a `playEvent` row can name a
// deleted track), so a strict fake would silently empty every draft and turn an
// ordering assertion into a vacuous one. Set ``Recording/resolvesUnknownIds`` to
// `false` to exercise that drop path on purpose.
import Foundation
import os
import Services

/// Thrown by ``FakeMixCandidateResolver`` when a test arms a failure.
public enum FakeMixCandidateResolverError: Error, Sendable, Equatable {
    case forcedFailure
}

/// An in-memory ``MixCandidateResolving`` for hermetic tests and previews.
public struct FakeMixCandidateResolver: MixCandidateResolving {
    /// One recorded call.
    public struct Request: Sendable, Equatable {
        public var profileId: Int64
        public var trackIds: [Int64]

        public init(profileId: Int64, trackIds: [Int64]) {
            self.profileId = profileId
            self.trackIds = trackIds
        }
    }

    /// Everything the fake serves and observes, guarded as one unit.
    public struct Recording: Sendable {
        /// Scripted facts, keyed by track id.
        public var facts: [Int64: MixTrackFacts] = [:]
        /// Whether an unscripted id resolves to empty facts (`true`, the
        /// default) or is reported as absent so the generator drops it.
        public var resolvesUnknownIds = true
        /// Every request, in call order.
        public var requests: [Request] = []
        /// When `true`, ``facts(profileId:trackIds:)`` throws
        /// ``FakeMixCandidateResolverError/forcedFailure`` after recording.
        public var shouldFail = false
    }

    private let state: OSAllocatedUnfairLock<Recording>

    public init(facts: [Int64: MixTrackFacts] = [:]) {
        var recording = Recording()
        recording.facts = facts
        state = OSAllocatedUnfairLock(initialState: recording)
    }

    /// A snapshot of everything served and recorded so far.
    public var recording: Recording {
        state.withLock { $0 }
    }

    public func seed(_ trackId: Int64, facts: MixTrackFacts) {
        state.withLock { $0.facts[trackId] = facts }
    }

    public func setResolvesUnknownIds(_ resolves: Bool) {
        state.withLock { $0.resolvesUnknownIds = resolves }
    }

    public func setShouldFail(_ shouldFail: Bool) {
        state.withLock { $0.shouldFail = shouldFail }
    }

    public func facts(profileId: Int64, trackIds: [Int64]) async throws -> [Int64: MixTrackFacts] {
        let request = Request(profileId: profileId, trackIds: trackIds)
        return try state.withLock { recording in
            recording.requests.append(request)
            guard !recording.shouldFail else { throw FakeMixCandidateResolverError.forcedFailure }
            var resolved: [Int64: MixTrackFacts] = [:]
            for trackId in trackIds {
                if let scripted = recording.facts[trackId] {
                    resolved[trackId] = scripted
                } else if recording.resolvesUnknownIds {
                    resolved[trackId] = MixTrackFacts()
                }
            }
            return resolved
        }
    }
}
