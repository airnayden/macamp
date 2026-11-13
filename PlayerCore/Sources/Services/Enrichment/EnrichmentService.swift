// EnrichmentService — background, pausable auto-enrichment of imported tracks.
//
// After an import, this walks the library and fills MISSING metadata + lyrics:
//   1. MusicBrainz lookup → fill missing title/artist/album/albumArtist/year/
//      genre/track-number (fill-missing only; a value already present is never
//      overwritten);
//   2. a follow-up MusicBrainz work-relationship lookup for the composer when it
//      is missing (one extra request, rate-limited by the SAME client limiter);
//   3. an LRCLIB fetch through ``LyricsProviding`` which caches the result;
//   4. a cache-gated prefetch of the online-info narratives for the track and
//      its artist, so the Info panel is instant when the user opens it.
//
// Steps 1, 2 and 4 all queue behind ONE shared MusicBrainz rate limiter; step 3
// hits a different host. ``EnrichmentService+Lanes`` therefore drives a page with
// two concurrent lanes — read that file for the split.
//
// The matching tag values are also written back to the file via
// ``MetadataWriting`` with the same fill-missing patch — skipped for read-only
// files and non-writable formats (.wav/.aiff/…), while the DB row + lyrics cache
// (which are MacAMP's, not the file's) are still updated.
//
// Memory: tracks are read in bounded id-keyset pages (never the whole table), so
// a 100k library never materialises in memory. The id keyset is stable even as
// title/sortTitle are mutated mid-walk (we order by the immutable rowid).
//
// Rate limiting: every MusicBrainz request goes through the injected
// ``OnlineMetadataFetching``; the production ``MusicBrainzClient`` serialises all
// of its requests (lookup + composer) ≥1s apart through its own internal limiter.
//
// `@MainActor` (like ``ReplayGainService``) — it owns mutable progress/state the
// UI reads; the heavy I/O all suspends off the main actor. It is deliberately NOT
// `@Observable`: ``EnrichmentViewModel`` is the observable projection and mirrors
// this state through the ``onChange`` callback.
//
// This file imports only Foundation/GRDB/Lyrics/Metadata/Persistence; it MUST NOT
// import AppKit or UIKit (PlayerCore portability invariant).
import Foundation
import GRDB
import Lyrics
import Metadata
import Persistence

/// Drives background metadata + lyrics enrichment over the library database.
@MainActor
public final class EnrichmentService {
    /// `true` between ``start()`` and the run finishing / ``stop()``.
    public private(set) var isRunning = false
    /// `true` when a running pass is suspended (``pause()``).
    public private(set) var isPaused = false
    /// Completed vs total tracks to process for the current pass.
    public private(set) var progress: (completed: Int, total: Int) = (0, 0)
    /// The title/filename of the track currently being processed, if any.
    public private(set) var currentTrack: String?

    /// Invoked on the main actor after any state mutation so an observable
    /// projection (``EnrichmentViewModel``) can mirror it. The service itself is
    /// not `@Observable`.
    public var onChange: (@MainActor () -> Void)?

    private let database: AppDatabase
    private let metadataFetcher: any OnlineMetadataFetching
    private let metadataWriter: any MetadataWriting
    private let lyricsProvider: any LyricsProviding
    private let infoService: (any InfoPrefetching)?
    private let pageSize: Int
    private var task: Task<Void, Never>?

    public init(
        database: AppDatabase,
        metadataFetcher: any OnlineMetadataFetching,
        metadataWriter: any MetadataWriting,
        lyricsProvider: any LyricsProviding,
        infoService: (any InfoPrefetching)? = nil,
        pageSize: Int = 100
    ) {
        self.database = database
        self.metadataFetcher = metadataFetcher
        self.metadataWriter = metadataWriter
        self.lyricsProvider = lyricsProvider
        self.infoService = infoService
        self.pageSize = max(1, pageSize)
    }
}

// MARK: - Control surface

public extension EnrichmentService {
    /// Starts a pass over the present tracks. A no-op while already running.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        isPaused = false
        currentTrack = nil
        progress = (0, 0)
        notify()
        task = Task { [weak self] in
            await self?.run()
        }
    }

    /// Suspends a running pass at the next track boundary.
    func pause() {
        guard isRunning, !isPaused else { return }
        isPaused = true
        notify()
    }

    /// Resumes a paused pass.
    func resume() {
        guard isRunning, isPaused else { return }
        isPaused = false
        notify()
    }

    /// Cancels the pass. Cancellation-safe: rows enriched so far stay committed.
    func stop() {
        task?.cancel()
        task = nil
        finish()
    }
}

// MARK: - Per-track enrichment

extension EnrichmentService {
    /// Runs every rate-limited step for one track — MusicBrainz lookup, the
    /// composer follow-up, and the cache-gated info prefetch — then writes the
    /// file tags and commits the row. Returns the (possibly updated) record so the
    /// caller can hand its lyrics fetch to the parallel lane.
    ///
    /// Called only from the serial lane: every `await` in here queues behind the
    /// shared 1-req/sec MusicBrainz limiter, so running two of these at once would
    /// buy nothing and would blur which request the limiter is pacing.
    func runRateLimitedWork(for track: TrackRecord) async -> TrackRecord {
        let url = URL(fileURLWithPath: track.filePath)
        var record = track
        var patch = WritableMetadata()
        if Self.needsMetadata(track), let result = await fetchMetadata(for: track) {
            Self.applyTextFields(from: result, to: &record, patch: &patch)
            Self.applyNumericFields(from: result, to: &record, patch: &patch)
            if Self.isBlank(track.composer), let composer = await fetchComposer(result: result) {
                record.composer = composer
                patch.composer = composer
            }
        }

        await prefetchInfo(for: record)

        if !patch.isEmpty, Self.shouldWriteFile(url) {
            try? metadataWriter.writeMetadata(patch, to: url)
        }
        if record != track {
            await commit(record)
        }
        return record
    }

    /// The parallel lane's unit of work: fetch + cache this track's lyrics, then
    /// mark it done. Safe to run alongside the serial lane and alongside itself —
    /// LRCLIB is a different host with no shared limiter.
    func runLyricsWork(for track: TrackRecord) async {
        await cacheLyrics(for: track, url: URL(fileURLWithPath: track.filePath))
        completeOne()
    }

    /// Pre-populates the online-info cache for this track + its artist so the Info
    /// panel is instant when the user opens it. Best-effort (results are ignored);
    /// the shared rate limiter paces the underlying requests. A no-op when no
    /// ``InfoPrefetching`` is injected (tests/previews).
    ///
    /// The cache probe is re-evaluated here rather than reused from lane
    /// classification because a MusicBrainz fill can change `title`/`artistName`,
    /// and those are the cache key.
    func prefetchInfo(for track: TrackRecord) async {
        guard let infoService else { return }
        guard await !infoService.hasCachedInfo(title: track.title, artist: track.artistName) else { return }
        if let title = track.title, !Self.isBlank(title) {
            _ = await infoService.trackInfo(title: title, artist: track.artistName, mbid: nil)
        }
        if let artist = track.artistName, !Self.isBlank(artist) {
            _ = await infoService.artistInfo(name: artist, mbid: nil)
        }
    }

    /// `true` when this track still needs a rate-limited info prefetch. Always
    /// `false` when no ``InfoPrefetching`` is injected — nothing to prefetch.
    func needsInfoPrefetch(_ track: TrackRecord) async -> Bool {
        guard let infoService else { return false }
        return await !infoService.hasCachedInfo(title: track.title, artist: track.artistName)
    }

    /// `true` when this track has work that must queue behind the shared
    /// MusicBrainz limiter, so it belongs in the serial lane.
    func needsSerialLane(_ track: TrackRecord) async -> Bool {
        if Self.needsMetadata(track) { return true }
        return await needsInfoPrefetch(track)
    }

    /// Fetches + caches this track's lyrics, recording a negative-result sentinel
    /// when the online lookup genuinely found none — so no later pass re-asks.
    func cacheLyrics(for track: TrackRecord, url: URL) async {
        let request = LyricsRequest(
            trackURL: url,
            title: track.title,
            artist: track.artistName,
            album: track.albumTitle,
            duration: track.duration
        )
        let resolved: Lyrics?
        do {
            resolved = try await lyricsProvider.resolveLyrics(for: request, options: .online)
        } catch {
            // A transient online failure is not a negative result: leaving the row
            // absent re-asks for this track next pass instead of hiding it forever.
            return
        }
        // A blank title never reaches LRCLIB's search fallback, so that `nil` is
        // "we never really asked", not "the service has nothing".
        guard resolved == nil, !Self.isBlank(track.title) else { return }
        await lyricsProvider.noteOnlineNoMatch(forKey: request.cacheKey)
    }
}

// MARK: - State mutation (main-actor only)

//
// `progress`/`currentTrack`/`isRunning`/`isPaused` are `private(set)`, so every
// write has to live in this file — the lanes drive them through these helpers.

extension EnrichmentService {
    func waitWhilePaused() async {
        while isPaused, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Records the most-recently-STARTED track. With two lanes in flight the UI
    /// can only ever name one of them; the serial driver picks the newest.
    func beginTrack(_ track: TrackRecord) {
        currentTrack = track.title ?? URL(fileURLWithPath: track.filePath).lastPathComponent
        notify()
    }

    func beginPass(total: Int) {
        progress = (0, total)
        notify()
    }

    /// Advances `progress` by one fully-finished track.
    func completeOne() {
        progress.completed += 1
        notify()
    }

    func finish() {
        isRunning = false
        isPaused = false
        currentTrack = nil
        notify()
    }

    func notify() {
        onChange?()
    }
}

private extension EnrichmentService {
    func fetchMetadata(for track: TrackRecord) async -> MetadataLookupResult? {
        let result = try? await metadataFetcher.lookup(
            artist: track.artistName,
            title: track.title,
            album: track.albumTitle,
            duration: track.duration
        )
        return result ?? nil
    }

    func fetchComposer(result: MetadataLookupResult) async -> String? {
        guard let mbid = result.recordingID else { return nil }
        let fetched = try? await metadataFetcher.lookupComposer(recordingID: mbid)
        guard let composer = fetched ?? nil, !composer.isEmpty else { return nil }
        return composer
    }
}

// MARK: - Bounded, off-main database access (id-keyset)

extension EnrichmentService {
    func presentTrackCount() async -> Int {
        let present = Availability.present.rawValue
        let count = try? await database.writer.read { db in
            try TrackRecord
                .filter(TrackRecord.Columns.availability == present)
                .fetchCount(db)
        }
        return count ?? 0
    }

    func nextPage(afterID lastID: Int64?) async -> [TrackRecord] {
        let limit = pageSize
        let present = Availability.present.rawValue
        let page = try? await database.writer.read { db -> [TrackRecord] in
            var request = TrackRecord
                .filter(TrackRecord.Columns.availability == present)
            if let lastID {
                request = request.filter(TrackRecord.Columns.id > lastID)
            }
            return try request
                .order(TrackRecord.Columns.id)
                .limit(limit)
                .fetchAll(db)
        }
        return page ?? []
    }

    func commit(_ track: TrackRecord) async {
        try? await database.writer.write { db in
            try track.update(db)
        }
    }
}

// MARK: - Fill-missing semantics (pure)

private extension EnrichmentService {
    static func needsMetadata(_ track: TrackRecord) -> Bool {
        isBlank(track.title) || isBlank(track.artistName) || isBlank(track.albumTitle)
            || isBlank(track.albumArtist) || isBlank(track.genre)
            || track.year == nil || track.trackNumber == nil
    }

    static func applyTextFields(
        from result: MetadataLookupResult,
        to record: inout TrackRecord,
        patch: inout WritableMetadata
    ) {
        if isBlank(record.title), let title = result.title {
            record.title = title
            record.sortTitle = SortKey.sortKeyOrNil(title)
            patch.title = title
        }
        if isBlank(record.artistName), let artist = result.artist {
            record.artistName = artist
            patch.artist = artist
        }
        if isBlank(record.albumTitle), let album = result.album {
            record.albumTitle = album
            patch.album = album
        }
        if isBlank(record.albumArtist), let albumArtist = result.albumArtist {
            record.albumArtist = albumArtist
            patch.albumArtist = albumArtist
        }
        if isBlank(record.genre), let genre = result.genre {
            record.genre = genre
            patch.genre = genre
        }
    }

    static func applyNumericFields(
        from result: MetadataLookupResult,
        to record: inout TrackRecord,
        patch: inout WritableMetadata
    ) {
        if record.year == nil, let year = result.year {
            record.year = year
            patch.year = year
        }
        if record.trackNumber == nil, let trackNumber = result.trackNumber {
            record.trackNumber = trackNumber
            patch.trackNumber = trackNumber
        }
        if record.discNumber == nil, let discNumber = result.discNumber {
            record.discNumber = discNumber
            patch.discNumber = discNumber
        }
    }

    /// Writable only when the format can carry tags AND the file is not read-only;
    /// .wav/.aiff and locked files fall out here so the file write is skipped.
    static func shouldWriteFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        guard SFBMetadataWriter.writableExtensions.contains(ext) else { return false }
        return FileManager.default.isWritableFile(atPath: url.path)
    }

    static func isBlank(_ value: String?) -> Bool {
        guard let value else { return true }
        return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
