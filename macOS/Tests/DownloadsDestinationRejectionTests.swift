// DownloadsDestinationRejectionTests — the Downloads pane's two shell-side decisions:
// which folders may hold downloads, and when the engine is old enough to warn about.
//
// These live here rather than in `swift test` for the same reason `DownloadDestinationTests`
// does: `DownloadsDestinationRejection` and `DownloadEngineVersionAge` are `macOS/Sources`
// types the SwiftPM package cannot see.
//
// The karaoke pair is the load-bearing one. The cache is GLOBAL and user-relocatable, so
// an overlap can point either way — the download folder can swallow the cache, or sit
// inside it — and both must be refused. A test that only drove one direction would pass
// against a one-sided check.
import Foundation
@testable import MacAMP
import Services
import Testing

@Suite("Downloads destination rejection")
struct DownloadsDestinationRejectionTests {
    /// A writable scratch directory, removed by the caller's `defer`.
    private func scratchDirectory(_ label: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macamp-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test("a plain writable folder clear of the cache is accepted")
    func anOrdinaryFolderIsAccepted() throws {
        let destination = try scratchDirectory("destination")
        let cache = try scratchDirectory("cache")
        defer {
            try? FileManager.default.removeItem(at: destination)
            try? FileManager.default.removeItem(at: cache)
        }

        #expect(DownloadsDestinationRejection.reject(destination, karaokeCacheDirectory: cache) == nil)
    }

    /// Direction one: the chosen folder CONTAINS the karaoke cache, so a download landing
    /// there would put the app's own rendered instrumentals under the same roof.
    @Test("a folder containing the karaoke cache is refused")
    func aFolderContainingTheCacheIsRefused() throws {
        let destination = try scratchDirectory("destination")
        defer { try? FileManager.default.removeItem(at: destination) }
        let cache = destination.appendingPathComponent("Instrumentals", isDirectory: true)

        #expect(DownloadsDestinationRejection.reject(destination, karaokeCacheDirectory: cache) == .karaokeCache)
    }

    /// Direction two: the chosen folder sits INSIDE the karaoke cache, so pruning the
    /// cache would delete the listener's downloads.
    @Test("a folder inside the karaoke cache is refused")
    func aFolderInsideTheCacheIsRefused() throws {
        let cache = try scratchDirectory("cache")
        defer { try? FileManager.default.removeItem(at: cache) }
        let destination = cache.appendingPathComponent("Downloads", isDirectory: true)

        #expect(DownloadsDestinationRejection.reject(destination, karaokeCacheDirectory: cache) == .karaokeCache)
    }

    @Test("the cache directory itself is refused")
    func theCacheDirectoryItselfIsRefused() throws {
        let cache = try scratchDirectory("cache")
        defer { try? FileManager.default.removeItem(at: cache) }

        #expect(DownloadsDestinationRejection.reject(cache, karaokeCacheDirectory: cache) == .karaokeCache)
    }

    @Test("MacAMP's own Application Support container is refused")
    func anAppInternalFolderIsRefused() throws {
        let support = try #require(
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        )
        let candidate = support.appendingPathComponent("MacAMP-\(UUID().uuidString)", isDirectory: true)

        #expect(DownloadsDestinationRejection.reject(candidate, karaokeCacheDirectory: nil) == .appInternal)
        // The order is load-bearing: the writability probe CREATES what it probes, so a
        // refusal that ran it would leave a directory behind inside the app's container.
        #expect(!FileManager.default.fileExists(atPath: candidate.path))
    }

    /// Mode `0o500` (r-x------) is a real filesystem refusal — the closest a test gets to
    /// a TCC denial without a privacy prompt.
    @Test("an unwritable folder is refused")
    func anUnwritableFolderIsRefused() throws {
        let manager = FileManager.default
        let destination = try scratchDirectory("readonly")
        defer {
            try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: destination.path)
            try? manager.removeItem(at: destination)
        }
        try manager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: destination.path)
        let candidate = destination.appendingPathComponent("Downloads", isDirectory: true)

        #expect(DownloadsDestinationRejection.reject(candidate, karaokeCacheDirectory: nil) == .notWritable)
    }

    /// Every refusal says something different, so a listener is told which rule they hit
    /// rather than a single "that folder won't work".
    @Test("each refusal carries its own localized message")
    func eachRefusalHasItsOwnMessage() {
        let messages = [
            DownloadsDestinationRejection.appInternal,
            .karaokeCache,
            .notWritable,
        ].map { String(localized: $0.message) }

        #expect(Set(messages).count == messages.count)
        #expect(messages.allSatisfy { !$0.isEmpty })
    }

    /// The QA scenario, as an invariant: a refused folder is surfaced and NOT persisted.
    @Test("a refused folder never reaches the stored preferences")
    func refusedFolderIsNotPersisted() {
        let preferences = DownloadPreferences(destinationPath: "/tmp/macamp-keep-me")
        let chosen = URL(fileURLWithPath: "/tmp/macamp-refused", isDirectory: true)

        let refused = preferences.choosingDestination(chosen, refusal: .karaokeCache)
        let accepted = preferences.choosingDestination(chosen, refusal: nil)

        #expect(refused == preferences)
        #expect(accepted.destinationPath == "/tmp/macamp-refused")
    }
}

@Suite("Download engine version age")
struct DownloadEngineVersionAgeTests {
    private static let day: TimeInterval = 24 * 60 * 60

    /// yt-dlp tags releases `YYYY.MM.DD`, so the tag IS the release date. Built from a
    /// real offset rather than a literal so the test does not rot.
    private func tag(daysAgo: Int, from now: Date) -> String {
        let released = now.addingTimeInterval(-Double(daysAgo) * Self.day)
        let fields = Calendar.current.dateComponents([.year, .month, .day], from: released)
        let month = String(format: "%02d", fields.month ?? 0)
        let day = String(format: "%02d", fields.day ?? 0)
        return "\(fields.year ?? 0).\(month).\(day)"
    }

    @Test("an engine older than ninety days is stale")
    func anOldEngineIsStale() {
        let now = Date()

        #expect(DownloadEngineVersionAge.isStale(tag(daysAgo: 120, from: now), now: now))
    }

    @Test("a recent engine is not stale, and neither is one exactly at the threshold")
    func recentEngineIsNotStale() {
        let now = Date()

        #expect(!DownloadEngineVersionAge.isStale(tag(daysAgo: 10, from: now), now: now))
        #expect(!DownloadEngineVersionAge.isStale(tag(daysAgo: 90, from: now), now: now))
    }

    /// A tag this code cannot read must stay quiet: a false staleness warning about a
    /// version nobody can interpret is worse than no warning at all.
    @Test("an unreadable tag is never reported as stale")
    func anUnreadableTagIsNotStale() {
        for version in ["", "nightly", "2025.09", "abc.def.ghi", "2025.13.01"] {
            #expect(!DownloadEngineVersionAge.isStale(version))
        }
    }

    @Test("a four-field tag still yields its release date")
    func revisionSuffixIsIgnored() throws {
        let released = try #require(DownloadEngineVersionAge.releaseDate(from: "2026.03.09.232703"))
        let fields = Calendar.current.dateComponents([.year, .month, .day], from: released)

        #expect(fields.year == 2026)
        #expect(fields.month == 3)
        #expect(fields.day == 9)
    }
}
