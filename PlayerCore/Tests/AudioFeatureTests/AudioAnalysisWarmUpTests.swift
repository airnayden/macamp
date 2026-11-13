// AudioAnalysisWarmUpTests — the one-shot decoder warm-up that precedes a page.
//
// A page fans out `concurrencyCap` extractions, and the first MP3 decoder each
// of them builds enters mpg123's process-global, non-thread-safe initialisation.
// The service therefore opens ONE decoder serially first. What these cases pin is
// the part that is easy to get subtly wrong and impossible to notice: WHICH
// candidate is chosen (only an MPEG-family file initialises mpg123), WHERE the
// open runs (never the main actor), and WHEN the one-shot is considered spent.
//
// The warm-up is observed through the injected `warmUpOpen` seam rather than by
// watching a decoder appear, so no case here needs an audio fixture — except the
// last, which drives the REAL provider through the REAL gate on a deliberately
// corrupt file.
import Decoding
import Foundation
import Persistence
import PlayerCoreTestSupport
import Services
import Testing

@MainActor
@Suite("AudioAnalysisWarmUpTests")
struct AudioAnalysisWarmUpTests {
    @Test("the first MPEG-family candidate is warmed, not simply the first candidate")
    func warmsTheFirstMPEGCandidate() async throws {
        let database = try AppDatabase.makeEmpty()
        try insertTrack(database, path: "/music/a.flac")
        try insertTrack(database, path: "/music/b.m4a")
        try insertTrack(database, path: "/music/c.mp3")
        try insertTrack(database, path: "/music/d.mp3")
        let recorder = WarmUpRecorder()
        let service = makeService(database, recorder)

        service.start()
        await pollUntil { !service.isRunning }

        #expect(recorder.openedURLs == [URL(fileURLWithPath: "/music/c.mp3")])
        #expect(service.didWarmUpDecoder)
        #expect(service.progress.completed == 4)
    }

    /// A page with nothing mpg123 would decode still warms — the format registry's
    /// own `dispatch_once` is worth tripping — but it must NOT spend the one-shot,
    /// or the first MP3 the library reaches later would never be warmed at all.
    @Test("an MPEG-less page warms its first candidate without spending the one-shot")
    func mpegLessPageDoesNotSpendTheOneShot() async throws {
        let database = try AppDatabase.makeEmpty()
        try insertTracks(database, count: 3)
        let recorder = WarmUpRecorder()
        let service = makeService(database, recorder)

        service.start()
        await pollUntil { !service.isRunning }

        #expect(recorder.openedURLs == [URL(fileURLWithPath: "/music/track-1.flac")])
        #expect(service.didWarmUpDecoder == false)
    }

    @Test("the warm-up runs once across several MPEG-bearing pages")
    func warmsExactlyOnceAcrossPages() async throws {
        let database = try AppDatabase.makeEmpty()
        for index in 1 ... 4 {
            try insertTrack(database, path: "/music/track-\(index).mp3")
        }
        let recorder = WarmUpRecorder()
        let service = makeService(database, recorder, pageSize: 2)

        service.start()
        await pollUntil { !service.isRunning }

        #expect(recorder.openedURLs == [URL(fileURLWithPath: "/music/track-1.mp3")])
        #expect(service.progress.completed == 4)
    }

    /// The service is `@MainActor`, so a warm-up that forgot to hop would put a
    /// synchronous file open on the actor driving the UI.
    @Test("the warm-up open never runs on the main actor")
    func warmUpRunsOffTheMainActor() async throws {
        let database = try AppDatabase.makeEmpty()
        try insertTrack(database, path: "/music/only.mp3")
        let recorder = WarmUpRecorder()
        let service = makeService(database, recorder)

        service.start()
        await pollUntil { !service.isRunning }

        #expect(recorder.openedURLs.isEmpty == false)
        #expect(recorder.mainThreadOpenCount == 0)
    }

    /// The decided failure semantics. A `try?` that set the flag anyway would mark
    /// the warm-up done WITHOUT having initialised mpg123 — the fix would be off
    /// for the rest of the run, and nothing would say so.
    @Test("a throwing warm-up leaves the one-shot unspent and the next page retries")
    func throwingWarmUpIsRetriedOnTheNextPage() async throws {
        let database = try AppDatabase.makeEmpty()
        for index in 1 ... 4 {
            try insertTrack(database, path: "/music/track-\(index).mp3")
        }
        let first = URL(fileURLWithPath: "/music/track-1.mp3")
        let recorder = WarmUpRecorder(failing: [first])
        let service = makeService(database, recorder, pageSize: 2)

        service.start()
        await pollUntil { !service.isRunning }

        #expect(recorder.openedURLs == [first, URL(fileURLWithPath: "/music/track-3.mp3")])
        #expect(service.didWarmUpDecoder, "a later page never re-attempted the warm-up")
        #expect(service.progress.completed == 4)
        #expect(service.failedCount == 0, "a failed warm-up was tallied as a failed track")
    }

    /// End to end on the production seams: the real `SFBDecoderProvider`, the real
    /// `DecoderOpenGate`, the real `liveWarmUpOpen`, and a file that is not an MP3
    /// at all. Both the warm-up and the extraction must fail SOFTLY.
    @Test("a corrupt MPEG file is tallied through the real gate and the page still finishes")
    func corruptMPEGFileIsTalliedNotFatal() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macamp-warmup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let corrupt = directory.appendingPathComponent("not-really-audio.mp3")
        try Data("this is plain text, not an MPEG frame".utf8).write(to: corrupt)

        let database = try AppDatabase.makeEmpty()
        try insertTrack(database, path: corrupt.path)
        let service = AudioAnalysisService(
            database: database,
            extractor: AudioFeatureExtractor(decoderProvider: SFBDecoderProvider()),
            now: { FeatureFixtures.epoch }
        )

        service.start()
        await pollUntil { !service.isRunning }

        #expect(service.failedCount == 1)
        #expect(service.progress.completed == 1)
        #expect(service.didWarmUpDecoder == false, "an unreadable file spent the one-shot")
        #expect(try featureCount(database) == 0)
    }
}

// MARK: - Construction

private extension AudioAnalysisWarmUpTests {
    func makeService(
        _ database: AppDatabase,
        _ recorder: WarmUpRecorder,
        pageSize: Int = 50
    ) -> AudioAnalysisService {
        AudioAnalysisService(
            database: database,
            extractor: ConcurrencyRecordingExtractor(),
            now: { FeatureFixtures.epoch },
            pageSize: pageSize,
            warmUpOpen: recorder.warmUpOpen
        )
    }
}

// MARK: - Doubles

/// Stands in for the production warm-up, recording every URL it was handed and
/// whether it was called on the main thread.
///
/// `@unchecked Sendable` over an `NSLock`, the `ConcurrencyRecordingExtractor`
/// shape: the closure is invoked from a detached task and read from the main
/// actor.
final class WarmUpRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let failing: Set<URL>
    private var opened: [URL] = []
    private var mainThreadOpens = 0

    /// - Parameter failing: URLs the warm-up throws on, standing in for a file
    ///   the decoder cannot open.
    init(failing: Set<URL> = []) {
        self.failing = failing
    }

    var warmUpOpen: @Sendable (URL) async throws -> Void {
        { [self] url in try record(url) }
    }

    var openedURLs: [URL] {
        lock.withLock { opened }
    }

    var mainThreadOpenCount: Int {
        lock.withLock { mainThreadOpens }
    }

    private func record(_ url: URL) throws {
        let onMainThread = Thread.isMainThread
        lock.withLock {
            opened.append(url)
            if onMainThread { mainThreadOpens += 1 }
        }
        if failing.contains(url) {
            throw AudioFeatureError.decodeFailed(url: url, reason: "warm-up fixture")
        }
    }
}
