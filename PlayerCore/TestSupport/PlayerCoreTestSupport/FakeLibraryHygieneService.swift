// FakeLibraryHygieneService — a scriptable ``LibraryHygieneProviding``.
//
// No database and no library walk: each list is whatever the test seeded, so a
// consumer (the assistant's hygiene mapping, a summary card) can be driven through
// a rich library, a pristine one, and a failing read without a fixture library.
//
// ``findings(profileId:limit:)`` is served by CONCATENATING the three seeded lists
// in the production service's own category order rather than from a fourth seed —
// so a test cannot accidentally script a `findings` result that disagrees with the
// per-category ones it also asserts on.
//
// A `struct` over a lock box rather than an `actor`, matching every other Fake here:
// the protocol is `Sendable` but not actor-isolated, and a lock box keeps the
// recorded call order readable from a synchronous assertion without an `await`.
import Foundation
import os
import Services

/// Thrown by ``FakeLibraryHygieneService`` when a test arms a failure.
public enum FakeLibraryHygieneError: Error, Sendable, Equatable {
    case forcedFailure
}

/// An in-memory hygiene source for hermetic tests and previews.
public struct FakeLibraryHygieneService: LibraryHygieneProviding {
    /// One recorded request.
    public enum Call: Sendable, Equatable {
        case duplicateGroups(profileId: Int64, limit: Int)
        case genreClusters(profileId: Int64, limit: Int)
        case metadataGaps(profileId: Int64, limit: Int)
        case findings(profileId: Int64, limit: Int)
    }

    /// Everything the fake serves and observes, guarded as one unit.
    public struct Recording: Sendable {
        /// Served by ``duplicateGroups(profileId:limit:)``, truncated to `limit`.
        public var duplicateGroups: [DuplicateGroup] = []
        /// Served by ``genreClusters(profileId:limit:)``, truncated to `limit`.
        public var genreClusters: [GenreCluster] = []
        /// Served by ``metadataGaps(profileId:limit:)``, truncated to `limit`.
        public var metadataGaps: [MetadataGap] = []
        /// Every request, in call order.
        public var calls: [Call] = []
        /// When `true`, every read throws ``FakeLibraryHygieneError/forcedFailure``
        /// AFTER the call is recorded.
        public var shouldFail = false
    }

    private let state: OSAllocatedUnfairLock<Recording>

    public init(
        duplicateGroups: [DuplicateGroup] = [],
        genreClusters: [GenreCluster] = [],
        metadataGaps: [MetadataGap] = []
    ) {
        var recording = Recording()
        recording.duplicateGroups = duplicateGroups
        recording.genreClusters = genreClusters
        recording.metadataGaps = metadataGaps
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
        duplicateGroups: [DuplicateGroup]? = nil,
        genreClusters: [GenreCluster]? = nil,
        metadataGaps: [MetadataGap]? = nil
    ) {
        state.withLock { recording in
            if let duplicateGroups { recording.duplicateGroups = duplicateGroups }
            if let genreClusters { recording.genreClusters = genreClusters }
            if let metadataGaps { recording.metadataGaps = metadataGaps }
        }
    }

    public func duplicateGroups(profileId: Int64, limit: Int) async throws -> [DuplicateGroup] {
        try serve(.duplicateGroups(profileId: profileId, limit: limit)) { recording in
            Array(recording.duplicateGroups.prefix(max(0, limit)))
        }
    }

    public func genreClusters(profileId: Int64, limit: Int) async throws -> [GenreCluster] {
        try serve(.genreClusters(profileId: profileId, limit: limit)) { recording in
            Array(recording.genreClusters.prefix(max(0, limit)))
        }
    }

    public func metadataGaps(profileId: Int64, limit: Int) async throws -> [MetadataGap] {
        try serve(.metadataGaps(profileId: profileId, limit: limit)) { recording in
            Array(recording.metadataGaps.prefix(max(0, limit)))
        }
    }

    public func findings(profileId: Int64, limit: Int) async throws -> [HygieneFinding] {
        try serve(.findings(profileId: profileId, limit: limit)) { recording in
            Array(Self.allFindings(in: recording).prefix(max(0, limit)))
        }
    }
}

private extension FakeLibraryHygieneService {
    /// Records the call, honours an armed failure, then serves whatever `list`
    /// derives from the seeded state.
    func serve<Element: Sendable>(
        _ call: Call,
        _ list: @Sendable (Recording) -> [Element]
    ) throws -> [Element] {
        try state.withLock { recording in
            recording.calls.append(call)
            guard !recording.shouldFail else { throw FakeLibraryHygieneError.forcedFailure }
            return list(recording)
        }
    }

    /// The three seeded lists in the production service's category order.
    static func allFindings(in recording: Recording) -> [HygieneFinding] {
        recording.duplicateGroups.map(HygieneFinding.duplicate)
            + recording.genreClusters.map(HygieneFinding.genreCluster)
            + recording.metadataGaps.map(HygieneFinding.metadataGap)
    }
}
