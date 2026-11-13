// Shared helpers + doubles for the AudioAnalysisService suites.
//
// `pollUntil` lets an async @MainActor test wait for the background analysis Task
// to deliver onto the main actor without a fixed sleep (the EnrichmentTests
// precedent). `BlockingFeatureExtractor` halts a pass mid-flight so cancellation
// is exercised deterministically rather than by racing a timer.
import Foundation
import GRDB
import Persistence
import Services

// MARK: - Waiting

@MainActor
func pollUntil(timeout: Duration = .seconds(10), _ condition: () -> Bool) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
        if clock.now >= deadline { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
}

// MARK: - Fixtures

/// The fingerprint every freshly-inserted fixture track carries.
enum Fingerprint {
    static let fileSize: Int64 = 1024
    static let mtime = 100.0
}

@discardableResult
func insertTrack(
    _ database: AppDatabase,
    path: String,
    availability: Availability = .present,
    fileSize: Int64? = Fingerprint.fileSize,
    mtime: Double? = Fingerprint.mtime
) throws -> TrackRecord {
    try TrackRepository(database).insert(
        TrackRecord(
            filePath: path,
            title: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
            fileSize: fileSize,
            mtime: mtime,
            availability: availability
        )
    )
}

/// Inserts `count` present, never-analysed tracks named `/music/track-1.flac` …
@discardableResult
func insertTracks(_ database: AppDatabase, count: Int) throws -> [TrackRecord] {
    try (1 ... count).map { try insertTrack(database, path: "/music/track-\($0).flac") }
}

/// Writes an analysis row directly, so a test can set up an already-fresh (or
/// deliberately stale) track without running the service.
func insertFeature(
    _ database: AppDatabase,
    trackId: Int64,
    fileSize: Int64 = Fingerprint.fileSize,
    mtime: Double = Fingerprint.mtime,
    analysisVersion: Int = AudioAnalysisService.analysisVersion,
    computedAt: Double = 0
) throws {
    let record = TrackAudioFeatureRecord(
        trackId: trackId,
        fileSize: fileSize,
        mtime: mtime,
        bpm: 90,
        energy: 0.1,
        brightness: 0.1,
        analysisVersion: analysisVersion,
        computedAt: computedAt
    )
    try database.writer.write { db in try record.insert(db) }
}

func fetchFeature(_ database: AppDatabase, trackId: Int64) throws -> TrackAudioFeatureRecord? {
    try database.writer.read { db in
        try TrackAudioFeatureRecord.fetchOne(db, key: trackId)
    }
}

func featureCount(_ database: AppDatabase) throws -> Int {
    try database.writer.read { db in try TrackAudioFeatureRecord.fetchCount(db) }
}

/// Every analysis row, for assertions that cannot name the track they expect.
func allFeatures(_ database: AppDatabase) throws -> [TrackAudioFeatureRecord] {
    try database.writer.read { db in try TrackAudioFeatureRecord.fetchAll(db) }
}

func url(of track: TrackRecord) -> URL {
    URL(fileURLWithPath: track.filePath)
}

// MARK: - Doubles

/// An ``AudioFeatureExtracting`` that serves `blockAfter` calls immediately, then
/// suspends on a long, cancellable sleep — the `BlockingMetadataFetcher` shape
/// from the Enrichment suites. Lets a test prove rows committed before a
/// ``AudioAnalysisService/stop()`` survive it, with no reliance on timing.
final class BlockingFeatureExtractor: AudioFeatureExtracting, @unchecked Sendable {
    private let result: AudioFeatureResult
    private let blockAfter: Int
    private let lock = NSLock()
    private var requested: [URL] = []

    init(returning result: AudioFeatureResult = FeatureFixtures.result, blockAfter: Int = 1) {
        self.result = result
        self.blockAfter = blockAfter
    }

    var requestedURLs: [URL] {
        lock.withLock { requested }
    }

    var extractCallCount: Int {
        lock.withLock { requested.count }
    }

    func extractFeatures(from url: URL) async throws -> AudioFeatureResult {
        let ordinal = lock.withLock { () -> Int in
            requested.append(url)
            return requested.count
        }
        if ordinal > blockAfter {
            try await Task.sleep(for: .seconds(60))
        }
        return result
    }
}

/// An ``AudioFeatureExtracting`` that records how many extractions overlap.
///
/// While `isHeld` every call parks on a cancellable sleep, so a test observes the
/// steady-state fan-out instead of racing whichever extraction finishes first —
/// with a zero-latency double the pass could complete each track before starting
/// the next and "max concurrency 1" would be a false negative.
final class ConcurrencyRecordingExtractor: AudioFeatureExtracting, @unchecked Sendable {
    private let lock = NSLock()
    private let failing: Set<URL>
    private var isHeld: Bool
    private var inFlight = 0
    private var observedMax = 0
    private var started: [URL] = []

    /// - Parameters:
    ///   - held: When `true`, extractions park until ``release()``.
    ///   - failing: URLs that throw instead of returning features.
    init(held: Bool = false, failing: Set<URL> = []) {
        isHeld = held
        self.failing = failing
    }

    func extractFeatures(from url: URL) async throws -> AudioFeatureResult {
        lock.withLock {
            started.append(url)
            inFlight += 1
            observedMax = max(observedMax, inFlight)
        }
        defer { lock.withLock { inFlight -= 1 } }
        while lock.withLock({ isHeld }) {
            try await Task.sleep(for: .milliseconds(5))
        }
        if failing.contains(url) {
            throw AudioFeatureError.decodeFailed(url: url, reason: "held fixture")
        }
        return FeatureFixtures.result
    }

    /// The greatest number of extractions ever in flight at the same instant.
    var maxObservedConcurrency: Int {
        lock.withLock { observedMax }
    }

    var inFlightCount: Int {
        lock.withLock { inFlight }
    }

    var startCount: Int {
        lock.withLock { started.count }
    }

    var requestedURLs: [URL] {
        lock.withLock { started }
    }

    func release() {
        lock.withLock { isHeld = false }
    }
}

/// The canned analysis every suite asserts against.
enum FeatureFixtures {
    static let result = AudioFeatureResult(bpm: 128, energy: 0.75, brightness: 0.42)

    /// The fixed instant the injected clock reports, so `computedAt` is exactly
    /// assertable instead of "roughly now".
    static let epoch = Date(timeIntervalSince1970: 1_700_000_000)
}
