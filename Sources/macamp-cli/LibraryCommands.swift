// macamp-cli library subcommands (Task 12): seed + full-text search over the
// GRDB-backed Persistence library, used for the 100k-track latency check.
//
//   seed   --tracks <N> --db <path> [--batch <N>]   batched synthetic insert
//   search --db <path> "<query>" [--measure] [--limit <N>]
//
// These exercise the real AppDatabase migrator (v1 + the v2 FTS5 index) and the
// TrackRepository, so the CLI measures the same code path the app ships.
import Foundation
import GRDB
import Persistence

/// Opens (creating if absent) an on-disk WAL library at `path`, migrated to head.
private func openLibrary(at path: String) throws -> AppDatabase {
    var config = Configuration()
    config.journalMode = .wal
    let queue = try DatabaseQueue(path: path, configuration: config)
    return try AppDatabase(queue)
}

/// Positional arguments, skipping boolean flags and the values of valued flags.
private func positionalArguments(_ args: [String], valuedFlags: Set<String>) -> [String] {
    var positionals: [String] = []
    var index = 0
    while index < args.count {
        let arg = args[index]
        if valuedFlags.contains(arg) {
            index += 2
        } else if arg.hasPrefix("--") {
            index += 1
        } else {
            positionals.append(arg)
            index += 1
        }
    }
    return positionals
}

private let syntheticTitleWords = [
    "Bohemian", "Rhapsody", "Stairway", "Heaven", "Hotel", "California",
    "Smells", "Teen", "Spirit", "Imagine", "Yesterday", "Wonderwall",
    "Creep", "Comfortably", "Numb", "Thunderstruck", "Money", "Time",
    "Queen", "Paranoid", "Africa", "Dreams", "Clocks", "Believer",
]

private func syntheticTitle(index: Int) -> String {
    let first = syntheticTitleWords[index % syntheticTitleWords.count]
    let second = syntheticTitleWords[(index / syntheticTitleWords.count) % syntheticTitleWords.count]
    return "\(first) \(second) \(index)"
}

private func syntheticTrack(index: Int) -> TrackRecord {
    let title = syntheticTitle(index: index)
    return TrackRecord(
        filePath: "/synthetic/\(index).flac",
        title: title,
        sortTitle: title,
        artistName: "Artist \(index % 5000)",
        albumTitle: "Album \(index % 20000)",
        dateAdded: Double(index)
    )
}

private func milliseconds(since start: DispatchTime) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000
}

func runSeed(_ args: [String]) {
    guard let count = intFlag("--tracks", in: args), count > 0 else {
        fail("seed requires --tracks <N> (N > 0)", code: 2)
    }
    guard let dbPath = flagValue("--db", in: args) else {
        fail("seed requires --db <path>", code: 2)
    }
    let batchSize = max(1, intFlag("--batch", in: args) ?? 5000)
    do {
        let appDB = try openLibrary(at: dbPath)
        let repo = TrackRepository(appDB)
        let started = DispatchTime.now()
        var inserted = 0
        while inserted < count {
            let upper = min(inserted + batchSize, count)
            let batch = (inserted ..< upper).map { syntheticTrack(index: $0) }
            inserted += try repo.insertBatch(batch)
        }
        let elapsed = milliseconds(since: started) / 1000
        let rate = elapsed > 0 ? Double(inserted) / elapsed : 0
        print("seeded \(inserted) tracks into \(dbPath)")
        print(String(format: "elapsed:     %.3f s (%.0f tracks/s)", elapsed, rate))
    } catch {
        fail("\(error)")
    }
}

func runSearch(_ args: [String]) {
    guard let dbPath = flagValue("--db", in: args) else {
        fail("search requires --db <path>", code: 2)
    }
    let positionals = positionalArguments(args, valuedFlags: ["--db", "--limit"])
    guard let query = positionals.first else {
        fail("search requires a <query> argument", code: 2)
    }
    let limit = max(1, intFlag("--limit", in: args) ?? 50)
    let measure = args.contains("--measure")
    do {
        let appDB = try openLibrary(at: dbPath)
        let repo = TrackRepository(appDB)
        var results = try repo.searchTracks(query: query, limit: limit)

        if measure {
            var timings: [Double] = []
            for _ in 0 ..< 7 {
                let started = DispatchTime.now()
                results = try repo.searchTracks(query: query, limit: limit)
                timings.append(milliseconds(since: started))
            }
            timings.sort()
            let median = timings[timings.count / 2]
            let best = timings.first ?? 0
            let total = try appDB.writer.read { try TrackRecord.fetchCount($0) }
            print("query:       \"\(query)\"  (corpus \(total) tracks)")
            print("matches:     \(results.count) (limit \(limit))")
            print(String(format: "elapsed:     median %.3f ms, best %.3f ms over %d runs", median, best, timings.count))
        } else {
            print("query:       \"\(query)\"")
            print("matches:     \(results.count) (limit \(limit))")
            for track in results.prefix(10) {
                print("  - \(track.title ?? "(untitled)") — \(track.artistName ?? "(unknown)")")
            }
        }
    } catch {
        fail("\(error)")
    }
}
