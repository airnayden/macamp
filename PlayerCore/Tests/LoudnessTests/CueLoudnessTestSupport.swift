// Doubles and fixtures for the CUE half of the loudness suites.
//
// Split out of `LoudnessScanTestSupport` purely for the 400-line file ceiling;
// both files serve the same target and nothing here is CUE-specific by
// architecture, only by the situation it exists to model.
import Foundation
import Persistence
import Services

/// A ``LoudnessMeasuring`` that serves a QUEUE of results per path, popping one
/// per call.
///
/// The per-path ``StubLoudnessScanner`` cannot express a disc image: every segment
/// of one is a separate `track` row over ONE audio file, so the seam — which sees
/// nothing but a URL — is asked the same question N times and would answer
/// identically N times. Driving it by call order is what lets a suite give each
/// segment its own measurement. Pair it with `pageSize: 1`, which makes the page
/// fan-out serial and therefore makes "call order" mean "`track.id` order".
final class SequencedLoudnessScanner: LoudnessMeasuring, @unchecked Sendable {
    private let lock = NSLock()
    private var queues: [String: [LoudnessScanResult]] = [:]
    private var requested: [URL] = []

    func enqueue(_ result: LoudnessScanResult, forPath path: String) {
        lock.withLock { queues[path, default: []].append(result) }
    }

    var scanCallCount: Int {
        lock.withLock { requested.count }
    }

    func measureLoudness(of url: URL) async throws -> LoudnessScanResult {
        let result = lock.withLock { () -> LoudnessScanResult? in
            requested.append(url)
            guard var queue = queues[url.path], !queue.isEmpty else { return nil }
            let next = queue.removeFirst()
            queues[url.path] = queue
            return next
        }
        guard let result else {
            throw LoudnessScanError.decodeFailed(url: url, reason: "no queued result")
        }
        return result
    }
}

/// One CUE segment row. `sheetPath` is `nil` to model a segment written without
/// one, which is the case the pooling key's `filePath` fallback exists for.
@discardableResult
func insertCueScanTrack(
    _ database: AppDatabase,
    path: String,
    sheetPath: String?,
    startFrame: Int64,
    endFrame: Int64? = nil,
    albumId: Int64? = nil
) throws -> TrackRecord {
    try TrackRepository(database).insert(
        TrackRecord(
            filePath: path,
            title: "Segment \(startFrame)",
            albumId: albumId,
            fileSize: ScanFixtures.fileSize,
            mtime: ScanFixtures.mtime,
            availability: .present,
            cueSheetPath: sheetPath,
            cueStartFrame: startFrame,
            cueEndFrame: endFrame
        )
    )
}
