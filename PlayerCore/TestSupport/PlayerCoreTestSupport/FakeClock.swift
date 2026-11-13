import Foundation
import os

/// A settable clock for services that take an injected `now: @Sendable () -> Date`.
///
/// Statistics behaviour is defined against the calendar — "more than 24 whole months
/// ago", "this month" — so the only way to test a boundary honestly is to place
/// `now` exactly on it. Waiting for real time is not an option, and reading the real
/// clock would make the same test pass in June and fail in July.
///
/// `Sendable` because the seam it feeds is `@Sendable`: the compactor reads it from
/// a detached task, so the storage is lock-guarded rather than plain state.
public final class FakeClock: Sendable {
    private let state: OSAllocatedUnfairLock<Date>

    public init(_ date: Date) {
        state = OSAllocatedUnfairLock(initialState: date)
    }

    /// An instant expressed as UTC epoch seconds — the form every statistics
    /// timestamp is stored in.
    public convenience init(epochSeconds: TimeInterval) {
        self.init(Date(timeIntervalSince1970: epochSeconds))
    }

    /// The instant the clock currently reads.
    public var now: Date {
        state.withLock { $0 }
    }

    /// The seam to hand a service: `PlayEventCompactor(db, now: clock.nowProvider)`.
    public var nowProvider: @Sendable () -> Date {
        { self.now }
    }

    public func set(_ date: Date) {
        state.withLock { $0 = date }
    }

    public func advance(by interval: TimeInterval) {
        state.withLock { $0 += interval }
    }
}
