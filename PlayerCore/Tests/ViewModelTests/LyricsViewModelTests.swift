import Foundation
import Lyrics
import Testing
@testable import ViewModels

@MainActor
struct LyricsViewModelTests {
    private func syncedLyrics() -> Lyrics {
        Lyrics(
            lines: [
                LyricLine(time: 0, text: "Intro"),
                LyricLine(time: 10, text: "Verse", words: [
                    TimedWord(time: 10, text: "Ver"),
                    TimedWord(time: 12, text: "se"),
                ]),
                LyricLine(time: 20, text: "Chorus"),
            ],
            source: .lrcFile
        )
    }

    @Test func resolvesAndExposesLines() async {
        let provider = FakeLyricsProvider(returning: syncedLyrics())
        let model = LyricsViewModel(provider: provider)
        model.resolve(request: LyricsRequest(title: "Song"))
        await pollUntil { model.lyrics != nil }
        #expect(model.lines.count == 3)
        #expect(!model.isLoading)
    }

    @Test func highlightTracksActiveLineAndWord() async {
        let provider = FakeLyricsProvider(returning: syncedLyrics())
        let model = LyricsViewModel(provider: provider)
        model.resolve(request: LyricsRequest(title: "Song"))
        await pollUntil { model.lyrics != nil }

        model.updateHighlight(at: 12)
        #expect(model.activeLineIndex == 1)
        #expect(model.activeLine?.text == "Verse")
        #expect(model.activeWordIndex == 1)

        model.updateHighlight(at: 0)
        #expect(model.activeLineIndex == 0)

        model.updateHighlight(at: 25)
        #expect(model.activeLineIndex == 2)
    }

    @Test func nilLyricsClearsHighlight() async {
        let provider = FakeLyricsProvider(returning: nil)
        let model = LyricsViewModel(provider: provider)
        model.resolve(request: LyricsRequest(title: "Song"))
        await pollUntil { !model.isLoading }
        #expect(model.lyrics == nil)
        model.updateHighlight(at: 10)
        #expect(model.activeLineIndex == nil)
    }
}

/// A ``LyricsProviding`` that always throws — the "service unreachable" arm of the
/// resolver contract, which is distinct from returning `nil` (a genuine no-match).
private struct FailingLyricsProvider: LyricsProviding {
    struct Failure: Error {}
    let error: any Error

    init(error: any Error = Failure()) {
        self.error = error
    }

    func resolveLyrics(for _: LyricsRequest, options _: LyricsOptions) async throws -> Lyrics? {
        throw error
    }
}

@MainActor
struct LyricsFetchOutcomeTests {
    private func request() -> LyricsRequest {
        LyricsRequest(title: "Song")
    }

    private func lyrics() -> Lyrics {
        Lyrics(lines: [LyricLine(time: 0, text: "Intro")], source: .lrcFile)
    }

    @Test func startsIdle() {
        let model = LyricsViewModel(provider: FakeLyricsProvider(returning: nil))
        #expect(model.fetchOutcome == .idle)
    }

    @Test func explicitFetchReportsLoadingBeforeItResolves() {
        let model = LyricsViewModel(provider: FakeLyricsProvider(returning: nil))
        model.resolve(request: request(), explicit: true)
        #expect(model.fetchOutcome == .loading)
    }

    @Test func passiveLoadNeverReportsLoading() {
        let model = LyricsViewModel(provider: FakeLyricsProvider(returning: nil))
        model.resolve(request: request())
        #expect(model.fetchOutcome == .idle)
    }

    @Test func resolvedLyricsReportFound() async {
        let model = LyricsViewModel(provider: FakeLyricsProvider(returning: lyrics()))
        model.resolve(request: request(), explicit: true)
        await pollUntil { !model.isLoading }
        #expect(model.fetchOutcome == .found)
    }

    @Test func passiveResolvedLyricsAlsoReportFound() async {
        let model = LyricsViewModel(provider: FakeLyricsProvider(returning: lyrics()))
        model.resolve(request: request())
        await pollUntil { !model.isLoading }
        #expect(model.fetchOutcome == .found)
    }

    @Test func explicitMissReportsNoMatch() async {
        let model = LyricsViewModel(provider: FakeLyricsProvider(returning: nil))
        model.resolve(request: request(), explicit: true)
        await pollUntil { !model.isLoading }
        #expect(model.fetchOutcome == .noMatch)
    }

    @Test func passiveMissStaysSilent() async {
        let model = LyricsViewModel(provider: FakeLyricsProvider(returning: nil))
        model.resolve(request: request())
        await pollUntil { !model.isLoading }
        #expect(model.fetchOutcome == .idle)
    }

    @Test func explicitThrowReportsFailed() async {
        let model = LyricsViewModel(provider: FailingLyricsProvider())
        model.resolve(request: request(), options: .online, explicit: true)
        await pollUntil { !model.isLoading }
        #expect(model.fetchOutcome == .failed)
        #expect(model.lyrics == nil)
        #expect(model.lines.isEmpty)
    }

    @Test func automaticOnlineFailureIsVisible() async {
        let model = LyricsViewModel(provider: FailingLyricsProvider())
        model.resolve(request: request(), options: .online)
        await pollUntil { !model.isLoading }
        #expect(model.fetchOutcome == .failed)
    }

    @Test func passiveResolveClearsAPriorExplicitFailure() async {
        let model = LyricsViewModel(provider: FailingLyricsProvider())
        model.resolve(request: request(), options: .online, explicit: true)
        await pollUntil { model.fetchOutcome == .failed }

        model.resolve(request: request(), options: .online)
        #expect(model.fetchOutcome == .loading)
    }

    @Test(arguments: [401, 429, 503])
    func serviceFailureRetainsTheHTTPStatus(_ status: Int) async {
        let model = LyricsViewModel(provider: FailingLyricsProvider(error: OnlineLyricsError.httpStatus(status)))
        model.resolve(request: request(), options: .online)
        await pollUntil { !model.isLoading }

        #expect(model.fetchOutcome == .failed)
        #expect(model.fetchFailure == .serviceStatus(status))
    }

    @Test func networkFailureRetainsTheSystemReason() async {
        let error = URLError(.timedOut)
        let model = LyricsViewModel(provider: FailingLyricsProvider(error: error))
        model.resolve(request: request(), options: .online, explicit: true)
        await pollUntil { !model.isLoading }

        #expect(model.fetchFailure == .network(code: error.errorCode, message: error.localizedDescription))
    }

    @Test func malformedResponseIsReportedAsAResponseFailure() async {
        let error = DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Invalid JSON"))
        let model = LyricsViewModel(provider: FailingLyricsProvider(error: error))
        model.resolve(request: request(), options: .online)
        await pollUntil { !model.isLoading }

        #expect(model.fetchOutcome == .failed)
        #expect(model.fetchFailure == .invalidResponse)
    }

    @Test func onlineMissReportsNoMatchWithoutFailureDetails() async {
        let model = LyricsViewModel(provider: FakeLyricsProvider())
        model.resolve(request: request(), options: .online)
        await pollUntil { !model.isLoading }

        #expect(model.fetchOutcome == .noMatch)
        #expect(model.fetchFailure == nil)
    }

    @Test func retryClearsFailureAndShowsSuccessfulLyrics() async {
        let expected = lyrics()
        let model = LyricsViewModel(provider: RetryingLyricsProvider(lyrics: expected))
        model.resolve(request: request(), options: .online)
        await pollUntil { !model.isLoading }
        #expect(model.fetchFailure == .serviceStatus(503))

        model.resolve(request: request(), options: .online, explicit: true)
        #expect(model.fetchOutcome == .loading)
        #expect(model.fetchFailure == nil)
        await pollUntil { !model.isLoading }

        #expect(model.fetchOutcome == .found)
        #expect(model.lyrics == expected)
        #expect(model.fetchFailure == nil)
    }

    @Test func clearCancelsAnInFlightFetchWithoutPublishingAFailure() async {
        let provider = CancellableLyricsProvider()
        let model = LyricsViewModel(provider: provider)
        model.resolve(request: request(), options: .online)
        await pollUntil { provider.started }
        #expect(provider.started)

        model.clear()
        await pollUntil { provider.cancelled }

        #expect(provider.cancelled)
        #expect(!model.isLoading)
        #expect(model.fetchOutcome == .idle)
        #expect(model.fetchFailure == nil)
    }

    @Test func clearResetsOutcome() async {
        let model = LyricsViewModel(provider: FakeLyricsProvider(returning: nil))
        model.resolve(request: request(), explicit: true)
        await pollUntil { model.fetchOutcome == .noMatch }

        model.clear()
        #expect(model.fetchOutcome == .idle)
    }
}


private actor RetryingLyricsProvider: LyricsProviding {
    let lyrics: Lyrics
    private var calls = 0

    init(lyrics: Lyrics) {
        self.lyrics = lyrics
    }

    func resolveLyrics(for _: LyricsRequest, options _: LyricsOptions) async throws -> Lyrics? {
        calls += 1
        if calls == 1 { throw OnlineLyricsError.httpStatus(503) }
        return lyrics
    }
}

private final class CancellableLyricsProvider: LyricsProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var didStart = false
    private var didCancel = false

    var started: Bool { lock.withLock { didStart } }
    var cancelled: Bool { lock.withLock { didCancel } }

    func resolveLyrics(for _: LyricsRequest, options _: LyricsOptions) async throws -> Lyrics? {
        lock.withLock { didStart = true }
        do {
            try await Task.sleep(for: .seconds(60))
            return nil
        } catch {
            lock.withLock { didCancel = true }
            throw error
        }
    }
}
