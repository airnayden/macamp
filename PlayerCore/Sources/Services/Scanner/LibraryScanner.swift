// LibraryScanner — resumable, bounded-memory audio import into the GRDB library.
//
// Design (Task 13):
//   * sources: .directory (recursive walk), .files, .manifest (pre-fingerprinted)
//   * fingerprint skip: unchanged files (mtime + size) are never re-read
//   * chunked single-transaction persistence: per chunk = 1 read-tx (fetch
//     existing by path) -> bounded-concurrency metadata read -> 1 batched
//     write-tx (insert new) [+ 1 write-tx for changed rows]. Never per-file
//     autocommit; never holds the writer lock for the whole import.
//   * AsyncStream progress tied to the scan task lifetime (drop ⇒ cancel)
//   * cancellation at chunk boundaries leaves committed chunks persisted
//
// Imports only Foundation/GRDB/Persistence/Metadata — no AppKit/UIKit, no Darwin
// (PlayerCore portability invariant; Mach memory probing lives in the CLI only).
import Foundation
import GRDB
import Metadata
import Persistence

/// Imports audio files into the `track` table with bounded memory and resumable,
/// chunked, single-transaction persistence. See the file header for the contract.
public struct LibraryScanner: LibraryScanning {
    /// Audio file extensions the directory walk imports (lowercased, no dot).
    /// Matches the Decoding module's supported families.
    public static let audioExtensions: Set<String> = [
        "flac", "mp3", "m4a", "m4b", "aac", "mp4", "ogg", "oga", "opus",
        "wv", "ape", "mpc", "wav", "aif", "aiff", "aifc", "dsf", "dff", "dsdiff",
        "mod", "xm", "it", "s3m",
    ]

    /// SQLite binds each `IN (...)` element as a variable; stay well under the
    /// 999-variable floor when fetching existing rows for a chunk's paths.
    static let inClauseLimit = 900

    let database: AppDatabase
    let repository: TrackRepository
    let metadataReader: any MetadataReading
    let chunkSize: Int
    let maxConcurrency: Int
    /// Evaluated at the START of each scan to yield the directories the walk must
    /// never descend into (by standardized absolute-path prefix) — so app-generated
    /// files (the instrumental cache's `.m4a` output) are never imported as tracks.
    /// A provider (not a stored array) so the excluded set can change at runtime —
    /// e.g. when the user relocates the karaoke cache directory — and the NEXT scan
    /// honors the new set. Empty result ⇒ nothing excluded.
    let excludedDirectoriesProvider: @Sendable () -> [URL]

    /// - Parameters:
    ///   - database: the migrated library database.
    ///   - metadataReader: tag reader (production `SFBMetadataReader` or a fake).
    ///   - chunkSize: candidates per read+write transaction pair (default 5000).
    ///   - maxConcurrency: concurrent metadata reads, capped to the core count.
    ///   - excludedDirectories: a provider, evaluated at the start of every scan, of
    ///     directories the recursive walk must skip entirely (by absolute-path
    ///     prefix). Dynamic so a runtime change (e.g. moving the karaoke cache) is
    ///     honored by the next scan without rebuilding the scanner.
    public init(
        database: AppDatabase,
        metadataReader: any MetadataReading,
        chunkSize: Int = 5000,
        maxConcurrency: Int = min(ProcessInfo.processInfo.activeProcessorCount, 8),
        excludedDirectories: @escaping @Sendable () -> [URL]
    ) {
        self.database = database
        repository = TrackRepository(database)
        self.metadataReader = metadataReader
        self.chunkSize = max(1, chunkSize)
        self.maxConcurrency = max(1, maxConcurrency)
        excludedDirectoriesProvider = excludedDirectories
    }

    /// Convenience initializer taking a STATIC excluded-directory list — the simple
    /// form for tests and call sites whose exclusions never change at runtime. Wraps
    /// the array in a constant provider so the single scan-time evaluation path is
    /// shared with the dynamic form.
    public init(
        database: AppDatabase,
        metadataReader: any MetadataReading,
        chunkSize: Int = 5000,
        maxConcurrency: Int = min(ProcessInfo.processInfo.activeProcessorCount, 8),
        excludedDirectories: [URL] = []
    ) {
        self.init(
            database: database,
            metadataReader: metadataReader,
            chunkSize: chunkSize,
            maxConcurrency: maxConcurrency,
            excludedDirectories: { excludedDirectories }
        )
    }

    // MARK: Public API

    public func scan(_ request: ScanRequest) async -> ScanSummary {
        var summary = ScanSummary()
        for await event in events(for: request) {
            if case let .finished(final) = event {
                summary = final
            }
        }
        return summary
    }

    public func events(for request: ScanRequest) -> AsyncStream<ScanEvent> {
        AsyncStream { continuation in
            let task = Task {
                await run(request, into: continuation)
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    // MARK: Scan body

    /// Resolves candidates then processes them chunk by chunk, emitting progress
    /// and a closing summary. Honors cancellation at each chunk boundary.
    private func run(_ request: ScanRequest, into continuation: AsyncStream<ScanEvent>.Continuation) async {
        let resolution = resolveCandidates(for: request)
        // Before any segment work: a whole-file row imported before this sheet
        // appeared must be hidden even on a re-scan that skips every segment.
        suppressWholeFileRows(coveredPaths: resolution.coveredPaths)
        let candidates = resolution.candidates
        let total = candidates.count
        var summary = ScanSummary(failed: resolution.failed)
        var processed = 0
        var index = 0

        while index < candidates.count {
            if Task.isCancelled {
                break
            }
            let end = min(index + chunkSize, candidates.count)
            let chunk = candidates[index ..< end]
            guard let outcome = await processChunk(chunk) else {
                break // cancelled mid-chunk: nothing for this chunk was persisted
            }
            summary.add(outcome)
            processed += chunk.count
            continuation.yield(.progress(ScanProgress(
                processed: processed,
                total: total,
                currentPath: chunk.last?.fingerprint.filePath
            )))
            index = end
        }

        continuation.yield(.finished(summary))
        continuation.finish()
    }

    // MARK: Candidate resolution

    /// Turns a request into a de-duplicated candidate list (first row wins), the
    /// audio paths its `.cue` sheets claim, and the sheet failures it hit.
    func resolveCandidates(for request: ScanRequest) -> CandidateResolution {
        switch request {
        case let .manifest(candidates):
            return CandidateResolution(candidates: deduplicate(candidates))
        case let .files(urls):
            return resolve(urls: urls)
        case let .directory(root):
            let excludedPathPrefixes = excludedDirectoriesProvider().map(\.standardizedFileURL.path)
            return resolve(urls: walk(root, excludedPathPrefixes: excludedPathPrefixes))
        }
    }

    /// Expands the `.cue` sheets among `urls`, then takes the whole-file candidates
    /// for every audio file NO sheet claims — which is what makes a fresh scan of a
    /// cue-covered album produce only its segment rows.
    private func resolve(urls: [URL]) -> CandidateResolution {
        let expansion = expandCueSidecars(in: urls)
        let covered = Set(expansion.coveredPaths)
        let wholeFile = urls
            .compactMap(makeFileCandidate)
            .filter { !covered.contains($0.fingerprint.filePath) }
        return CandidateResolution(
            candidates: deduplicate(wholeFile + expansion.candidates),
            coveredPaths: expansion.coveredPaths,
            failed: expansion.failed
        )
    }

    /// Fingerprints one file URL, rejecting non-audio extensions and unstattable
    /// paths (returns `nil` so they are simply not imported).
    private func makeFileCandidate(_ url: URL) -> ScanCandidate? {
        guard Self.audioExtensions.contains(url.pathExtension.lowercased()) else {
            return nil
        }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        let mtime = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        return ScanCandidate(url: url, mtime: mtime, fileSize: fileSize)
    }

    /// Recursively enumerates regular files under `root` (hidden files and
    /// package descendants skipped).
    private func walk(_ root: URL, excludedPathPrefixes: [String]) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }
        var urls: [URL] = []
        for case let url as URL in enumerator {
            if isExcluded(url, excludedPathPrefixes: excludedPathPrefixes) {
                enumerator.skipDescendants()
                continue
            }
            let isRegularFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
            if isRegularFile {
                urls.append(url)
            }
        }
        return urls
    }

    private func isExcluded(_ url: URL, excludedPathPrefixes: [String]) -> Bool {
        guard !excludedPathPrefixes.isEmpty else { return false }
        let path = url.standardizedFileURL.path
        return excludedPathPrefixes.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// Keeps the first candidate per `(filePath, cueStartFrame)`, preserving order.
    /// Keying on the path alone would collapse a sheet's N segments into one row.
    private func deduplicate(_ candidates: [ScanCandidate]) -> [ScanCandidate] {
        var seen = Set<TrackRecord.Identity>()
        var result: [ScanCandidate] = []
        result.reserveCapacity(candidates.count)
        for candidate in candidates where seen.insert(candidate.trackIdentity).inserted {
            result.append(candidate)
        }
        return result
    }
}

// MARK: - Candidate resolution result

/// What one pass over a scan request produced: the rows to import, the audio paths
/// a `.cue` sheet claims (whose pre-existing whole-file rows are suppressed), and
/// the sheets that named something that is not there.
struct CandidateResolution {
    var candidates: [ScanCandidate] = []
    var coveredPaths: [String] = []
    var failed: Int = 0
}
