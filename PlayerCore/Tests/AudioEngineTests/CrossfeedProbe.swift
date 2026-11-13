@testable import AudioEngine
import AVFAudio
import Darwin
import Foundation
import Testing

/// Shared rig for the crossfeed node suites: the probe signal, the measurement,
/// and the INDEPENDENT oracle every level assertion is checked against.
///
/// The oracle is todo 6's committed libbs2b 3.1.0 impulse responses, read from
/// the SAME artifacts `DSPTests` reads (`tools/fixtures/bs2b/vectors/`) and
/// located by `#filePath`. A second copy inside this target could drift, and a
/// node that mis-rendered would then still "match" its fixture.
enum CrossfeedProbe {
    /// The rate every case runs at — the SAME rate the committed vectors were
    /// generated at, which is what makes them usable as an oracle.
    static let sampleRate = 44100.0

    /// Peak amplitude of the left-only probe tone. Low enough that the direct
    /// path's high-boost cannot clip, high enough that the crossfed channel at
    /// 10 kHz (some 31 dB down) stays far above float32 noise.
    static let amplitude: Float = 0.5

    /// Seconds discarded from the front of every measurement.
    ///
    /// The one-pole filters settle in tens of samples, but the engine's opening
    /// blocks also carry the graph's own start-up, and a tone measured across
    /// that is not a steady-state reading.
    static let settlingSeconds = 0.2

    static func stereoFormat(_ rate: Double = sampleRate) throws -> AVAudioFormat {
        try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
    }

    /// A stereo source whose LEFT channel carries a sine and whose RIGHT channel
    /// is digital silence — the same excitation shape as the reference vectors,
    /// so the right channel of the result is purely crossfed signal.
    static func leftOnlySine(format: AVAudioFormat, frequency: Double) -> AVAudioSourceNode {
        let cursor = FrameCursor()
        let rate = format.sampleRate
        let block: AVAudioSourceNodeRenderBlock = { _, _, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let start = cursor.advance(by: Int(frameCount))
            for bufferIndex in 0 ..< buffers.count {
                let samples = UnsafeMutableBufferPointer<Float>(buffers[bufferIndex])
                for frame in 0 ..< Int(frameCount) {
                    let phase = 2.0 * Double.pi * frequency * Double(start + frame) / rate
                    samples[frame] = bufferIndex == 0 ? amplitude * Float(sin(phase)) : 0
                }
            }
            return noErr
        }
        return AVAudioSourceNode(format: format, renderBlock: block)
    }

    /// RMS of one channel over the steady-state tail of `buffer`.
    static func steadyStateRMS(_ buffer: AVAudioPCMBuffer, channel: Int) throws -> Double {
        let channels = try #require(buffer.floatChannelData)
        let skip = Int(settlingSeconds * sampleRate)
        let count = Int(buffer.frameLength) - skip
        guard channel < Int(buffer.format.channelCount), count > 0 else { return 0 }
        let samples = channels[channel]
        var sumOfSquares = 0.0
        for frame in skip ..< (skip + count) {
            sumOfSquares += Double(samples[frame]) * Double(samples[frame])
        }
        return (sumOfSquares / Double(count)).squareRoot()
    }

    /// Every sample of `buffer`, channel-major — the currency of the
    /// bit-identity comparison.
    static func samples(_ buffer: AVAudioPCMBuffer) throws -> [[Float]] {
        let channels = try #require(buffer.floatChannelData)
        let frames = Int(buffer.frameLength)
        return (0 ..< Int(buffer.format.channelCount)).map { channel in
            Array(UnsafeBufferPointer(start: channels[channel], count: frames))
        }
    }

    static func decibels(_ linear: Double) -> Double {
        linear > 0 ? 20 * log10(linear) : -.infinity
    }

    // MARK: Oracle

    private static let vectorDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("tools/fixtures/bs2b/vectors", isDirectory: true)

    /// The reference RIGHT-channel response to a left-only unit impulse — the
    /// crossfed path, which is what every level assertion measures.
    static func crossfedImpulseResponse(preset: String) throws -> [Double] {
        let url = vectorDirectory.appendingPathComponent("\(preset)-44100.csv")
        let text = try String(contentsOf: url, encoding: .utf8)
        var response: [Double] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("#") || line.hasPrefix("n,") { continue }
            let columns = line.split(separator: ",")
            guard columns.count == 3, let right = Double(columns[2]) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            response.append(right)
        }
        return response
    }

    /// Magnitude of `response`'s DTFT at `frequency` — the steady-state level the
    /// filter presents to that tone, derived from the impulse response alone.
    ///
    /// This never runs MacAMP's kernel, so agreement means the node reproduces
    /// libbs2b's own measured response rather than merely reproducing itself.
    static func responseMagnitude(_ response: [Double], at frequency: Double) -> Double {
        var real = 0.0
        var imaginary = 0.0
        for (index, sample) in response.enumerated() {
            let angle = -2.0 * .pi * frequency * Double(index) / sampleRate
            real += sample * cos(angle)
            imaginary += sample * sin(angle)
        }
        return (real * real + imaginary * imaginary).squareRoot()
    }

    /// Process-global `malloc` block count — the differential the audio-thread
    /// allocation assertion is built on.
    static func mallocBlocksInUse() -> Int {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(malloc_default_zone(), &stats)
        return Int(stats.blocks_in_use)
    }

    /// Heap-block growth over `iterations` calls of `work`, paired with an ambient
    /// control measured over the same wall-clock span.
    ///
    /// `blocks_in_use` is PROCESS-GLOBAL, so the measured window also counts whatever
    /// other suites allocate while it runs. Subtracting a control window is only
    /// sound when that window spans the same DURATION: concurrent suites allocate as
    /// a function of time, not of this loop's iteration count, so an integer-add
    /// control matched only on iteration count finishes ~1000x sooner and subtracts
    /// almost none of the noise it exists to subtract (measured: 1549 blocks against
    /// a 1-block control). Those suites also allocate in BURSTS, so one control
    /// window can miss the burst the work window absorbed — both sides are sampled
    /// and the larger wins.
    ///
    /// A per-call allocation regression adds at least `iterations` blocks, which no
    /// ambient margin this side of the iteration count can mask.
    static func allocationProbe(iterations: Int, _ work: () -> Void) -> (measured: Int, ambient: Int) {
        let warmUp = 100
        let warmUpBegan = DispatchTime.now().uptimeNanoseconds
        for _ in 0 ..< warmUp {
            work()
        }
        let span = (DispatchTime.now().uptimeNanoseconds - warmUpBegan) / UInt64(warmUp) * UInt64(iterations)

        let ambientBefore = ambientBlocks(over: span)
        let start = mallocBlocksInUse()
        for _ in 0 ..< iterations {
            work()
        }
        let measured = mallocBlocksInUse() - start
        return (measured, max(ambientBefore, ambientBlocks(over: span)))
    }

    private static func ambientBlocks(over nanoseconds: UInt64) -> Int {
        var sink = 0
        let start = mallocBlocksInUse()
        let began = DispatchTime.now().uptimeNanoseconds
        while DispatchTime.now().uptimeNanoseconds - began < nanoseconds {
            sink = sink &+ 1
        }
        _ = sink
        return mallocBlocksInUse() - start
    }

    /// Running frame index for the probe generator, so phase stays continuous
    /// across render blocks of any size.
    private final class FrameCursor: @unchecked Sendable {
        private var index = 0

        func advance(by count: Int) -> Int {
            let start = index
            index += count
            return start
        }
    }
}
