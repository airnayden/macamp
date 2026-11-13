// The rig `ChatDownloadPlaylistAppenderTests` is written against: a real migrated
// in-memory database, a real `PlaylistRepository`, a real `TrackRepository`, and a
// scanner wrapper that COUNTS every scan it is asked for.
//
// Two scanner modes, because the suite has two different things to prove:
//
//   * `.counting` — answers a canned summary and touches nothing. Library rows are
//     inserted by the test itself, which is what lets an assertion about SCAN COUNT be
//     read as a statement about the pipeline rather than about the filesystem.
//   * `.real` — forwards to a real `LibraryScanner` over the same database. This is the
//     only way to prove the `skipped: 1, added: 0` success case honestly: a fake that
//     returns that summary proves nothing, because the whole point is that the summary
//     is ADVISORY and the row is already there.
//
// Both modes go through the same counting wrapper, so `scanLog.count` means the same
// thing in either.
//
// The three lock boxes exist because the appender's gate seams are `@Sendable` closures
// (`isAutoImportEnabled`, `libraryRoots`) — they may be called off the main actor, so
// their backing values cannot be `@MainActor` fixture properties. `activeProfileId` is
// boxed for the same shape rather than a second mechanism.
//
// Names are prefixed `ChatAppend…` / `chatAppend…` because the whole `DownloadsTests`
// target shares one namespace (`DownloadLibrarySupport.swift`'s recorded learning).
import Foundation
import Metadata
import os
import Persistence
import PlayerCoreTestSupport
import Services
import Testing

/// One scan the appender asked for. `summary` is `nil` for the streaming entry point,
/// which the appender is not expected to use at all.
struct ChatAppendScanRecord: Equatable {
    var files: [URL]
    var summary: ScanSummary?
}

/// Every scan request that reached the scanner, in order.
final class ChatAppendScanLog: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: [ChatAppendScanRecord]())

    var records: [ChatAppendScanRecord] {
        state.withLock { $0 }
    }

    var count: Int {
        state.withLock { $0.count }
    }

    func record(_ request: ScanRequest, summary: ScanSummary?) {
        let entry = ChatAppendScanRecord(files: Self.files(in: request), summary: summary)
        state.withLock { $0.append(entry) }
    }

    private static func files(in request: ScanRequest) -> [URL] {
        switch request {
        case let .files(urls): urls
        case let .directory(url): [url]
        case let .manifest(candidates): candidates.map(\.url)
        }
    }
}

/// Which scanner the fixture puts behind the counting wrapper.
enum ChatAppendScannerMode {
    case counting
    case real
}

/// A ``LibraryScanning`` that records every request and optionally forwards it to a real
/// scanner.
///
/// Both entry points record, so a pipeline that reached for `events(for:)` instead of
/// `scan(_:)` would still be counted — the exactly-one-scan assertion cannot be dodged
/// by picking the other method.
struct ChatAppendCountingScanner: LibraryScanning {
    let log: ChatAppendScanLog
    let inner: (any LibraryScanning)?
    let cannedSummary: ScanSummary

    func scan(_ request: ScanRequest) async -> ScanSummary {
        let summary = await inner?.scan(request) ?? cannedSummary
        log.record(request, summary: summary)
        return summary
    }

    func events(for request: ScanRequest) -> AsyncStream<ScanEvent> {
        log.record(request, summary: nil)
        if let inner { return inner.events(for: request) }
        let summary = cannedSummary
        return AsyncStream { continuation in
            continuation.yield(.finished(summary))
            continuation.finish()
        }
    }
}

/// The auto-import switch and the active profile's library roots, readable from any
/// isolation.
struct ChatAppendGateSettings {
    var autoImport = false
    var roots: [URL] = []
}

/// A `Sendable` box for ``ChatAppendGateSettings`` so the appender's `@Sendable` gate
/// closures can read it, and a test can flip it between calls.
final class ChatAppendGateBox: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: ChatAppendGateSettings())

    var autoImport: Bool {
        state.withLock { $0.autoImport }
    }

    var roots: [URL] {
        state.withLock { $0.roots }
    }

    func set(autoImport: Bool, roots: [URL] = []) {
        state.withLock {
            $0.autoImport = autoImport
            $0.roots = roots
        }
    }
}

/// A `Sendable` box for the active profile id.
final class ChatAppendProfileBox: Sendable {
    private let state: OSAllocatedUnfairLock<Int64>

    init(_ value: Int64) {
        state = OSAllocatedUnfairLock(initialState: value)
    }

    var value: Int64 {
        state.withLock { $0 }
    }

    func set(_ newValue: Int64) {
        state.withLock { $0 = newValue }
    }
}

/// Everything the appender announced, in order.
@MainActor
final class ChatAppendAnnouncementLog {
    private(set) var events: [ChatDownloadAppendEvent] = []

    func record(_ event: ChatDownloadAppendEvent) {
        events.append(event)
    }

    func reset() {
        events.removeAll()
    }
}

/// The assembled appender plus every seam a test needs to drive or inspect it.
@MainActor
final class ChatDownloadAppenderFixture {
    let database: AppDatabase
    let destination: URL
    let scanLog: ChatAppendScanLog
    let scanner: ChatAppendCountingScanner
    let playlists: PlaylistRepository
    let tracks: TrackRepository
    let registry = SuggestionDownloadRegistry()
    let gate = ChatAppendGateBox()
    let profile = ChatAppendProfileBox(ProfileRecord.guestID)
    let announcements = ChatAppendAnnouncementLog()

    private(set) lazy var appender = ChatDownloadPlaylistAppender(
        registry: registry,
        scanner: scanner,
        isAutoImportEnabled: { [gate] in gate.autoImport },
        libraryRoots: { [gate] _ in gate.roots },
        activeProfileId: { [profile] in profile.value },
        trackLookup: { [tracks] path in
            try await Task.detached(priority: .utility) {
                try tracks.fetchTrack(filePath: path)?.id
            }.value
        },
        playlists: playlists,
        announce: { [announcements] event in announcements.record(event) }
    )

    init(scannerMode: ChatAppendScannerMode = .counting) throws {
        let database = try AppDatabase.makeEmpty()
        let log = ChatAppendScanLog()
        let inner: (any LibraryScanning)? = scannerMode == .real
            ? LibraryScanner(database: database, metadataReader: FakeMetadataReader())
            : nil
        self.database = database
        destination = try downloadLibraryTempDirectory("chat-append")
        scanLog = log
        scanner = ChatAppendCountingScanner(log: log, inner: inner, cannedSummary: ScanSummary(added: 1))
        playlists = PlaylistRepository(database)
        tracks = TrackRepository(database)
        gate.set(autoImport: true)
    }

    /// A real file in the (non-root) destination folder, the way a finished download
    /// leaves one.
    @discardableResult
    func writeDownloadedFile(named name: String = "Finished [dQw4w9WgXcQ].m4a") throws -> URL {
        try downloadLibraryWriteAudioFile(in: destination, named: name)
    }

    /// Inserts a library row directly, for the `.counting` mode where no scan ever runs.
    @discardableResult
    func insertTrack(at path: String) throws -> Int64 {
        try database.writer.write { db in
            var record = TrackRecord(filePath: path, title: "Finished", duration: 120)
            try record.insert(db)
            return record.id ?? 0
        }
    }

    @discardableResult
    func makePlaylist(named name: String) throws -> Int64 {
        try playlists.create(named: name, profileId: ProfileRecord.guestID).id ?? 0
    }

    /// The playlist's membership in `position` order, read through the shipped keyset
    /// page the acceptance criteria name.
    func membership(playlistId: Int64) async throws -> [Int64] {
        try await playlists.playlistTracksPage(playlistId: playlistId).items.compactMap(\.track.id)
    }

    func libraryRowCount() throws -> Int {
        try database.writer.read { db in try TrackRecord.fetchCount(db) }
    }

    func registration(_ target: SuggestionAppendTarget, profileId: Int64 = ProfileRecord.guestID)
        -> SuggestionDownloadRegistration
    {
        SuggestionDownloadRegistration(target: target, profileId: profileId)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: destination)
    }
}
