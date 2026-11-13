// macamp-cli `zeroalloc` subcommand: a differential `malloc_zone_statistics`
// probe for the metering tap path (plan `audiophile-suite`, todo 35 budget (c)).
//
//   zeroalloc [--iterations <N>] [--pulls <N>] [--json]
//
// The package's own `ZeroAllocTapTests` / `StereoTapAllocationTests` /
// `CrossfeedTests` assert the same invariant, but Swift Testing only prints the
// measured block delta when an expectation FAILS — a green run records no number.
// This probe reports the numbers, so a budget verification can quote them.
//
// It drives the PUBLIC half of the tap body: `SpectrumProvider.ingest` (ch0) plus
// `ingestChannel1` (ch1), which is exactly what the internal, `@testable`-only
// `SFBPlaybackEngine.ingest(_:into:)` performs once its `floatChannelData` and
// `format.channelCount >= 2` guards have passed. The consumer-side
// `StereoPeakMeter.read` pull is measured separately — it runs on the UI cadence,
// not the render thread, but it must stay allocation-free for the 60 Hz pull to
// be free.
//
// `malloc_zone_statistics` counts the whole PROCESS, so every measurement window
// is paired with an ambient control window of the same iteration count; the
// reported verdict compares `delta - ambient` against the budget the matching
// test uses (4096 blocks for the tap, 256 for a kernel loop).
import AVFAudio
import Darwin
import DSP
import Foundation

// MARK: - report

private struct ZeroAllocReport: Codable {
    let iterations: Int
    let pulls: Int
    let frameCount: Int
    let ambientBlocks: Int
    let ingestBlocks: Int
    let ingestExcessBlocks: Int
    let pullAmbientBlocks: Int
    let pullBlocks: Int
    let pullExcessBlocks: Int
    let tapBudgetBlocks: Int
    let passed: Bool
}

private struct ZeroAllocError: Error, CustomStringConvertible {
    let reason: String

    var description: String {
        reason
    }
}

private func zeroAllocBlocksInUse() -> Int {
    var stats = malloc_statistics_t()
    malloc_zone_statistics(malloc_default_zone(), &stats)
    return Int(stats.blocks_in_use)
}

/// An arithmetic-only window of the same length as a measured window, so the
/// ambient allocation traffic of the rest of the process can be subtracted.
private func ambientBlocks(iterations: Int) -> Int {
    var sink = 0
    let started = zeroAllocBlocksInUse()
    for index in 0 ..< iterations {
        sink = sink &+ (index & 1)
    }
    let delta = zeroAllocBlocksInUse() - started
    _ = sink
    return delta
}

// MARK: - fixtures

private func stereoToneBuffer(frameCount: Int) throws -> AVAudioPCMBuffer {
    guard
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2),
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))
    else {
        throw ZeroAllocError(reason: "could not build a 44.1 kHz stereo tap buffer")
    }
    buffer.frameLength = AVAudioFrameCount(frameCount)
    guard let channels = buffer.floatChannelData else {
        throw ZeroAllocError(reason: "tap buffer carries no float channel data")
    }
    for frame in 0 ..< frameCount {
        let phase = 2.0 * Double.pi * 997.0 * Double(frame) / 44100.0
        channels[0][frame] = 0.5 * Float(sin(phase))
        channels[1][frame] = 0.25 * Float(sin(phase))
    }
    return buffer
}

/// The public half of the render-thread tap body: one memcpy per metered channel
/// into its own pre-allocated lock-free ring.
private func ingestBothChannels(_ buffer: AVAudioPCMBuffer, into provider: SpectrumProvider) {
    guard let channels = buffer.floatChannelData else { return }
    let frames = Int(buffer.frameLength)
    provider.ingest(channels[0], count: frames)
    guard buffer.format.channelCount >= 2 else { return }
    provider.ingestChannel1(channels[1], count: frames)
}

// MARK: - measurement

private func measureTapIngest(
    _ buffer: AVAudioPCMBuffer,
    provider: SpectrumProvider,
    iterations: Int
) -> (ambient: Int, delta: Int) {
    for _ in 0 ..< 2000 {
        ingestBothChannels(buffer, into: provider)
    }
    let ambient = ambientBlocks(iterations: iterations)
    let started = zeroAllocBlocksInUse()
    for _ in 0 ..< iterations {
        ingestBothChannels(buffer, into: provider)
    }
    return (ambient, zeroAllocBlocksInUse() - started)
}

private func measureMeterPull(
    _ provider: SpectrumProvider,
    meter: StereoPeakMeter,
    pulls: Int
) -> (ambient: Int, delta: Int) {
    for _ in 0 ..< 100 {
        meter.read(from: provider, channelCount: 2)
    }
    let ambient = ambientBlocks(iterations: pulls)
    let started = zeroAllocBlocksInUse()
    for _ in 0 ..< pulls {
        meter.read(from: provider, channelCount: 2)
    }
    return (ambient, zeroAllocBlocksInUse() - started)
}

// MARK: - output

private func emitZeroAlloc(_ report: ZeroAllocReport, json: Bool) {
    if json {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(report)) ?? Data()
        print(String(data: data, encoding: .utf8) ?? "{}")
        return
    }
    print("frames/call:   \(report.frameCount) (stereo, 44100 Hz)")
    print("iterations:    \(report.iterations) tap ingests")
    print("ambient:       \(report.ambientBlocks) blocks (control window)")
    print("ingest:        \(report.ingestBlocks) blocks")
    print("ingest excess: \(report.ingestExcessBlocks) blocks (budget \(report.tapBudgetBlocks))")
    print("pulls:         \(report.pulls) StereoPeakMeter.read")
    print("pull ambient:  \(report.pullAmbientBlocks) blocks")
    print("pull:          \(report.pullBlocks) blocks")
    print("pull excess:   \(report.pullExcessBlocks) blocks (budget \(report.tapBudgetBlocks))")
    print("RESULT:        \(report.passed ? "PASS" : "FAIL")")
}

// MARK: - entry point

func runZeroAlloc(_ args: [String]) {
    let iterations = max(1, intFlag("--iterations", in: args) ?? 200_000)
    let pulls = max(1, intFlag("--pulls", in: args) ?? 20000)
    let frameCount = max(1, intFlag("--frames", in: args) ?? 1024)
    let budget = 4096
    do {
        let provider = SpectrumProvider()
        let buffer = try stereoToneBuffer(frameCount: frameCount)
        let tap = measureTapIngest(buffer, provider: provider, iterations: iterations)
        let meter = StereoPeakMeter()
        let pull = measureMeterPull(provider, meter: meter, pulls: pulls)
        let tapExcess = tap.delta - max(tap.ambient, 0)
        let pullExcess = pull.delta - max(pull.ambient, 0)
        let report = ZeroAllocReport(
            iterations: iterations,
            pulls: pulls,
            frameCount: frameCount,
            ambientBlocks: tap.ambient,
            ingestBlocks: tap.delta,
            ingestExcessBlocks: tapExcess,
            pullAmbientBlocks: pull.ambient,
            pullBlocks: pull.delta,
            pullExcessBlocks: pullExcess,
            tapBudgetBlocks: budget,
            passed: tapExcess <= budget && pullExcess <= budget
        )
        emitZeroAlloc(report, json: args.contains("--json"))
        if !report.passed {
            exit(4)
        }
    } catch {
        fail("\(error)")
    }
}
