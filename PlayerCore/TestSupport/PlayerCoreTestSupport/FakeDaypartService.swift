// FakeDaypartService — a scriptable ``DaypartProviding``.
//
// No database and no clock: the "current" daypart and each bucket's ranking are
// whatever the test seeded, so a consumer can be pinned to (say) `night` without
// waiting for night. A `struct` over a lock box rather than an `actor` because
// ``DaypartProviding/currentDaypart()`` is SYNCHRONOUS — an actor could not satisfy
// it without forcing every caller through an `await`.
import Foundation
import os
import Services

/// Thrown by ``FakeDaypartService`` when a test arms a failure.
public enum FakeDaypartError: Error, Sendable, Equatable {
    case forcedFailure
}

/// An in-memory daypart source for hermetic tests and previews.
public struct FakeDaypartService: DaypartProviding {
    /// One recorded request.
    public enum Call: Sendable, Equatable {
        case currentDaypart
        case topTracks(profileId: Int64, daypart: Daypart, limit: Int)
        case topTracksByDaypart(profileId: Int64, limit: Int)
    }

    /// Everything the fake serves and observes, guarded as one unit.
    public struct Recording: Sendable {
        /// Returned by ``currentDaypart()``.
        public var current: Daypart = .evening
        /// Served per bucket, truncated to `limit`. An absent key serves `[]`, which
        /// is how the production service reports a daypart with no history.
        public var byDaypart: [Daypart: [DaypartTrack]] = [:]
        /// Every request, in call order.
        public var calls: [Call] = []
        /// When `true`, both list requests throw ``FakeDaypartError/forcedFailure``
        /// AFTER the call is recorded. ``currentDaypart()`` cannot throw.
        public var shouldFail = false
    }

    private let state: OSAllocatedUnfairLock<Recording>

    public init(current: Daypart = .evening, byDaypart: [Daypart: [DaypartTrack]] = [:]) {
        var recording = Recording()
        recording.current = current
        recording.byDaypart = byDaypart
        state = OSAllocatedUnfairLock(initialState: recording)
    }

    /// A snapshot of everything served and recorded so far.
    public var recording: Recording {
        state.withLock { $0 }
    }

    public func setCurrent(_ daypart: Daypart) {
        state.withLock { $0.current = daypart }
    }

    public func seed(_ daypart: Daypart, tracks: [DaypartTrack]) {
        state.withLock { $0.byDaypart[daypart] = tracks }
    }

    public func setShouldFail(_ shouldFail: Bool) {
        state.withLock { $0.shouldFail = shouldFail }
    }

    public func currentDaypart() -> Daypart {
        state.withLock { recording in
            recording.calls.append(.currentDaypart)
            return recording.current
        }
    }

    public func topTracks(profileId: Int64, daypart: Daypart, limit: Int) async throws -> [DaypartTrack] {
        try state.withLock { recording in
            recording.calls.append(.topTracks(profileId: profileId, daypart: daypart, limit: limit))
            guard !recording.shouldFail else { throw FakeDaypartError.forcedFailure }
            return Array((recording.byDaypart[daypart] ?? []).prefix(max(0, limit)))
        }
    }

    public func topTracksByDaypart(profileId: Int64, limit: Int) async throws -> [Daypart: [DaypartTrack]] {
        try state.withLock { recording in
            recording.calls.append(.topTracksByDaypart(profileId: profileId, limit: limit))
            guard !recording.shouldFail else { throw FakeDaypartError.forcedFailure }
            return recording.byDaypart.compactMapValues { rows in
                let capped = Array(rows.prefix(max(0, limit)))
                return capped.isEmpty ? nil : capped
            }
        }
    }
}
