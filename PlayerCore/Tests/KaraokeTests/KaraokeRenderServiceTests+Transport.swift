import Foundation
import PlayerCoreTestSupport
import Separation
@testable import Services
import Testing

/// Pause/resume and retry transport coverage — split from
/// `KaraokeRenderServiceTests` to stay under the file-length budget.
extension KaraokeRenderServiceTests {
    @Test("pause cancels the in-flight item and requeues it at the front")
    func pauseCancelsAndRequeuesInFlightAtFront() async throws {
        let files = try Self.makeTempFiles(count: 3)
        let separator = FakeStemSeparator(latency: .milliseconds(200))
        let collector = Collector()
        let service = KaraokeRenderService(
            separator: separator,
            cache: FakeInstrumentalCache(),
            modelSHA: Self.modelSHA
        )
        service.onFinished = { collector.record(finished: $0, result: $1) }
        service.onQueueChanged = { collector.record(snapshot: $0) }

        service.setEnabled(true)
        files.forEach(service.requestRender)
        await Self.waitUntil { separator.separateCallCount == 1 }
        service.pause()
        let paused = KaraokeQueueSnapshot(currentURL: nil, pendingURLs: files, isPaused: true)
        await Self.waitUntil { collector.snapshots.contains(paused) }

        #expect(separator.requestedURLs == [files[0]])
        #expect(separator.maxObservedConcurrency == 1)
        #expect(collector.finished.isEmpty)
    }

    @Test("resume revives an idle, unpaused queue stopped by disk-full")
    func resumeRevivesIdleNotPausedQueue() async throws {
        let files = try Self.makeTempFiles(count: 2)
        let separator = FakeStemSeparator(latency: .milliseconds(15))
        separator.setError(.diskFull, for: files[0])
        let collector = Collector()
        let service = KaraokeRenderService(
            separator: separator,
            cache: FakeInstrumentalCache(),
            modelSHA: Self.modelSHA
        )
        service.onNotice = { collector.record(notice: $0) }
        service.onQueueChanged = { collector.record(snapshot: $0) }

        service.setEnabled(true)
        service.requestRender(files[0])
        service.requestRender(files[1])
        await Self.waitUntil { collector.notices == [.diskFull] }

        let stoppedSnapshot = collector.snapshots.last
        #expect(stoppedSnapshot?.currentURL == nil)
        #expect(stoppedSnapshot?.isPaused == false)
        #expect(stoppedSnapshot?.pendingURLs.isEmpty == false)

        separator.setError(nil, for: files[0])
        service.resume()
        await Self.waitUntil { separator.separateCallCount == 2 }

        #expect(separator.separateCallCount == 2)
    }

    @Test("resume continues a queue from the paused state")
    func resumeContinuesPausedQueue() async throws {
        let files = try Self.makeTempFiles(count: 2)
        let separator = FakeStemSeparator(latency: .milliseconds(15))
        let collector = Collector()
        let service = KaraokeRenderService(
            separator: separator,
            cache: FakeInstrumentalCache(),
            modelSHA: Self.modelSHA
        )
        service.onFinished = { collector.record(finished: $0, result: $1) }

        service.setEnabled(true)
        service.pause()
        files.forEach(service.requestRender)
        try await Task.sleep(for: .milliseconds(50))
        #expect(separator.separateCallCount == 0)

        service.resume()
        await Self.waitUntil { collector.finished.count == 2 }

        #expect(separator.requestedURLs == files)
        #expect(separator.maxObservedConcurrency == 1)
    }

    @Test("repeated disk-full retries preserve the queue and debounce notices")
    func repeatedDiskFullRetriesPreserveQueueAndDebounceNotices() async throws {
        let files = try Self.makeTempFiles(count: 2)
        let separator = FakeStemSeparator(failingWith: .diskFull, latency: .milliseconds(15))
        let collector = Collector()
        let service = KaraokeRenderService(
            separator: separator,
            cache: FakeInstrumentalCache(),
            modelSHA: Self.modelSHA
        )
        service.onFinished = { collector.record(finished: $0, result: $1) }
        service.onNotice = { collector.record(notice: $0) }
        service.onQueueChanged = { collector.record(snapshot: $0) }

        service.setEnabled(true)
        files.forEach(service.requestRender)
        await Self.waitUntil { collector.notices == [.diskFull] }
        for callCount in 2 ... 3 {
            service.resume()
            await Self.waitUntil {
                separator.separateCallCount == callCount
                    && collector.snapshots.last == KaraokeQueueSnapshot(
                        currentURL: nil,
                        pendingURLs: files,
                        isPaused: false
                    )
            }
        }

        #expect(separator.requestedURLs == [files[0], files[0], files[0]])
        #expect(collector.snapshots.last?.pendingURLs.count == files.count)
        #expect(collector.notices == [.diskFull])
        #expect(collector.finished.isEmpty)
    }

    @Test("stopCurrent and pause have identical observable outcomes")
    func stopCurrentAndPauseHaveIdenticalOutcomes() async throws {
        let files = try Self.makeTempFiles(count: 2)
        let pauseSeparator = FakeStemSeparator(latency: .milliseconds(200))
        let stopSeparator = FakeStemSeparator(latency: .milliseconds(200))
        let pauseCollector = Collector()
        let stopCollector = Collector()
        let pauseService = KaraokeRenderService(
            separator: pauseSeparator,
            cache: FakeInstrumentalCache(),
            modelSHA: Self.modelSHA
        )
        let stopService = KaraokeRenderService(
            separator: stopSeparator,
            cache: FakeInstrumentalCache(),
            modelSHA: Self.modelSHA
        )
        pauseService.onQueueChanged = { pauseCollector.record(snapshot: $0) }
        stopService.onQueueChanged = { stopCollector.record(snapshot: $0) }

        pauseService.setEnabled(true)
        stopService.setEnabled(true)
        files.forEach(pauseService.requestRender)
        files.forEach(stopService.requestRender)
        await Self.waitUntil {
            pauseSeparator.separateCallCount == 1 && stopSeparator.separateCallCount == 1
        }
        pauseService.pause()
        stopService.stopCurrent()
        let expected = KaraokeQueueSnapshot(currentURL: nil, pendingURLs: files, isPaused: true)
        await Self.waitUntil {
            pauseCollector.snapshots.last == expected && stopCollector.snapshots.last == expected
        }

        #expect(pauseCollector.snapshots.last == stopCollector.snapshots.last)
        #expect(pauseSeparator.requestedURLs == stopSeparator.requestedURLs)
    }
}
