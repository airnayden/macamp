// macamp-cli `loudness-mem` subcommand: bounded-memory verification for the R128
// batch loudness scan (plan `audiophile-suite`, todo 35 budget (b)).
//
//   loudness-mem --count <N> [--seconds <S>] [--rate <Hz>] [--page <N>]
//                [--dir <path>] [--keep] [--json]
//
// It generates N synthetic WAV files, inserts N `track` rows, and then runs the
// REAL `LoudnessScanService` + `LoudnessScanner` + `SFBDecoderProvider` over them
// while sampling Mach `phys_footprint` — the same metric Instruments' "Physical
// Footprint" shows, and the same one `scan --memory-ceiling` reports for the
// 100k-row import recorded in `.omo/evidence/task-13-100k-import.txt`.
//
// The scan is the thing under measurement, so the baseline is taken AFTER the
// fixtures and rows exist: `peak - baseline` is the scan's own cost, and it must
// not grow with N (the decode is windowed and the page loop is keyset-bounded).
//
// Darwin/Mach is used for the footprint probe — allowed in the CLI, forbidden
// inside PlayerCore.
import AVFAudio
import Darwin
import Decoding
import Foundation
import GRDB
import Persistence
import Services

// MARK: - options + report

private struct LoudnessMemoryOptions {
    var count = 1000
    var seconds = 2.0
    var sampleRate = 44100.0
    var pageSize = 50
    var directory: URL
    var json = false
    var keep = false
}

private struct LoudnessMemoryReport: Codable {
    let count: Int
    let pageSize: Int
    let toneSeconds: Double
    let sampleRate: Double
    let generateSeconds: Double
    let scanSeconds: Double
    let baselineFootprintBytes: UInt64
    let peakFootprintBytes: UInt64
    let scanDeltaBytes: UInt64
    let footprintSamples: Int
    let analyzedRows: Int
    let failedCount: Int
}

// MARK: - footprint probe

/// Current physical-memory footprint in bytes via Mach `TASK_VM_INFO`
/// (`phys_footprint`). Identical to the probe `scan --memory-ceiling` uses.
private func loudnessFootprintBytes() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
        MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
    )
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
        }
    }
    return result == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
}

/// Running maximum of `phys_footprint`, written by a sampling task and read once
/// the pass is over.
private final class FootprintSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var maximum: UInt64 = 0
    private var samples = 0

    func record() {
        let now = loudnessFootprintBytes()
        lock.withLock {
            maximum = max(maximum, now)
            samples += 1
        }
    }

    var peak: UInt64 {
        lock.withLock { maximum }
    }

    var sampleCount: Int {
        lock.withLock { samples }
    }
}

// MARK: - fixture generation

private func pcmSettings(sampleRate: Double) -> [String: Any] {
    [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: 2,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
    ]
}

/// Fills `buffer` with a stereo sine at `frequency`, peak `amplitude`.
private func fillTone(_ buffer: AVAudioPCMBuffer, frequency: Double, amplitude: Float) {
    guard let channels = buffer.floatChannelData else { return }
    let frames = Int(buffer.frameCapacity)
    let rate = buffer.format.sampleRate
    let step = 2.0 * Double.pi * frequency / rate
    for frame in 0 ..< frames {
        let value = amplitude * Float(sin(step * Double(frame)))
        channels[0][frame] = value
        channels[1][frame] = value
    }
    buffer.frameLength = AVAudioFrameCount(frames)
}

/// Writes `count` 16-bit stereo WAV tones into `directory`, reusing ONE float
/// buffer so generation itself cannot dominate the footprint being measured.
private func generateTones(_ options: LoudnessMemoryOptions) throws -> [URL] {
    try FileManager.default.createDirectory(at: options.directory, withIntermediateDirectories: true)
    let frames = AVAudioFrameCount((options.seconds * options.sampleRate).rounded())
    guard
        let format = AVAudioFormat(standardFormatWithSampleRate: options.sampleRate, channels: 2),
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
    else {
        throw LoudnessMemoryError(reason: "could not build a \(options.sampleRate) Hz stereo buffer")
    }
    let settings = pcmSettings(sampleRate: options.sampleRate)
    var urls: [URL] = []
    urls.reserveCapacity(options.count)
    for index in 0 ..< options.count {
        let url = options.directory.appendingPathComponent(String(format: "tone-%05d.wav", index))
        fillTone(buffer, frequency: 440 + Double(index % 64), amplitude: 0.5)
        let file = try AVAudioFile(forWriting: url, settings: settings)
        try file.write(from: buffer)
        urls.append(url)
    }
    return urls
}

private struct LoudnessMemoryError: Error, CustomStringConvertible {
    let reason: String

    var description: String {
        reason
    }
}

// MARK: - row insertion

private func trackRecord(for url: URL) -> TrackRecord {
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    let mtime = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
    let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    let name = url.deletingPathExtension().lastPathComponent
    return TrackRecord(
        filePath: url.path,
        title: name,
        sortTitle: name,
        fileSize: size,
        mtime: mtime,
        dateAdded: Date().timeIntervalSince1970
    )
}

private func insertRows(_ urls: [URL], into database: AppDatabase) throws {
    let repository = TrackRepository(database)
    var index = 0
    while index < urls.count {
        let end = min(index + 500, urls.count)
        _ = try repository.insertBatch(urls[index ..< end].map(trackRecord(for:)))
        index = end
    }
}

// MARK: - the measured pass

@MainActor
private func measureScan(
    _ options: LoudnessMemoryOptions,
    database: AppDatabase,
    sampler: FootprintSampler
) async -> (elapsed: Double, failed: Int) {
    let service = LoudnessScanService(
        database: database,
        scanner: LoudnessScanner(decoderProvider: SFBDecoderProvider()),
        pageSize: options.pageSize
    )
    service.onChange = { sampler.record() }
    let ticker = Task.detached(priority: .utility) {
        while !Task.isCancelled {
            sampler.record()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
    let started = DispatchTime.now()
    service.start()
    let deadline = ContinuousClock().now.advanced(by: .seconds(1800))
    while service.isRunning, ContinuousClock().now < deadline {
        try? await Task.sleep(for: .milliseconds(20))
    }
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds &- started.uptimeNanoseconds) / 1_000_000_000
    ticker.cancel()
    sampler.record()
    return (elapsed, service.failedCount)
}

private func analyzedRowCount(_ database: AppDatabase) -> Int {
    (try? database.writer.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM trackLoudness") ?? 0
    }) ?? 0
}

// MARK: - output

private func emitLoudnessMemory(_ report: LoudnessMemoryReport, json: Bool) {
    if json {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(report)) ?? Data()
        print(String(data: data, encoding: .utf8) ?? "{}")
        return
    }
    let mib = { (bytes: UInt64) in String(format: "%.2f MB", Double(bytes) / (1024 * 1024)) }
    print("count:       \(report.count) files (\(report.toneSeconds)s stereo @ \(Int(report.sampleRate)) Hz)")
    print("pageSize:    \(report.pageSize)")
    print("analyzed:    \(report.analyzedRows) rows (failed \(report.failedCount))")
    print(String(format: "generate:    %.3f s", report.generateSeconds))
    print(String(format: "scan:        %.3f s", report.scanSeconds))
    print("baseline:    \(mib(report.baselineFootprintBytes)) (\(report.baselineFootprintBytes) bytes)")
    print("peak:        \(mib(report.peakFootprintBytes)) (\(report.peakFootprintBytes) bytes)")
    print("scan delta:  \(mib(report.scanDeltaBytes)) (\(report.scanDeltaBytes) bytes)")
    print("samples:     \(report.footprintSamples)")
}

// MARK: - entry point

private func parseLoudnessMemoryOptions(_ args: [String]) -> LoudnessMemoryOptions {
    let fallback = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("macamp-loudness-mem-\(ProcessInfo.processInfo.processIdentifier)")
    var options = LoudnessMemoryOptions(directory: fallback)
    options.count = max(1, intFlag("--count", in: args) ?? options.count)
    options.seconds = max(0.5, doubleFlag("--seconds", in: args) ?? options.seconds)
    options.sampleRate = doubleFlag("--rate", in: args) ?? options.sampleRate
    options.pageSize = max(1, intFlag("--page", in: args) ?? options.pageSize)
    if let dir = flagValue("--dir", in: args) {
        options.directory = URL(fileURLWithPath: dir)
    }
    options.json = args.contains("--json")
    options.keep = args.contains("--keep")
    return options
}

@MainActor
private func runLoudnessMemoryPass(_ options: LoudnessMemoryOptions) async throws -> LoudnessMemoryReport {
    let generateStarted = DispatchTime.now()
    let urls = try generateTones(options)
    let generateSeconds =
        Double(DispatchTime.now().uptimeNanoseconds &- generateStarted.uptimeNanoseconds) / 1_000_000_000
    let dbURL = options.directory.appendingPathComponent("library.sqlite")
    let database = try AppDatabase(DatabaseQueue(path: dbURL.path))
    try insertRows(urls, into: database)
    let sampler = FootprintSampler()
    let baseline = loudnessFootprintBytes()
    sampler.record()
    let outcome = await measureScan(options, database: database, sampler: sampler)
    let peak = sampler.peak
    return LoudnessMemoryReport(
        count: options.count,
        pageSize: options.pageSize,
        toneSeconds: options.seconds,
        sampleRate: options.sampleRate,
        generateSeconds: generateSeconds,
        scanSeconds: outcome.elapsed,
        baselineFootprintBytes: baseline,
        peakFootprintBytes: peak,
        scanDeltaBytes: peak > baseline ? peak - baseline : 0,
        footprintSamples: sampler.sampleCount,
        analyzedRows: analyzedRowCount(database),
        failedCount: outcome.failed
    )
}

func runLoudnessMemory(_ args: [String]) {
    let options = parseLoudnessMemoryOptions(args)
    nonisolated(unsafe) var report: LoudnessMemoryReport?
    nonisolated(unsafe) var failure: (any Error)?
    Task { @MainActor in
        do {
            report = try await runLoudnessMemoryPass(options)
        } catch {
            failure = error
        }
        CFRunLoopStop(CFRunLoopGetMain())
    }
    CFRunLoopRun()
    if !options.keep {
        try? FileManager.default.removeItem(at: options.directory)
    }
    if let failure {
        fail("\(failure)")
    }
    guard let report else {
        fail("loudness-mem produced no report")
    }
    emitLoudnessMemory(report, json: options.json)
}
