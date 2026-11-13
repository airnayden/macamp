// LoudnessScanTestSupport — the doubles and the library fixture the loudness
// suites share.
//
// Split from `LoudnessScanViewModelTests.swift` purely to keep each source under
// the SwiftLint file-length limit.
import Foundation
import GRDB
import Persistence
import Services

// MARK: - Doubles

/// A canned ``LoudnessScanning`` that measures nothing and remembers everything.
@MainActor
final class FakeLoudnessScanService: LoudnessScanning {
    private(set) var isRunning = false
    private(set) var isPaused = false
    private(set) var progress: (completed: Int, total: Int) = (0, 0)
    private(set) var failedCount = 0
    private(set) var currentTrack: String?

    var onChange: (@MainActor () -> Void)?

    private(set) var startCount = 0
    private(set) var fullReanalysisCount = 0
    private(set) var pauseCount = 0
    private(set) var resumeCount = 0
    private(set) var stopCount = 0

    func start() {
        startCount += 1
        begin()
    }

    func startFullReanalysis() {
        fullReanalysisCount += 1
        begin()
    }

    func pause() {
        pauseCount += 1
        guard isRunning, !isPaused else { return }
        isPaused = true
        onChange?()
    }

    func resume() {
        resumeCount += 1
        guard isRunning, isPaused else { return }
        isPaused = false
        onChange?()
    }

    func stop() {
        stopCount += 1
        isRunning = false
        isPaused = false
        currentTrack = nil
        onChange?()
    }

    func simulateProgress(completed: Int, total: Int, currentTrack: String? = nil, failedCount: Int = 0) {
        isRunning = true
        progress = (completed, total)
        self.currentTrack = currentTrack
        self.failedCount = failedCount
        onChange?()
    }

    private func begin() {
        guard !isRunning else { return }
        isRunning = true
        isPaused = false
        currentTrack = nil
        progress = (0, 0)
        failedCount = 0
        onChange?()
    }
}

/// Records every batch handed to the invalidation seam, in call order.
///
/// An actor because ``TrackLoudnessInvalidating`` is `Sendable` and its one
/// requirement is `async` — an actor-isolated member satisfies it, so no
/// `@unchecked` is needed.
actor RecordingLoudnessInvalidator: TrackLoudnessInvalidating {
    private(set) var batches: [[Int64]] = []

    func deleteLoudness(forTrackIds trackIds: [Int64]) async throws {
        batches.append(trackIds)
    }
}

// MARK: - Fixture

/// A library seeded straight through `Persistence`, with no scan service
/// involved — so a coverage assertion cannot be satisfied by a pass's own
/// progress bookkeeping.
enum LoudnessCoverageFixture {
    static let fileSize: Int64 = 4096
    static let mtime = 99.0

    static func makeLibrary(
        presentCount: Int,
        measuredCount: Int,
        missingCount: Int = 0
    ) throws -> AppDatabase {
        let database = try AppDatabase.makeEmpty()
        let repository = TrackRepository(database)
        for index in 0 ..< presentCount {
            let track = try repository.insert(makeRecord(index: index, availability: .present))
            guard index < measuredCount, let trackId = track.id else { continue }
            try measure(database, trackIds: [trackId])
        }
        for index in 0 ..< missingCount {
            _ = try repository.insert(makeRecord(index: presentCount + index, availability: .missing))
        }
        return database
    }

    static func measure(_ database: AppDatabase, trackIds: [Int64]) throws {
        try database.writer.write { db in
            for trackId in trackIds {
                try TrackLoudnessRecord(
                    trackId: trackId,
                    integratedLUFS: -14.5,
                    truePeak: 0.98,
                    analysisVersion: LoudnessScanService.analysisVersion,
                    fingerprint: TrackLoudnessFingerprint(fileSize: fileSize, mtime: mtime),
                    computedAt: 0
                ).upsert(db)
            }
        }
    }

    /// Rewrites one row's fingerprint so it no longer describes the file on disk.
    static func staleFingerprint(_ database: AppDatabase, trackId: Int64) throws {
        try database.writer.write { db in
            try db.execute(
                sql: "UPDATE trackLoudness SET mtime = ? WHERE trackId = ?",
                arguments: [mtime + 1, trackId]
            )
        }
    }

    private static func makeRecord(index: Int, availability: Availability) -> TrackRecord {
        TrackRecord(
            filePath: "/music/loudness-\(index).flac",
            title: "Loudness \(index)",
            sortTitle: "loudness \(index)",
            fileSize: fileSize,
            mtime: mtime,
            availability: availability
        )
    }
}
