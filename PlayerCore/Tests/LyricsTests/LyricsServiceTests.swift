import Foundation
@testable import Lyrics
import Testing

@Suite("LyricsServiceTests")
struct LyricsServiceTests {
    private let trackURL = URL(fileURLWithPath: "/music/song.flac")

    @Test("Local lyrics survive an optional online failure", arguments: [false, true])
    func localLyricsSurviveNetworkFailure(useSidecar: Bool) async throws {
        let service = LyricsService(
            embeddedReader: FakeEmbeddedLyricsReader(useSidecar ? nil : EmbeddedLyrics(synced: "[00:01.00]embedded")),
            sidecar: FakeSidecarReader(useSidecar ? "[00:01.00]sidecar" : nil),
            lrclib: FailingLyricsFetcher(cancelled: false), cache: nil
        )
        let result = try await service.resolveLyrics(for: LyricsRequest(trackURL: trackURL), options: .online)
        #expect(result?.source == (useSidecar ? .lrcFile : .embeddedSynced))
    }

    @Test("Online failure without local lyrics remains an error")
    func networkFailureWithoutFallbackPropagates() async {
        let service = LyricsService(
            embeddedReader: FakeEmbeddedLyricsReader(nil), sidecar: FakeSidecarReader(nil),
            lrclib: FailingLyricsFetcher(cancelled: false), cache: nil
        )
        await #expect(throws: URLError.self) {
            _ = try await service.resolveLyrics(for: LyricsRequest(trackURL: trackURL), options: .online)
        }
    }

    @Test("Cancellation is not converted into a local fallback")
    func cancellationPropagates() async {
        let service = LyricsService(
            embeddedReader: FakeEmbeddedLyricsReader(EmbeddedLyrics(synced: "[00:01.00]embedded")),
            sidecar: FakeSidecarReader(nil), lrclib: FailingLyricsFetcher(cancelled: true), cache: nil
        )
        await #expect(throws: CancellationError.self) {
            _ = try await service.resolveLyrics(for: LyricsRequest(trackURL: trackURL), options: .online)
        }
    }

    @Test("precedence: embedded-synced > .lrc > LRCLIB > embedded-unsynced")
    func precedenceRanking() {
        let embeddedSynced = Lyrics(lines: [LyricLine(time: 1, text: "es")], source: .embeddedSynced)
        let lrcFile = Lyrics(lines: [LyricLine(time: 1, text: "lrc")], source: .lrcFile)
        let online = Lyrics(lines: [LyricLine(time: 1, text: "net")], source: .lrclib)
        let embeddedUnsynced = Lyrics(lines: [LyricLine(text: "eu")], source: .embeddedUnsynced)

        #expect(LyricsService.resolve(from: [embeddedUnsynced, online, lrcFile, embeddedSynced])?
            .source == .embeddedSynced)
        #expect(LyricsService.resolve(from: [embeddedUnsynced, online, lrcFile])?.source == .lrcFile)
        #expect(LyricsService.resolve(from: [embeddedUnsynced, online])?.source == .lrclib)
        #expect(LyricsService.resolve(from: [embeddedUnsynced])?.source == .embeddedUnsynced)
        #expect(LyricsService.resolve(from: []) == nil)
    }

    @Test("end-to-end: embedded synced beats both .lrc and online")
    func serviceEmbeddedSyncedWins() async throws {
        let service = LyricsService(
            embeddedReader: FakeEmbeddedLyricsReader(EmbeddedLyrics(synced: "[00:01.00]embedded synced")),
            sidecar: FakeSidecarReader("[00:01.00]from lrc"),
            lrclib: MockOnlineLyricsFetcher(returning: OnlineLyricsResult(syncedLyrics: "[00:01.00]from net")),
            cache: nil
        )
        let resolved = try await service.resolveLyrics(for: LyricsRequest(trackURL: trackURL), options: .online)
        let lyrics = try #require(resolved)
        #expect(lyrics.source == .embeddedSynced)
    }

    @Test("online is never queried when online fetch is opted out")
    func onlineNotFetchedWhenOptOut() async throws {
        let mock = MockOnlineLyricsFetcher(returning: OnlineLyricsResult(syncedLyrics: "[00:01.00]net"))
        let service = LyricsService(
            embeddedReader: FakeEmbeddedLyricsReader(nil),
            sidecar: FakeSidecarReader(nil),
            lrclib: mock,
            cache: nil
        )
        let resolved = try await service.resolveLyrics(for: LyricsRequest(trackURL: trackURL), options: .offline)
        #expect(resolved == nil)
        #expect(mock.fetchCount == 0)
    }

    @Test("online is queried only on opt-in and yields a .lrclib result")
    func onlineFetchedWhenOptIn() async throws {
        let mock = MockOnlineLyricsFetcher(returning: OnlineLyricsResult(syncedLyrics: "[00:01.00]net"))
        let service = LyricsService(
            embeddedReader: FakeEmbeddedLyricsReader(nil),
            sidecar: FakeSidecarReader(nil),
            lrclib: mock,
            cache: nil
        )
        let resolved = try await service.resolveLyrics(for: LyricsRequest(title: "T", artist: "A"), options: .online)
        let lyrics = try #require(resolved)
        #expect(lyrics.source == .lrclib)
        #expect(mock.fetchCount == 1)
    }

    @Test("a sidecar .lrc outranks an online result even when both are present")
    func sidecarWinsOverOnline() async throws {
        let mock = MockOnlineLyricsFetcher(returning: OnlineLyricsResult(syncedLyrics: "[00:01.00]net"))
        let service = LyricsService(
            embeddedReader: FakeEmbeddedLyricsReader(nil),
            sidecar: FakeSidecarReader("[00:01.00]from lrc"),
            lrclib: mock,
            cache: nil
        )
        let resolved = try await service.resolveLyrics(for: LyricsRequest(trackURL: trackURL), options: .online)
        let lyrics = try #require(resolved)
        #expect(lyrics.source == .lrcFile)
        #expect(mock.fetchCount == 1)
    }
}

private struct FailingLyricsFetcher: OnlineLyricsFetching {
    let cancelled: Bool

    func fetch(
        artist _: String?,
        title _: String?,
        album _: String?,
        duration _: TimeInterval?
    ) async throws -> OnlineLyricsResult? {
        if cancelled { throw CancellationError() }
        throw URLError(.notConnectedToInternet)
    }
}
