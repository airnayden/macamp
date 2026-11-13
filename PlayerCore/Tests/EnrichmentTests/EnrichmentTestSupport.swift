// Shared helpers + test doubles for the Enrichment suites.
//
// `pollUntil` lets an async @MainActor test wait for the background enrichment
// Task to deliver onto the main actor without a fixed sleep. The fetchers are
// network-free doubles: `StubMetadataFetcher` returns canned lookup + composer
// values and counts calls; `BlockingMetadataFetcher` halts a pass mid-flight so
// cancellation can be exercised deterministically.
import Foundation
import GRDB
import Lyrics
import Metadata
import Persistence

@MainActor
func pollUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
        if clock.now >= deadline { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
}

@discardableResult
func insertTrack(_ database: AppDatabase, _ track: TrackRecord) throws -> TrackRecord {
    try TrackRepository(database).insert(track)
}

func fetchTrack(_ database: AppDatabase, id: Int64) throws -> TrackRecord? {
    try TrackRepository(database).fetchTrack(id: id)
}

/// Creates a real, writable temp audio file with the given extension so the
/// writable-format gate (`SFBMetadataWriter.writableExtensions` + `isWritableFile`)
/// can be exercised against a path that actually exists.
func makeTempAudioFile(ext: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("enrich-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("track.\(ext)")
    try Data([0x00]).write(to: url)
    return url
}

/// A canned ``OnlineMetadataFetching`` that returns a fixed lookup result and a
/// fixed composer, counting both call kinds. Never touches the network.
///
/// `latency` + `onActivity` let a test prove the SERIAL lane really is serial:
/// share one ``LaneActivityProbe`` with a ``FakeInfoService`` and the probe's
/// `maxObserved` stays 1 only if no two rate-limited calls ever overlap.
final class StubMetadataFetcher: OnlineMetadataFetching, @unchecked Sendable {
    private let result: MetadataLookupResult?
    private let composer: String?
    private let latency: Duration
    private let onActivity: (@Sendable (Bool) -> Void)?
    private let lock = NSLock()
    private var lookups = 0
    private var composerLookups = 0

    init(
        returning result: MetadataLookupResult?,
        composer: String? = nil,
        latency: Duration = .zero,
        onActivity: (@Sendable (Bool) -> Void)? = nil
    ) {
        self.result = result
        self.composer = composer
        self.latency = latency
        self.onActivity = onActivity
    }

    var lookupCount: Int {
        lock.withLock { lookups }
    }

    var composerLookupCount: Int {
        lock.withLock { composerLookups }
    }

    func lookup(
        artist _: String?,
        title _: String?,
        album _: String?,
        duration _: TimeInterval?
    ) async throws -> MetadataLookupResult? {
        lock.withLock { lookups += 1 }
        await settle()
        return result
    }

    func lookupComposer(recordingID _: String) async throws -> String? {
        lock.withLock { composerLookups += 1 }
        await settle()
        return composer
    }

    private func settle() async {
        onActivity?(true)
        defer { onActivity?(false) }
        if latency > .zero {
            try? await Task.sleep(for: latency)
        }
    }
}

/// A shared in-flight counter two fakes can report into, so a test can assert
/// they never overlap (``maxObserved`` stays 1) or that they do (> 1).
final class LaneActivityProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var inFlight = 0
    private var peak = 0

    /// The largest number of simultaneously-active calls seen so far.
    var maxObserved: Int {
        lock.withLock { peak }
    }

    /// Pass this straight into a fake's `onActivity` / `onPrefetchActivity`.
    var record: @Sendable (Bool) -> Void {
        { [self] entering in
            lock.withLock {
                inFlight += entering ? 1 : -1
                peak = max(peak, inFlight)
            }
        }
    }
}

/// A ``LyricsProviding`` that suspends for `latency` on every resolve and records
/// the peak number of resolves in flight — the proof that the parallel lane really
/// overlaps. Paths in `failing` throw instead of returning, so a test can show one
/// bad track neither stalls the lane nor double-counts progress.
final class SlowLyricsProvider: LyricsProviding, @unchecked Sendable {
    struct ResolveFailure: Error {}

    private let latency: Duration
    private let failing: Set<String>
    private let lock = NSLock()
    private var inFlight = 0
    private var peak = 0
    private var seen: [LyricsRequest] = []

    init(latency: Duration = .milliseconds(40), failing: Set<String> = []) {
        self.latency = latency
        self.failing = failing
    }

    var maxObservedConcurrency: Int {
        lock.withLock { peak }
    }

    var requests: [LyricsRequest] {
        lock.withLock { seen }
    }

    func resolveLyrics(for request: LyricsRequest, options _: LyricsOptions) async throws -> Lyrics? {
        lock.withLock {
            seen.append(request)
            inFlight += 1
            peak = max(peak, inFlight)
        }
        defer { lock.withLock { inFlight -= 1 } }
        try? await Task.sleep(for: latency)
        if let path = request.trackURL?.path, failing.contains(path) {
            throw ResolveFailure()
        }
        return nil
    }
}

/// A track with every fill-missing field populated, so ``EnrichmentService``
/// classifies it as needing no MusicBrainz work at all.
func metadataCompleteTrack(path: String, title: String, artist: String) -> TrackRecord {
    TrackRecord(
        filePath: path,
        title: title,
        artistName: artist,
        albumTitle: "Album",
        trackNumber: 1,
        availability: .present,
        genre: "Rock",
        albumArtist: artist,
        composer: "Composer",
        year: 1969
    )
}

/// An ``OnlineMetadataFetching`` that returns `result` for the first `blockAfter`
/// lookups, then suspends on a long, cancellable sleep — so a pass can be halted
/// mid-flight to prove committed rows survive a ``EnrichmentService/stop()``.
final class BlockingMetadataFetcher: OnlineMetadataFetching, @unchecked Sendable {
    private let result: MetadataLookupResult?
    private let blockAfter: Int
    private let lock = NSLock()
    private var calls = 0

    init(returning result: MetadataLookupResult?, blockAfter: Int = 1) {
        self.result = result
        self.blockAfter = blockAfter
    }

    var lookupCount: Int {
        lock.withLock { calls }
    }

    func lookup(
        artist _: String?,
        title _: String?,
        album _: String?,
        duration _: TimeInterval?
    ) async throws -> MetadataLookupResult? {
        let ordinal = lock.withLock { () -> Int in calls += 1; return calls }
        if ordinal > blockAfter {
            try await Task.sleep(for: .seconds(60))
        }
        return result
    }
}
