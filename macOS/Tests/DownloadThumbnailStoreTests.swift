// Todo 11 acceptance: a cached poster frame costs NO second request.
//
// The claim is about call COUNT, not about pixels. A store that re-fetched on every
// ask would hand back a byte-identical image from the same stub and satisfy any
// assertion that only compared what came out — so the only thing that separates a
// cache from a pass-through is how many times the transport was reached. That is what
// this suite counts.
//
// It lives in `macampMacTests` rather than under `swift test`, and there is no choice
// about it: ``DownloadThumbnailStore`` decodes `NSImage`, so it belongs to the shell —
// `PlayerCore` is CI-guarded against importing AppKit. The stub below is local for the
// same structural reason the file header of `DownloadToastPolicyTests` records:
// linking `PlayerCoreTestSupport` (where `FakeOEmbedFetcher` lives) into this target
// would narrow that product's Tuist platform support to macOS and break twelve
// PlayerCore test targets that declare iOS.
import AppKit
import Foundation
@testable import MacAMP
import Services
import Testing

@Suite("Download thumbnail store")
@MainActor
struct DownloadThumbnailStoreTests {
    @Test func aCacheHitNeverReachesTheTransport() async throws {
        let url = try thumbnailTestURL("https://i.ytimg.com/vi/dQw4w9WgXcQ/hq.jpg")
        let bytes = try thumbnailPNGData()
        let stub = StubThumbnailFetcher(thumbnails: [url: bytes])
        let store = DownloadThumbnailStore(fetcher: stub)

        let first = await store.image(for: url)
        let second = await store.image(for: url)

        #expect(first != nil)
        #expect(second != nil)
        #expect(stub.thumbnailCallCount == 1)
        #expect(store.cachedImage(for: url) != nil)
    }

    /// The peek is what lets a row paint without a placeholder flash, so it must answer
    /// only for a URL already in the cache — and must never fetch to find out.
    @Test func theCachePeekAnswersNothingBeforeAFetchAndNeverTransports() async throws {
        let url = try thumbnailTestURL("https://i.ytimg.com/vi/9bZkp7q19f0/hq.jpg")
        let stub = try StubThumbnailFetcher(thumbnails: [url: thumbnailPNGData()])
        let store = DownloadThumbnailStore(fetcher: stub)

        #expect(store.cachedImage(for: url) == nil)
        #expect(stub.thumbnailCallCount == 0)

        _ = await store.image(for: url)

        #expect(store.cachedImage(for: url) != nil)
        #expect(stub.thumbnailCallCount == 1)
    }

    /// Several rows can legitimately name the same poster frame, and they ask at the
    /// same moment — the list materializes them together. One request, not N.
    @Test func concurrentAsksForOneURLShareASingleRequest() async throws {
        let url = try thumbnailTestURL("https://i.ytimg.com/vi/kJQP7kiw5Fk/hq.jpg")
        let stub = try StubThumbnailFetcher(
            thumbnails: [url: thumbnailPNGData()],
            latency: .milliseconds(40)
        )
        let store = DownloadThumbnailStore(fetcher: stub)

        async let first = resolved(store, url)
        async let second = resolved(store, url)
        async let third = resolved(store, url)
        let answered = await [first, second, third]

        #expect(answered == [true, true, true])
        #expect(stub.thumbnailCallCount == 1)
    }

    /// A URL the transport has no bytes for produces no image and, crucially, no crash
    /// and no cache entry — the row simply keeps its placeholder.
    @Test func anUnansweredURLLeavesNothingCached() async throws {
        let url = try thumbnailTestURL("https://i.ytimg.com/vi/dQw4w9WgXcQ/missing.jpg")
        let stub = StubThumbnailFetcher(thumbnails: [:])
        let store = DownloadThumbnailStore(fetcher: stub)

        let image = await store.image(for: url)

        #expect(image == nil)
        #expect(store.cachedImage(for: url) == nil)
        #expect(stub.thumbnailCallCount == 1)
    }
}

// MARK: - Local doubles

private enum ThumbnailTestError: Error {
    case malformedURL(String)
    case couldNotEncodePNG
}

/// Whether the store answered with an image, reduced to a `Sendable` value ON the main
/// actor — `NSImage` is not `Sendable`, so an `async let` child task may not carry one
/// out of the store's isolation domain.
@MainActor
private func resolved(_ store: DownloadThumbnailStore, _ url: URL) async -> Bool {
    await store.image(for: url) != nil
}

private func thumbnailTestURL(_ string: String) throws -> URL {
    guard let url = URL(string: string) else { throw ThumbnailTestError.malformedURL(string) }
    return url
}

/// Real PNG bytes, so `NSImage(data:)` succeeds for the same reason it does in
/// production rather than because the test handed it something special.
private func thumbnailPNGData() throws -> Data {
    let image = NSImage(size: NSSize(width: 4, height: 4))
    image.lockFocus()
    NSColor.systemPink.drawSwatch(in: NSRect(x: 0, y: 0, width: 4, height: 4))
    image.unlockFocus()
    guard let tiff = image.tiffRepresentation,
          let representation = NSBitmapImageRep(data: tiff),
          let png = representation.representation(using: .png, properties: [:])
    else {
        throw ThumbnailTestError.couldNotEncodePNG
    }
    return png
}

/// A canned ``OEmbedFetching`` that answers thumbnails from a table and counts asks.
///
/// `fetch(videoID:)` is never exercised here — the store only ever reaches for bytes —
/// but the protocol requires it, and answering `nil` is exactly what the production
/// conformer does for a lookup it cannot satisfy.
private final class StubThumbnailFetcher: OEmbedFetching, @unchecked Sendable {
    private let lock = NSLock()
    private let thumbnails: [URL: Data]
    private let latency: Duration
    private var asks = 0

    init(thumbnails: [URL: Data], latency: Duration = .zero) {
        self.thumbnails = thumbnails
        self.latency = latency
    }

    func fetch(videoID _: String) async -> OEmbedPayload? {
        nil
    }

    func fetchThumbnail(url: URL) async -> Data? {
        lock.withLock { asks += 1 }
        if latency > .zero {
            try? await Task.sleep(for: latency)
        }
        return thumbnails[url]
    }

    var thumbnailCallCount: Int {
        lock.withLock { asks }
    }
}
