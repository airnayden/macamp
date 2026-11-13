import Foundation
import Lyrics
import Persistence

/// An in-memory ``EnrichmentCoverageReading`` returning fixed counts — the test
/// double.
///
/// Counts are held per profile, so a consumer that must re-read on a profile
/// switch can be driven without a database. An unseeded profile reports
/// ``EnrichmentCoverageCounts/empty`` rather than failing, matching the real
/// reader's behaviour on a library the profile cannot see.
public final class FakeEnrichmentCoverageReader: EnrichmentCoverageReading, @unchecked Sendable {
    private let lock = NSLock()
    private var countsByProfile: [Int64: EnrichmentCoverageCounts]
    private var error: (any Error)?
    private var callCount = 0

    public init(countsByProfile: [Int64: EnrichmentCoverageCounts] = [:]) {
        self.countsByProfile = countsByProfile
    }

    public convenience init(
        counts: EnrichmentCoverageCounts,
        profileId: Int64 = ProfileRecord.guestID
    ) {
        self.init(countsByProfile: [profileId: counts])
    }

    /// How many times ``counts(profileId:)`` was called.
    public var countsCallCount: Int {
        lock.withLock { callCount }
    }

    public func setCounts(_ counts: EnrichmentCoverageCounts, profileId: Int64 = ProfileRecord.guestID) {
        lock.withLock { countsByProfile[profileId] = counts }
    }

    /// Makes the next (and every subsequent) read throw, until set back to `nil`.
    public func setError(_ error: (any Error)?) {
        lock.withLock { self.error = error }
    }

    public func counts(profileId: Int64) throws -> EnrichmentCoverageCounts {
        let result: Result<EnrichmentCoverageCounts, any Error> = lock.withLock {
            callCount += 1
            if let error { return .failure(error) }
            return .success(countsByProfile[profileId] ?? .empty)
        }
        return try result.get()
    }
}
