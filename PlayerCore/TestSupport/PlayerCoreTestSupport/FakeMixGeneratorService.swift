// FakeMixGeneratorService — a scripted ``MixGenerating``.
//
// No pools, no ranking, no database: a consumer states the draft it wants back
// and asserts on the specs it was asked for. That is what todo 9's generated
// playlists need — "did a refresh ask for the right mix, and did it materialise
// exactly what the generator returned" — without re-testing the ranking
// pipeline, which owns its own suite.
//
// A `struct` over a lock box rather than an `actor`, matching
// ``FakeSimilarityService``: an actor's methods hop to its own executor, which
// would make "this ran off the calling actor" true by construction and therefore
// worthless as an assertion.
import Foundation
import os
import Services

/// Thrown by ``FakeMixGeneratorService`` when a test arms a failure.
public enum FakeMixGeneratorError: Error, Sendable, Equatable {
    case forcedFailure
}

/// An in-memory mix generator for hermetic tests and previews.
public struct FakeMixGeneratorService: MixGenerating {
    /// Everything the fake serves and observes, guarded as one unit.
    public struct Recording: Sendable {
        /// Served by ``generate(_:)`` unless ``draftsBySourceKind`` has a match.
        public var draft: PlaylistDraft = .empty()
        /// Per-source overrides, so one fake can serve a daypart mix and a
        /// rediscovery mix differently in the same test.
        public var draftsBySourceKind: [MixSourceKind: PlaylistDraft] = [:]
        /// Every spec the fake was asked for, in call order.
        public var specs: [MixSpec] = []
        /// When `true`, ``generate(_:)`` throws
        /// ``FakeMixGeneratorError/forcedFailure`` AFTER recording the spec —
        /// so a test can assert the call happened and still exercise the
        /// caller's rollback path.
        public var shouldFail = false
    }

    private let state: OSAllocatedUnfairLock<Recording>

    public init(draft: PlaylistDraft = .empty()) {
        var recording = Recording()
        recording.draft = draft
        state = OSAllocatedUnfairLock(initialState: recording)
    }

    /// A snapshot of everything served and recorded so far.
    public var recording: Recording {
        state.withLock { $0 }
    }

    public func setDraft(_ draft: PlaylistDraft) {
        state.withLock { $0.draft = draft }
    }

    public func seed(_ sourceKind: MixSourceKind, draft: PlaylistDraft) {
        state.withLock { $0.draftsBySourceKind[sourceKind] = draft }
    }

    public func setShouldFail(_ shouldFail: Bool) {
        state.withLock { $0.shouldFail = shouldFail }
    }

    public func generate(_ spec: MixSpec) async throws -> PlaylistDraft {
        try state.withLock { recording in
            recording.specs.append(spec)
            guard !recording.shouldFail else { throw FakeMixGeneratorError.forcedFailure }
            return recording.draftsBySourceKind[spec.source.kind] ?? recording.draft
        }
    }
}
