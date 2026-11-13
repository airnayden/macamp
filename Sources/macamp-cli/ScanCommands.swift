// macamp-cli `scan` subcommand (Task 13): a headless harness for the library
// import path.
//
//   scan <dir> --db <path> [--json] [--chunk <N>]
//   scan --synthetic <N> --db <path> [--measure] [--memory-ceiling] [--json] [--chunk <N>]
//
// It drives the SAME persistence hot path the PlayerCore `LibraryScanner` uses
// (chunked `TrackRepository.insertBatch` with fingerprint-based skip) and the
// SAME production reader (`SFBMetadataReader`), so its reported memory ceiling is
// representative of a real import. The harness deliberately does not link the
// `Services` module (keeping the executable's dependency set, and Package.swift,
// untouched); the importer logic the scanner owns is mirrored here only for the
// out-of-process measurement. Darwin/Mach is used for the physical-footprint
// probe — allowed in the CLI, forbidden inside PlayerCore.
//
// NOTE: The CLI operates on the shared library database. Any state it seeds
// (e.g., via `seed` command) is scoped to the Guest profile (id 1). Profile-
// specific state (playCount, isFavourite, listenedCount, customPosition) is
// managed separately via profileTrackState and is NOT preserved by the scanner.
import Darwin
import Foundation
import GRDB
import Metadata
import Persistence

// MARK: - tally + JSON report

private struct ScanTally {
    var added = 0
    var updated = 0
    var skipped = 0
    var failed = 0

    var total: Int {
        added + updated + skipped + failed
    }
}

private struct ScanReport: Codable {
    let added: Int
    let updated: Int
    let skipped: Int
    let failed: Int
    let elapsedSeconds: Double?
    let peakFootprintBytes: UInt64?
}

private func jsonReport(_ tally: ScanTally, elapsed: Double?, peak: UInt64?) -> String {
    let report = ScanReport(
        added: tally.added,
        updated: tally.updated,
        skipped: tally.skipped,
        failed: tally.failed,
        elapsedSeconds: elapsed,
        peakFootprintBytes: peak
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(report), let string = String(data: data, encoding: .utf8) else {
        return "{}"
    }
    return string
}

// MARK: - environment probes

/// Current physical-memory footprint in bytes via Mach `TASK_VM_INFO`
/// (`phys_footprint` — the same metric Instruments' "Physical Footprint" shows).
private func physicalFootprintBytes() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
        MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
    )
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
        }
    }
    return result == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
}

private func megabytes(_ bytes: UInt64) -> String {
    String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
}

private func secondsSince(_ start: DispatchTime) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000_000
}

private func openScanLibrary(at path: String) throws -> AppDatabase {
    var config = Configuration()
    config.journalMode = .wal
    return try AppDatabase(DatabaseQueue(path: path, configuration: config))
}

// MARK: - import core (mirrors LibraryScanner persistence)

private let scanAudioExtensions: Set<String> = [
    "flac", "mp3", "m4a", "m4b", "aac", "mp4", "ogg", "oga", "opus",
    "wv", "ape", "mpc", "wav", "aif", "aiff", "aifc", "dsf", "dff", "dsdiff",
    "mod", "xm", "it", "s3m",
]

private func fetchExistingByPath(_ paths: [String], in appDB: AppDatabase) throws -> [String: TrackRecord] {
    guard !paths.isEmpty else {
        return [:]
    }
    return try appDB.writer.read { db in
        var byPath: [String: TrackRecord] = [:]
        var index = 0
        while index < paths.count {
            let end = min(index + 900, paths.count)
            let slice = Array(paths[index ..< end])
            for row in try TrackRecord.filter(slice.contains(TrackRecord.Columns.filePath)).fetchAll(db) {
                byPath[row.filePath] = row
            }
            index = end
        }
        return byPath
    }
}

private func importChunk(_ chunk: [TrackRecord], into appDB: AppDatabase, tally: inout ScanTally) throws {
    let existing = try fetchExistingByPath(chunk.map(\.filePath), in: appDB)
    var inserts: [TrackRecord] = []
    var updates: [TrackRecord] = []
    for record in chunk {
        guard let row = existing[record.filePath] else {
            inserts.append(record)
            continue
        }
        if row.mtime == record.mtime, row.fileSize == record.fileSize {
            tally.skipped += 1
        } else {
            var changed = record
            changed.id = row.id
            changed.dateAdded = row.dateAdded
            updates.append(changed)
        }
    }
    if !inserts.isEmpty {
        _ = try TrackRepository(appDB).insertBatch(inserts)
    }
    if !updates.isEmpty {
        try appDB.writer.write { db in
            for record in updates {
                try record.update(db)
            }
        }
    }
    tally.added += inserts.count
    tally.updated += updates.count
}

private func mapRecord(metadata: TrackMetadata, path: String, mtime: Double, fileSize: Int64) -> TrackRecord {
    TrackRecord(
        filePath: path,
        title: metadata.title,
        sortTitle: metadata.sortTitle,
        artistName: metadata.artist,
        albumTitle: metadata.album,
        trackNumber: metadata.trackNumber,
        discNumber: metadata.discNumber,
        duration: metadata.duration,
        bitrate: metadata.bitrate.map { Int(($0 * 1000).rounded()) },
        sampleRate: metadata.sampleRate.map { Int($0.rounded()) },
        bitDepth: metadata.bitDepth,
        fileSize: fileSize,
        mtime: mtime,
        dateAdded: Date().timeIntervalSince1970,
        replaygainTrackGain: metadata.replayGain?.trackGain,
        replaygainTrackPeak: metadata.replayGain?.trackPeak,
        replaygainAlbumGain: metadata.replayGain?.albumGain,
        replaygainAlbumPeak: metadata.replayGain?.albumPeak,
        genre: GenreNormalizer.normalize(metadata.genre)
    )
}

private func syntheticRecord(index: Int) -> TrackRecord {
    let title = "Synthetic Track \(index)"
    return TrackRecord(
        filePath: "/synthetic/\(index).flac",
        title: title,
        sortTitle: title,
        artistName: "Artist \(index % 5000)",
        albumTitle: "Album \(index % 20000)",
        trackNumber: (index % 24) + 1,
        duration: 180,
        bitrate: 1_000_000,
        sampleRate: 44100,
        fileSize: Int64(1_000_000 + index),
        mtime: Double(index),
        dateAdded: Date().timeIntervalSince1970
    )
}

// MARK: - synthetic import (per-chunk generation keeps memory bounded)

private func importSynthetic(
    count: Int,
    into appDB: AppDatabase,
    chunkSize: Int,
    measureMemory: Bool
) throws -> (tally: ScanTally, peakBytes: UInt64) {
    var tally = ScanTally()
    var peak: UInt64 = 0
    var index = 0
    while index < count {
        let end = min(index + chunkSize, count)
        let chunk = (index ..< end).map(syntheticRecord(index:))
        try importChunk(chunk, into: appDB, tally: &tally)
        if measureMemory {
            peak = max(peak, physicalFootprintBytes())
        }
        index = end
    }
    return (tally, peak)
}

// MARK: - directory import (production SFBMetadataReader)

private func audioFiles(under root: URL) -> [URL] {
    guard let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles, .skipsPackageDescendants]
    ) else {
        return []
    }
    var urls: [URL] = []
    for case let url as URL in enumerator where scanAudioExtensions.contains(url.pathExtension.lowercased()) {
        urls.append(url)
    }
    return urls
}

private func buildRecords(from urls: [URL], reader: SFBMetadataReader, failed: inout Int) -> [TrackRecord] {
    var records: [TrackRecord] = []
    for url in urls {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let metadata = try? reader.readMetadata(from: url)
        else {
            failed += 1
            continue
        }
        let mtime = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        records.append(mapRecord(metadata: metadata, path: url.path, mtime: mtime, fileSize: fileSize))
    }
    return records
}

private func importDirectory(_ dir: String, into appDB: AppDatabase, chunkSize: Int) throws -> ScanTally {
    let reader = SFBMetadataReader()
    let urls = audioFiles(under: URL(fileURLWithPath: dir))
    var tally = ScanTally()
    var index = 0
    while index < urls.count {
        let end = min(index + chunkSize, urls.count)
        let records = buildRecords(from: Array(urls[index ..< end]), reader: reader, failed: &tally.failed)
        try importChunk(records, into: appDB, tally: &tally)
        index = end
    }
    return tally
}

// MARK: - output

private func emit(_ tally: ScanTally, elapsed: Double?, peak: UInt64?, json: Bool) {
    if json {
        print(jsonReport(tally, elapsed: elapsed, peak: peak))
        return
    }
    print("added:       \(tally.added)")
    print("updated:     \(tally.updated)")
    print("skipped:     \(tally.skipped)")
    print("failed:      \(tally.failed)")
    if let elapsed {
        let rate = elapsed > 0 ? Double(tally.total) / elapsed : 0
        print(String(format: "elapsed:     %.3f s (%.0f tracks/s)", elapsed, rate))
    }
    if let peak {
        print("peak:        \(megabytes(peak)) (\(peak) bytes)")
    }
}

// MARK: - entry points

private func firstPositional(_ args: [String], valuedFlags: Set<String>) -> String? {
    var index = 0
    while index < args.count {
        let arg = args[index]
        if valuedFlags.contains(arg) {
            index += 2
        } else if arg.hasPrefix("--") {
            index += 1
        } else {
            return arg
        }
    }
    return nil
}

func runScan(_ args: [String]) {
    guard let dbPath = flagValue("--db", in: args) else {
        fail("scan requires --db <path>", code: 2)
    }
    let chunkSize = max(1, intFlag("--chunk", in: args) ?? 5000)
    let json = args.contains("--json")
    do {
        let appDB = try openScanLibrary(at: dbPath)
        if let count = intFlag("--synthetic", in: args) {
            guard count > 0 else { fail("scan --synthetic requires N > 0", code: 2) }
            let measureMemory = args.contains("--memory-ceiling")
            let measure = measureMemory || args.contains("--measure")
            let started = DispatchTime.now()
            let result = try importSynthetic(
                count: count,
                into: appDB,
                chunkSize: chunkSize,
                measureMemory: measureMemory
            )
            emit(
                result.tally,
                elapsed: measure ? secondsSince(started) : nil,
                peak: measureMemory ? result.peakBytes : nil,
                json: json
            )
        } else {
            guard let dir = firstPositional(args, valuedFlags: ["--db", "--chunk"]) else {
                fail("scan requires a <dir> argument or --synthetic <N>", code: 2)
            }
            let started = DispatchTime.now()
            let tally = try importDirectory(dir, into: appDB, chunkSize: chunkSize)
            emit(tally, elapsed: secondsSince(started), peak: nil, json: json)
        }
    } catch {
        fail("\(error)")
    }
}
