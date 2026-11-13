// FakeRediscoveryService — a scriptable ``RediscoveryProviding``.
//
// No database and no clock: each of the three lists is whatever the test seeded, so
// a consumer (the mix generator, the generated-playlist service, the assistant) can
// be driven through every shape — rich, empty, failing — without a fixture library.
//
// A `struct` over a lock box rather than an `actor`, for two reasons: the protocol
// is `Sendable` but not actor-isolated, and a lock box keeps the recorded call order
// readable from a synchronous assertion without an `await`.
import Foundation
import os
import Services

/// Thrown by ``FakeRediscoveryService`` when a test arms a failure.
public enum FakeRediscoveryError: Error, Sendable, Equatable {
    case forcedFailure
}

/// An in-memory rediscovery source for hermetic tests and previews.
public struct FakeRediscoveryService: RediscoveryProviding {
    /// One recorded request.
    public enum Call: Sendable, Equatable {
        case forgottenFavourites(profileId: Int64, limit: Int)
        case neverPlayed(profileId: Int64, limit: Int)
        case throwbacks(profileId: Int64, limit: Int)
    }

    /// Everything the fake serves and observes, guarded as one unit.
    public struct Recording: Sendable {
        /// Served by ``forgottenFavourites(profileId:limit:)``, truncated to `limit`.
        public var forgottenFavourites: [RediscoveryCandidate] = []
        /// Served by ``neverPlayed(profileId:limit:)``, truncated to `limit`.
        public var neverPlayed: [RediscoveryCandidate] = []
        /// Served by ``throwbacks(profileId:limit:)``, truncated to `limit`.
        public var throwbacks: [RediscoveryCandidate] = []
        /// Every request, in call order.
        public var calls: [Call] = []
        /// When `true`, every list throws ``FakeRediscoveryError/forcedFailure``
        /// AFTER the call is recorded.
        public var shouldFail = false
    }

    private let state: OSAllocatedUnfairLock<Recording>

    public init(
        forgottenFavourites: [RediscoveryCandidate] = [],
        neverPlayed: [RediscoveryCandidate] = [],
        throwbacks: [RediscoveryCandidate] = []
    ) {
        var recording = Recording()
        recording.forgottenFavourites = forgottenFavourites
        recording.neverPlayed = neverPlayed
        recording.throwbacks = throwbacks
        state = OSAllocatedUnfairLock(initialState: recording)
    }

    /// A snapshot of everything served and recorded so far.
    public var recording: Recording {
        state.withLock { $0 }
    }

    public func setShouldFail(_ shouldFail: Bool) {
        state.withLock { $0.shouldFail = shouldFail }
    }

    public func seed(
        forgottenFavourites: [RediscoveryCandidate]? = nil,
        neverPlayed: [RediscoveryCandidate]? = nil,
        throwbacks: [RediscoveryCandidate]? = nil
    ) {
        state.withLock { recording in
            if let forgottenFavourites { recording.forgottenFavourites = forgottenFavourites }
            if let neverPlayed { recording.neverPlayed = neverPlayed }
            if let throwbacks { recording.throwbacks = throwbacks }
        }
    }

    public func forgottenFavourites(profileId: Int64, limit: Int) async throws -> [RediscoveryCandidate] {
        try serve(.forgottenFavourites(profileId: profileId, limit: limit), limit: limit)
    }

    public func neverPlayed(profileId: Int64, limit: Int) async throws -> [RediscoveryCandidate] {
        try serve(.neverPlayed(profileId: profileId, limit: limit), limit: limit)
    }

    public func throwbacks(profileId: Int64, limit: Int) async throws -> [RediscoveryCandidate] {
        try serve(.throwbacks(profileId: profileId, limit: limit), limit: limit)
    }
}

private extension FakeRediscoveryService {
    /// Records the call, honours an armed failure, then serves the seeded list
    /// truncated exactly the way the production service caps its own output.
    func serve(_ call: Call, limit: Int) throws -> [RediscoveryCandidate] {
        try state.withLock { recording in
            recording.calls.append(call)
            guard !recording.shouldFail else { throw FakeRediscoveryError.forcedFailure }
            return Array(Self.list(for: call, in: recording).prefix(max(0, limit)))
        }
    }

    /// Which seeded list a request is asking for. A `switch` (never a `default:`) so
    /// a fourth list cannot be added to ``Call`` without wiring it here.
    static func list(for call: Call, in recording: Recording) -> [RediscoveryCandidate] {
        switch call {
        case .forgottenFavourites: recording.forgottenFavourites
        case .neverPlayed: recording.neverPlayed
        case .throwbacks: recording.throwbacks
        }
    }
}
