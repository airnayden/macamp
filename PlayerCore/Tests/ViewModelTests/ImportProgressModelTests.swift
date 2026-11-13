import Foundation
import Services
import Testing
@testable import ViewModels

/// Todo 10 acceptance: a scripted ``LibraryScanning`` event stream drives the
/// observable import state (idle → importing → idle), the mid-import projection
/// refresh fires once per chunk when unthrottled and collapses to one call inside
/// the default window, and a pass that resolved no candidates never shows at all.
@MainActor
struct ImportProgressModelTests {
    // MARK: Scripted event stream

    @Test func scriptedScanDrivesIdleThenImportingThenIdle() async {
        let model = ImportProgressModel(refreshInterval: 0)
        let scanner = FakeLibraryScanner(summary: ScanSummary(added: 3), progressCount: 3)
        #expect(!model.isImporting)

        var processedWhileImporting: [Int] = []
        for await event in scanner.events(for: .files(Self.files(3))) {
            await model.apply(event)
            if model.isImporting {
                processedWhileImporting.append(model.processed)
            }
        }

        #expect(processedWhileImporting == [1, 2, 3])
        #expect(!model.isImporting)
        #expect(model.processed == 0)
        #expect(model.total == 0)
        #expect(model.currentPath == nil)
        #expect(model.fraction == 0)
    }

    @Test func publishesTotalCurrentPathAndFraction() async {
        let model = ImportProgressModel(refreshInterval: 0)

        await model.apply(.progress(ScanProgress(processed: 5, total: 20, currentPath: "/Music/a.flac")))

        #expect(model.isImporting)
        #expect(model.processed == 5)
        #expect(model.total == 20)
        #expect(model.currentPath == "/Music/a.flac")
        #expect(model.fraction == 0.25)
    }

    // MARK: Zero-work guard

    @Test func zeroWorkScanNeverReportsImporting() async {
        let recorder = CallRecorder()
        let model = ImportProgressModel(refreshInterval: 0)
        model.onIncrementalRefresh = { recorder.record() }
        // A `.directory` request resolves no canned candidates, so the fake emits
        // `.finished` alone — exactly the shape of a rescan with nothing to do.
        let scanner = FakeLibraryScanner()

        var everImporting = false
        for await event in scanner.events(for: .directory(URL(fileURLWithPath: "/tmp/macamp-empty"))) {
            await model.apply(event)
            everImporting = everImporting || model.isImporting
        }

        #expect(!everImporting)
        #expect(!model.isImporting)
        #expect(recorder.count == 0)
    }

    @Test func progressWithoutCandidatesIsIgnored() async {
        let model = ImportProgressModel(refreshInterval: 0)

        await model.apply(.progress(ScanProgress(processed: 0, total: 0)))

        #expect(!model.isImporting)
        #expect(model.total == 0)
    }

    // MARK: Incremental refresh + throttle

    @Test func unthrottledRefreshFiresOncePerChunk() async {
        let recorder = CallRecorder()
        let model = ImportProgressModel(refreshInterval: 0)
        model.onIncrementalRefresh = { recorder.record() }
        let scanner = FakeLibraryScanner(progressCount: 4)

        for await event in scanner.events(for: .files(Self.files(4))) {
            await model.apply(event)
        }

        #expect(recorder.count == 4)
    }

    @Test func defaultWindowCollapsesRapidChunksIntoOneRefresh() async {
        let clock = TestClock()
        let recorder = CallRecorder()
        let model = ImportProgressModel(refreshInterval: 1, now: { clock.now })
        model.onIncrementalRefresh = { recorder.record() }
        let scanner = FakeLibraryScanner(progressCount: 5)

        for await event in scanner.events(for: .files(Self.files(5))) {
            await model.apply(event)
        }

        #expect(recorder.count == 1)
    }

    @Test func refreshResumesOnceTheWindowElapses() async {
        let clock = TestClock()
        let recorder = CallRecorder()
        let model = ImportProgressModel(refreshInterval: 1, now: { clock.now })
        model.onIncrementalRefresh = { recorder.record() }

        await model.apply(.progress(ScanProgress(processed: 1, total: 9)))
        #expect(recorder.count == 1)

        clock.now = 0.9
        await model.apply(.progress(ScanProgress(processed: 2, total: 9)))
        #expect(recorder.count == 1)

        clock.now = 1
        await model.apply(.progress(ScanProgress(processed: 3, total: 9)))
        #expect(recorder.count == 2)
    }

    @Test func finishedRearmsTheWindowForTheNextImport() async {
        let clock = TestClock()
        let recorder = CallRecorder()
        let model = ImportProgressModel(refreshInterval: 1, now: { clock.now })
        model.onIncrementalRefresh = { recorder.record() }

        await model.apply(.progress(ScanProgress(processed: 1, total: 2)))
        await model.apply(.finished(ScanSummary(added: 2)))
        await model.apply(.progress(ScanProgress(processed: 1, total: 2)))

        #expect(recorder.count == 2)
    }
}

private extension ImportProgressModelTests {
    static func files(_ count: Int) -> [URL] {
        (0 ..< count).map { URL(fileURLWithPath: "/tmp/macamp-import/\($0).flac") }
    }
}

@MainActor
private final class CallRecorder {
    private(set) var count = 0

    func record() {
        count += 1
    }
}

@MainActor
private final class TestClock {
    var now: TimeInterval = 0
}
