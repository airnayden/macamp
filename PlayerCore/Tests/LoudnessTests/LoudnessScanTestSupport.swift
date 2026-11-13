// Shared helpers + doubles for the LoudnessScanner / LoudnessScanService suites.
//
// `PlanarBufferDecoderProvider` is the reason this file exists: the shipped
// `BufferDecoderProvider` serves ONE mono channel, and BS.1770-4 measures mono
// exactly 10·log10(2) = 3.0103 dB below dual-mono, so every reference figure in
// the spec (a −23 dBFS sine reads −23.0 LUFS) needs a genuinely STEREO decoder.
// It also keys fixtures by path, so an album's members can carry different audio
// and an unregistered path models an undecodable file.
import AVFAudio
import Decoding
import Foundation
import GRDB
import Persistence
import PlayerCoreTestSupport
import Services

// MARK: - Waiting

@MainActor
func pollUntil(timeout: Duration = .seconds(30), _ condition: () -> Bool) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
        if clock.now >= deadline { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
}

// MARK: - Tones

enum ScanFixtures {
    static let sampleRate = 48000.0

    /// The fixed instant the injected clock reports, so `computedAt` is exactly
    /// assertable instead of "roughly now".
    static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    /// The fingerprint every freshly-inserted fixture track carries.
    static let fileSize: Int64 = 4096
    static let mtime = 200.0

    /// A dual-mono tone at `dBFS` peak — the shape every BS.1770-4 reference
    /// figure is quoted for.
    static func stereoTone(dBFS: Double, seconds: Double) -> [[Float]] {
        let channel = LoudnessFixtures.tone(dBFS: dBFS, seconds: seconds, sampleRate: sampleRate)
        return [channel, channel]
    }

    /// `silenceSeconds` of digital silence spliced between two equal halves of a
    /// `dBFS` tone — the fixture that proves silent blocks are DROPPED rather
    /// than binned (binning `-infinity` traps; clamping it into bin 0 would drag
    /// the answer down).
    static func stereoToneWithSilenceSplice(
        dBFS: Double,
        toneSeconds: Double,
        silenceSeconds: Double
    ) -> [[Float]] {
        let half = LoudnessFixtures.tone(dBFS: dBFS, seconds: toneSeconds / 2, sampleRate: sampleRate)
        let gap = LoudnessFixtures.silence(seconds: silenceSeconds, sampleRate: sampleRate)
        let channel = half + gap + half
        return [channel, channel]
    }
}

// MARK: - Planar decoder double

/// Counts calls across every decoder a (value-semantics) provider vended.
final class ScanCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock { count += 1 }
    }

    func reset() {
        lock.withLock { count = 0 }
    }
}

/// A ``DecoderProviding`` that replays registered planar sample arrays, keyed by
/// file path, and counts opens and decodes.
///
/// An UNREGISTERED path throws — which is how a suite models an undecodable
/// album member without shipping a corrupt binary fixture.
final class PlanarBufferDecoderProvider: DecoderProviding, @unchecked Sendable {
    let sampleRate: Double

    private let lock = NSLock()
    private var registry: [String: [[Float]]] = [:]
    private let opens = ScanCallCounter()
    private let decodes = ScanCallCounter()

    init(sampleRate: Double = ScanFixtures.sampleRate) {
        self.sampleRate = sampleRate
    }

    func register(_ channels: [[Float]], forPath path: String) {
        lock.withLock { registry[path] = channels }
    }

    func makeDecoder(for url: URL) throws -> any PCMDecoding {
        opens.increment()
        guard let channels = lock.withLock({ registry[url.path] }) else {
            throw DecodingError.ioError(url: url, underlying: "no fixture registered")
        }
        return PlanarBufferDecoder(channels: channels, sampleRate: sampleRate, counter: decodes)
    }

    var openCount: Int {
        opens.value
    }

    var decodeCallCount: Int {
        decodes.value
    }

    func resetCounts() {
        opens.reset()
        decodes.reset()
    }

    static let supportedPathExtensions: Set<String> = ["flac", "wav", "aiff", "mp3", "caf"]
    static let supportedMIMETypes: Set<String> = ["audio/flac", "audio/wav", "audio/mpeg"]
}

/// A ``PCMDecoding`` that reads sequentially out of fixed planar sample arrays.
final class PlanarBufferDecoder: PCMDecoding {
    let processingFormat: AVAudioFormat
    let sourceFormat: AVAudioFormat? = nil
    let frameLength: AVAudioFramePosition
    private(set) var framePosition: AVAudioFramePosition = 0
    let supportsSeeking = true

    private let channels: [[Float]]
    private let counter: ScanCallCounter

    init(channels: [[Float]], sampleRate: Double, counter: ScanCallCounter) {
        let channelCount = AVAudioChannelCount(max(channels.count, 1))
        guard
            let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channelCount)
        else {
            fatalError("standard float format unconstructible at \(sampleRate) Hz / \(channelCount) ch")
        }
        processingFormat = format
        frameLength = AVAudioFramePosition(channels.map(\.count).min() ?? 0)
        self.channels = channels
        self.counter = counter
    }

    @discardableResult
    func decode(into buffer: AVAudioPCMBuffer, frameLength frames: AVAudioFrameCount) throws -> AVAudioFrameCount {
        counter.increment()
        let remaining = frameLength - framePosition
        guard remaining > 0, let data = buffer.floatChannelData else {
            buffer.frameLength = 0
            return 0
        }
        let produce = min(Int(frames), Int(buffer.frameCapacity), Int(remaining))
        let start = Int(framePosition)
        for channel in 0 ..< channels.count {
            channels[channel].withUnsafeBufferPointer { source in
                guard let base = source.baseAddress else { return }
                data[channel].update(from: base + start, count: produce)
            }
        }
        buffer.frameLength = AVAudioFrameCount(produce)
        framePosition += AVAudioFramePosition(produce)
        return AVAudioFrameCount(produce)
    }

    @discardableResult
    func seek(toFrame frame: AVAudioFramePosition) throws -> AVAudioFramePosition {
        framePosition = max(0, min(frame, frameLength))
        return framePosition
    }
}

// MARK: - Scanner doubles

/// A ``LoudnessMeasuring`` that serves `blockAfter` scans immediately, then
/// suspends on a long, cancellable sleep.
///
/// Lets a test prove rows committed before a ``LoudnessScanService/stop()``
/// survive it, with no reliance on timing.
final class BlockingLoudnessScanner: LoudnessMeasuring, @unchecked Sendable {
    private let result: LoudnessScanResult
    private let blockAfter: Int
    private let lock = NSLock()
    private var requested: [URL] = []

    init(returning result: LoudnessScanResult = ScanResultFixtures.quiet, blockAfter: Int = 2) {
        self.result = result
        self.blockAfter = blockAfter
    }

    var requestedURLs: [URL] {
        lock.withLock { requested }
    }

    var scanCallCount: Int {
        lock.withLock { requested.count }
    }

    func measureLoudness(of url: URL) async throws -> LoudnessScanResult {
        let ordinal = lock.withLock { () -> Int in
            requested.append(url)
            return requested.count
        }
        if ordinal > blockAfter {
            try await Task.sleep(for: .seconds(60))
        }
        return result
    }
}

/// A ``LoudnessMeasuring`` that returns a canned result per path (and throws for
/// any path it was not given), so a suite can drive the batch service's grouping
/// and failure rules without decoding anything.
final class StubLoudnessScanner: LoudnessMeasuring, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [String: LoudnessScanResult] = [:]
    private var requested: [URL] = []

    func stub(_ result: LoudnessScanResult, forPath path: String) {
        lock.withLock { results[path] = result }
    }

    var scanCallCount: Int {
        lock.withLock { requested.count }
    }

    func measureLoudness(of url: URL) async throws -> LoudnessScanResult {
        let result = lock.withLock { () -> LoudnessScanResult? in
            requested.append(url)
            return results[url.path]
        }
        guard let result else {
            throw LoudnessScanError.decodeFailed(url: url, reason: "no stub registered")
        }
        return result
    }
}

enum ScanResultFixtures {
    /// A measurement whose blocks all sit at −23 LKFS — the reference level.
    static let quiet = make(loudness: -23, blocks: 50, truePeak: 0.0708)

    /// Every block at `loudness`, which makes the integrated figure equal to it
    /// (the relative gate removes nothing from a flat set).
    static func make(loudness: Double, blocks: Int, truePeak: Double) -> LoudnessScanResult {
        let set = [Double](repeating: loudness, count: blocks)
        return LoudnessScanResult(
            integratedLUFS: LoudnessGating.integratedLoudness(ofAbsoluteGatedBlocks: set),
            truePeak: truePeak,
            gatedBlockLoudness: set,
            blockCount: blocks
        )
    }
}

// MARK: - Database fixtures

/// A warm-up that opens nothing — the production one builds a real SFB decoder
/// from a real file, which no hermetic suite has.
let inertWarmUp: @Sendable (URL) async throws -> Void = { _ in }

@discardableResult
func insertScanTrack(
    _ database: AppDatabase,
    path: String,
    albumId: Int64? = nil,
    availability: Availability = .present,
    fileSize: Int64? = ScanFixtures.fileSize,
    mtime: Double? = ScanFixtures.mtime
) throws -> TrackRecord {
    try TrackRepository(database).insert(
        TrackRecord(
            filePath: path,
            title: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
            albumId: albumId,
            fileSize: fileSize,
            mtime: mtime,
            availability: availability
        )
    )
}

/// Raised when a fixture could not be built — never by the code under test.
struct FixtureError: Error {
    let reason: String
}

@discardableResult
func insertAlbum(_ database: AppDatabase, title: String) throws -> Int64 {
    let album = try AlbumRepository(database).insert(AlbumRecord(title: title, sortTitle: title))
    guard let id = album.id else {
        throw FixtureError(reason: "album \(title) did not receive a rowid")
    }
    return id
}

func fetchLoudness(_ database: AppDatabase, trackId: Int64) throws -> TrackLoudnessRecord? {
    try database.writer.read { db in try TrackLoudnessRecord.fetchOne(db, key: trackId) }
}

func loudnessRowCount(_ database: AppDatabase) throws -> Int {
    try database.writer.read { db in try TrackLoudnessRecord.fetchCount(db) }
}

func requireLoudness(_ database: AppDatabase, trackId: Int64) throws -> TrackLoudnessRecord {
    guard let row = try fetchLoudness(database, trackId: trackId) else {
        throw FixtureError(reason: "no trackLoudness row for track \(trackId)")
    }
    return row
}

func allLoudnessRows(_ database: AppDatabase) throws -> [TrackLoudnessRecord] {
    try database.writer.read { db in try TrackLoudnessRecord.fetchAll(db) }
}

func simulateFileRewrite(_ database: AppDatabase, trackId: Int64, newMtime: Double) throws {
    try database.writer.write { db in
        try db.execute(sql: "UPDATE track SET mtime = ? WHERE id = ?", arguments: [newMtime, trackId])
    }
}

@MainActor
func makeScanService(
    _ database: AppDatabase,
    _ scanner: any LoudnessMeasuring,
    pageSize: Int = 50
) -> LoudnessScanService {
    LoudnessScanService(
        database: database,
        scanner: scanner,
        now: { ScanFixtures.epoch },
        pageSize: pageSize,
        warmUpOpen: inertWarmUp
    )
}
