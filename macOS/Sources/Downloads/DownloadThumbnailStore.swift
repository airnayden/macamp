// DownloadThumbnailStore — poster frames for the download queue, in memory only.
//
// ── WHY THIS EXISTS AT ALL, INSTEAD OF `AsyncImage` ──────────────────────────
//
// `AsyncImage(url:)` would be one line and is forbidden here — by review AND by
// `scripts/check-downloader-boundary.sh`, which refuses the token anywhere in this
// surface. A view that fetches is a second egress path: it appears in no transport
// sweep, is described by no consent copy, has no timeout this app chose, and sends
// whatever headers SwiftUI happens to send. Routing the bytes through
// ``OEmbedFetching`` instead keeps every request the downloader makes inside the one
// file that is allowed to transport (`YouTubeOEmbedClient.swift`), under the same
// 5 s budget and the same ≤4 window as the metadata lookups they came from.
//
// ── MEMORY ONLY. NO DISK. ───────────────────────────────────────────────────
//
// `NSCache`, capped at ``cacheCountLimit`` entries, and nothing else — no
// `FileManager`, no Application Support directory, no index sidecar. A download
// queue is a runtime concept that resets on quit (`DownloadQueueService`'s own
// contract), so a thumbnail that outlived the row it decorated would be cache for a
// question nobody will ask again. `NSCache` additionally evicts under memory
// pressure on its own, so the ceiling is a bound on intent rather than the only
// thing standing between this and unbounded growth.
//
// ── WHY NOTHING HERE IS AN OBSERVABLE PROPERTY ──────────────────────────────
//
// The type is `@Observable` and every stored member is `@ObservationIgnored`, which
// is deliberate rather than an oversight. An observable "loaded images" map would be
// ONE property, so the hundredth thumbnail arriving would invalidate the other
// ninety-nine rows — the same property-granularity cascade ``DownloadRowLeaf``
// exists to avoid. Each row instead awaits its OWN image through a `.task(id:)` and
// holds it in its own `@State`, so an arriving image repaints exactly one row.
//
// This file constructs no `Process` and no `URLSession` — `macOS/Sources/Downloads`
// is scanned wholesale by `scripts/check-downloader-boundary.sh`.
import AppKit
import Foundation
import Observation
import Services
import SwiftUI

/// Resolves download-queue thumbnail URLs to decoded images, caching them in memory.
@MainActor
@Observable
final class DownloadThumbnailStore {
    /// How many decoded poster frames the cache keeps. The queue's own display window
    /// is 100 pending rows plus at most four active ones, so this holds a full screen
    /// of queue plus the one the person just scrolled past.
    static let cacheCountLimit = 200

    @ObservationIgnored private let fetcher: any OEmbedFetching
    @ObservationIgnored private let cache = NSCache<NSURL, NSImage>()

    /// One task per URL being fetched right now, so N rows naming the same poster
    /// frame — a queue can legitimately hold the same channel's art twice — cost one
    /// request rather than N.
    @ObservationIgnored private var inFlight: [URL: Task<NSImage?, Never>] = [:]

    init(fetcher: any OEmbedFetching) {
        self.fetcher = fetcher
        cache.countLimit = Self.cacheCountLimit
    }

    /// The already-decoded image for `url`, without touching the network.
    ///
    /// Lets a row paint a cached frame on its very first body evaluation, so scrolling
    /// back to a row does not flash its placeholder.
    func cachedImage(for url: URL) -> NSImage? {
        cache.object(forKey: url as NSURL)
    }

    /// The image for `url`, fetching it at most once.
    ///
    /// A cache hit returns without reaching ``OEmbedFetching`` at all — the assertion
    /// `DownloadThumbnailStoreTests` makes by call count, because an implementation
    /// that re-fetched every time would return an identical-looking image and pass any
    /// test that only compared pixels.
    ///
    /// A failed fetch is not remembered: `NSCache` cannot hold the absence of a value,
    /// and a row asks at most once per appearance, so the retry is bounded by the list
    /// rather than by a loop.
    func image(for url: URL) async -> NSImage? {
        if let cached = cachedImage(for: url) { return cached }
        if let existing = inFlight[url] { return await existing.value }
        let fetcher = fetcher
        let work = Task { [weak self] () -> NSImage? in
            let image = await fetcher.fetchThumbnail(url: url).flatMap(NSImage.init(data:))
            guard let self else { return image }
            inFlight[url] = nil
            if let image { cache.setObject(image, forKey: url as NSURL) }
            return image
        }
        inFlight[url] = work
        return await work.value
    }
}

extension EnvironmentValues {
    /// The queue's thumbnail store, or `nil` where none was injected.
    ///
    /// A dedicated environment entry rather than a read of `AppEnvironment`, for the
    /// same reason ``downloadsRowBodyProbe`` is one: the row views are hosted directly
    /// by `macOS/Tests/DownloadsRowInvalidationTests.swift` with no composition root in
    /// scope, and an `@Environment(AppEnvironment.self)` read would trap there. `nil`
    /// simply renders the placeholder, which is also what a `#Preview` gets.
    @Entry var downloadThumbnails: DownloadThumbnailStore?
}
