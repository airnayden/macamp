// One paste, end to end: `DownloadQueueService` → the composition root's seam wiring →
// `DownloadQueueStore`, with the paste-time oEmbed lookup answered by a fake.
//
// The service-level rules are pinned in `DownloadsTests`; what this file adds is the
// half only the store can answer — that a decoration reaches the rendered row WITHOUT
// bumping ``DownloadQueueStore/version``. The counter is what a list's own layout pass
// keys off, so an enrichment that bumped it would relayout the whole queue once per
// arriving title: fifty pastes, fifty full passes, for fifty in-place text changes.
//
// The seam wiring here mirrors `connectDownloadsUI(_:oEmbed:)` deliberately, including
// the capture-time sequence stamp, so the sequencing the store depends on is exercised
// rather than assumed.
import Foundation
import PlayerCoreTestSupport
import Services
import Testing
import ViewModels

@Suite("Paste-time decoration reaches the store without a relayout")
@MainActor
struct DownloadPasteDecorationStoreTests {
    private static let videoID = "dQw4w9WgXcQ"

    private static func watchURL() throws -> URL {
        try testURL("https://www.youtube.com/watch?v=\(videoID)")
    }

    private static func thumbnail() throws -> URL {
        try testURL("https://i.ytimg.com/vi/\(videoID)/hq.jpg")
    }

    @Test func aPastedTitleArrivesInTheStoreWithoutBumpingVersion() async throws {
        let expectedThumbnail = try Self.thumbnail()
        let oEmbed = FakeOEmbedFetcher(payloads: [Self.videoID: OEmbedPayload(
            title: "Paste Title",
            authorName: "Paste Channel",
            thumbnailURL: expectedThumbnail
        )])
        let store = DownloadQueueStore()
        let service = Self.makeService(oEmbed: oEmbed)
        Self.connect(service, to: store)

        service.pause()
        _ = try await service.enqueue(urls: [Self.watchURL()])
        let versionAfterPaste = store.version
        #expect(store.pendingItems.first?.title == nil)

        await Self.waitUntil { store.pendingItems.first?.title != nil }

        let row = try #require(store.pendingItems.first)
        #expect(row.title == "Paste Title")
        #expect(row.uploader == "Paste Channel")
        #expect(row.thumbnailURL == expectedThumbnail)
        #expect(store.version == versionAfterPaste)
        #expect(store.activeRows.isEmpty)
        #expect(oEmbed.fetchCallCount == 1)
    }

    /// Mirrors `connectDownloadsUI(_:oEmbed:)`: the sequence is stamped synchronously at
    /// CAPTURE time, before any hop, because a hop is what lets two snapshots arrive out
    /// of order and the reorder guard then drop the newer one.
    private static func connect(_ service: DownloadQueueService, to store: DownloadQueueStore) {
        let sequence = SequenceStamp()
        service.onQueueChanged = { snapshot in
            let stamped = sequence.next()
            MainActor.assumeIsolated { store.ingest(sequence: stamped, snapshot: snapshot) }
        }
        service.onItemProgress = { id, state in
            MainActor.assumeIsolated { store.ingestProgress(id: id, state: state) }
        }
    }

    /// A queue that can accept a paste and nothing else: paused before anything is
    /// enqueued, so the tool provider and the process runner are never reached.
    private static func makeService(oEmbed: any OEmbedFetching) -> DownloadQueueService {
        DownloadQueueService(
            toolProvider: FakeDownloadToolProvider(),
            processRunner: FakeToolProcessRunner(),
            stagingDirectory: URL(fileURLWithPath: "/tmp/macamp-staging", isDirectory: true),
            destinationDirectory: { URL(fileURLWithPath: "/tmp/macamp-downloads", isDirectory: true) },
            oEmbedFetcher: oEmbed
        )
    }

    private static func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }
}

private enum DecorationTestURLError: Error {
    case malformed(String)
}

/// Builds a URL from a compile-time constant, throwing rather than force-unwrapping.
private func testURL(_ string: String) throws -> URL {
    guard let url = URL(string: string) else { throw DecorationTestURLError.malformed(string) }
    return url
}

/// A monotonic counter safe to read from a `@Sendable` seam closure.
private final class SequenceStamp: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.withLock {
            value += 1
            return value
        }
    }
}
