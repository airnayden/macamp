// Shared helpers for the Downloads suites: URL construction that fails loudly, and a
// lock-guarded recorder for the `@Sendable` seams.
import Foundation
import Services

enum DownloadTestURLError: Error {
    case malformed(String)
}

/// Builds a URL from a compile-time constant, throwing rather than force-unwrapping.
func downloadTestURL(_ string: String) throws -> URL {
    guard let url = URL(string: string) else { throw DownloadTestURLError.malformed(string) }
    return url
}

/// Collects seam callbacks. Lock-guarded because the seams are `@Sendable` by
/// contract, even though the doubles fire them on the main actor.
final class DownloadSeamRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [DownloadQueueSnapshot] = []
    private var progress: [DownloadState] = []

    func record(_ snapshot: DownloadQueueSnapshot) {
        lock.withLock { snapshots.append(snapshot) }
    }

    func record(_ state: DownloadState) {
        lock.withLock { progress.append(state) }
    }

    var recordedSnapshots: [DownloadQueueSnapshot] {
        lock.withLock { snapshots }
    }

    var recordedProgress: [DownloadState] {
        lock.withLock { progress }
    }

    var latestSnapshot: DownloadQueueSnapshot? {
        lock.withLock { snapshots.last }
    }
}

/// The five files one interrupted download leaves in the staging directory, named the
/// way yt-dlp's `%(title)s [%(id)s].%(ext)s` template names them.
///
/// Real files in a real directory: the purge and the sweep are filesystem operations,
/// and a double would assert the double rather than the behaviour.
enum StagingFixture {
    static let videoID = DownloadFixture.videoID

    /// The killer: post-processing output carrying NO partial marker. This is the file
    /// a retry ADOPTS as already-finished, which is how a truncated download was
    /// reported as a success.
    static let adoptableContainer = "Never Gonna Give You Up [\(videoID)].m4a"
    /// ffmpeg's in-progress mux target — adoptable in the same way once renamed.
    static let muxScratch = "Never Gonna Give You Up [\(videoID)].temp.m4a"
    /// `--embed-thumbnail`'s fetched cover.
    static let thumbnail = "Never Gonna Give You Up [\(videoID)].webp"
    /// The source stream, still marked partial — resumable, never mistaken for output.
    static let resumablePartial = "Never Gonna Give You Up [\(videoID)].webm.part"
    /// yt-dlp's own resume bookkeeping.
    static let resumeState = "Never Gonna Give You Up [\(videoID)].ytdl"

    static let ownedNames = [
        adoptableContainer,
        muxScratch,
        thumbnail,
        resumablePartial,
        resumeState,
    ]

    /// The same five artifacts, marked for any `videoID` — what a per-item purge test
    /// needs so one row's footprint is distinguishable from its sibling's.
    static func ownedNames(forVideoID videoID: String) -> [String] {
        ["m4a", "temp.m4a", "webp", "webm.part", "ytdl"].map { "Track [\(videoID)].\($0)" }
    }

    static func makeDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("macamp-purge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func remove(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }

    @discardableResult
    static func seed(_ name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name, isDirectory: false)
        try Data("x".utf8).write(to: url)
        return url
    }

    @discardableResult
    static func seedAll(_ names: [String], in directory: URL) throws -> [URL] {
        try names.map { try seed($0, in: directory) }
    }

    static func exists(_ name: String, in directory: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(name, isDirectory: false).path
        )
    }
}
