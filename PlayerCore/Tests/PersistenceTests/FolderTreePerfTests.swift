// EVIDENCE-ONLY wall-clock timings for the folder-tree queries.
//
// These build six-figure fixtures and time real reads, so they are gated behind
// `MACAMP_PERF_GATE=1` (the `.enabled(if:)` precedent is `SFBReloadTests.swift`)
// and are EXCLUDED from the default `swift test --filter PersistenceTests` sweep.
// Run them deliberately, serially, and record the numbers:
//
//   MACAMP_PERF_GATE=1 DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
//     swift test --filter FolderTreePerfTests
//
// The measured milliseconds are PRINTED, never asserted: a timing assert running
// beside other suites is a flake generator, not a gate. The deterministic gate
// for these queries is the `EXPLAIN QUERY PLAN` sargability assertion in
// `FolderTreeQueryPlanTests`, which runs in the normal suite. Budgets for the
// recorded numbers: `tracksDirectlyIn` / non-root `childFolders` < 100 ms at 10k
// rows, ROOT `childFolders` < 300 ms at 100k rows.
import Foundation
import GRDB
import Persistence
import Testing

@Suite(
    "FolderTreePerfTests",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["MACAMP_PERF_GATE"] == "1")
)
struct FolderTreePerfTests {
    /// Runs `work` once to warm caches, then times a second run.
    private func measure(_ label: String, _ work: () throws -> Int) throws -> Double {
        _ = try work()
        let start = CFAbsoluteTimeGetCurrent()
        let count = try work()
        let milliseconds = (CFAbsoluteTimeGetCurrent() - start) * 1000
        print(String(format: "PERF %@: %.2f ms (%d rows)", label, milliseconds, count))
        return milliseconds
    }

    @Test("10k rows: tracksDirectlyIn and non-root childFolders")
    func tenThousandRowFolderReads() throws {
        let harness = try FolderTreeHarness()
        // 50 discs x 5 parts x 40 tracks = 10,000 rows beneath /Perf/Root.
        try harness.seedWideTree(root: "/Perf/Root", discs: 50, partsPerDisc: 5, tracksPerPart: 40)

        let directMs = try measure("tracksDirectlyIn(/Perf/Root/Disc0/Part0) @10k") {
            try harness.tracks.tracksDirectlyIn(dirPath: "/Perf/Root/Disc0/Part0", limit: 100).items.count
        }
        let childMs = try measure("childFolders(/Perf/Root/Disc0) @10k [non-root]") {
            try harness.tracks.childFolders(parentPath: "/Perf/Root/Disc0").count
        }
        let rootMs = try measure("childFolders(/Perf/Root) @10k [root]") {
            try harness.tracks.childFolders(parentPath: "/Perf/Root").count
        }

        print(String(
            format: "PERF SUMMARY @10k — direct %.2f ms, non-root children %.2f ms, root children %.2f ms",
            directMs, childMs, rootMs
        ))
        // Correctness only — timings above are evidence, never a gate.
        let direct = try harness.tracks.tracksDirectlyIn(dirPath: "/Perf/Root/Disc0/Part0", limit: 100)
        let children = try harness.tracks.childFolders(parentPath: "/Perf/Root/Disc0")
        #expect(direct.items.count == 40)
        #expect(children.count == 5)
    }

    @Test("100k rows: root-level childFolders aggregates the whole subtree")
    func hundredThousandRowRootChildFolders() throws {
        let harness = try FolderTreeHarness()
        // 100 discs x 10 parts x 100 tracks = 100,000 rows beneath /Perf/Big.
        try harness.seedWideTree(root: "/Perf/Big", discs: 100, partsPerDisc: 10, tracksPerPart: 100)

        let rootMs = try measure("childFolders(/Perf/Big) @100k [root]") {
            try harness.tracks.childFolders(parentPath: "/Perf/Big").count
        }
        let directMs = try measure("tracksDirectlyIn(/Perf/Big/Disc0/Part0) @100k") {
            try harness.tracks.tracksDirectlyIn(dirPath: "/Perf/Big/Disc0/Part0", limit: 100).items.count
        }

        print(String(
            format: "PERF SUMMARY @100k — root children %.2f ms, direct %.2f ms",
            rootMs, directMs
        ))
        let children = try harness.tracks.childFolders(parentPath: "/Perf/Big")
        #expect(children.count == 100)
        #expect(children.allSatisfy { $0.trackCount == 1000 && $0.hasChildren })
    }
}
