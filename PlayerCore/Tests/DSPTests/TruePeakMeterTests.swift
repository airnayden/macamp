import Darwin
@testable import DSP
import Foundation
import Testing

// MARK: Fixtures

/// `amplitude · sin(2π·frequency·n/sampleRate + phase)` for `seconds` of audio.
private func sine(
    frequency: Double,
    sampleRate: Double,
    seconds: Double,
    amplitude: Float = 1,
    phase: Double = 0
) -> [Float] {
    let count = Int((sampleRate * seconds).rounded())
    let increment = 2 * Double.pi * frequency / sampleRate
    return (0 ..< count).map { amplitude * Float(sin(increment * Double($0) + phase)) }
}

/// A deterministic pseudo-random block in `[-amplitude, amplitude)`.
private func noise(count: Int, amplitude: Float = 0.7, seed: UInt64 = 0x2545_F491_4F6C_DD1D) -> [Float] {
    var state = seed
    return (0 ..< count).map { _ in
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        let unit = Float(state >> 11) / Float(UInt64(1) << 53)
        return amplitude * (unit * 2 - 1)
    }
}

/// The straight-line transcription of the Annex 2 convolution, written against
/// the published table rather than against the meter's vDSP correlation, so a
/// sign or ordering slip in the meter cannot hide behind a matching reference.
///
/// Pre-history reads as zero, matching a freshly reset meter.
private func referenceTruePeak(_ samples: [Float]) -> Float {
    var peak: Float = 0
    for phase in TruePeakFilter.phases {
        for index in samples.indices {
            var accumulator: Float = 0
            for (tapIndex, tap) in phase.enumerated() where index - tapIndex >= 0 {
                accumulator += tap * samples[index - tapIndex]
            }
            peak = max(peak, abs(accumulator))
        }
    }
    return peak
}

private func samplePeak(_ samples: [Float]) -> Float {
    samples.reduce(0) { max($0, abs($1)) }
}

@discardableResult
private func feed(_ meter: TruePeakMeter, _ samples: [Float], channel: Int = 0) -> TruePeakMeasurement {
    samples.withUnsafeBufferPointer { meter.process($0, channel: channel) }
}

private func mallocBlocksInUse() -> Int {
    var stats = malloc_statistics_t()
    malloc_zone_statistics(malloc_default_zone(), &stats)
    return Int(stats.blocks_in_use)
}

// MARK: Tests

@Suite(.serialized)
struct TruePeakMeterTests {
    // MARK: Coefficient table

    @Test func phaseTableMatchesPublishedTaps() {
        // An independent copy of BS.1770-4 Annex 2, Table 3 — if either list is
        // edited, this is the assertion that has to be edited with it.
        let phase0: [Float] = [
            0.0017089843750, 0.0109863281250, -0.0196533203125, 0.0332031250000,
            -0.0594482421875, 0.1373291015625, 0.9721679687500, -0.1022949218750,
            0.0476074218750, -0.0266113281250, 0.0148925781250, -0.0083007812500,
        ]
        let phase1: [Float] = [
            -0.0291748046875, 0.0292968750000, -0.0517578125000, 0.0891113281250,
            -0.1665039062500, 0.4650878906250, 0.7797851562500, -0.2003173828125,
            0.1015625000000, -0.0582275390625, 0.0330810546875, -0.0189208984375,
        ]
        #expect(TruePeakFilter.phases.count == TruePeakFilter.oversamplingFactor)
        #expect(TruePeakFilter.phases.allSatisfy { $0.count == TruePeakFilter.tapsPerPhase })
        #expect(TruePeakFilter.phases[0] == phase0)
        #expect(TruePeakFilter.phases[1] == phase1)
        #expect(TruePeakFilter.phases[2] == Array(phase1.reversed()))
        #expect(TruePeakFilter.phases[3] == Array(phase0.reversed()))
    }

    @Test func prototypeIsLinearPhaseSymmetric() {
        let prototype = TruePeakFilter.prototype
        #expect(prototype.count == 48)
        for index in prototype.indices {
            #expect(prototype[index] == prototype[47 - index])
        }
        // The two centre taps carry the interpolator's main lobe; anything else
        // there means the branch ordering drifted.
        #expect(prototype[23] == 0.9721679687500)
        #expect(prototype[24] == 0.9721679687500)
    }

    // MARK: Level accuracy

    @Test(arguments: [44100.0, 48000.0])
    func fullScaleSineReadsZeroDBTP(sampleRate: Double) {
        let meter = TruePeakMeter()
        let tone = sine(frequency: 997, sampleRate: sampleRate, seconds: 1)
        let measurement = feed(meter, tone)
        #expect(abs(measurement.dBTP) <= 0.3)
        #expect(measurement.linear == meter.measurement.linear)
    }

    @Test func interSamplePeakExceedsSamplePeak() {
        // 11025 Hz at 44.1 kHz is exactly four samples per cycle; the π/4 phase
        // puts every sample at ±0.7071 while the waveform itself still reaches
        // full scale between them.
        let tone = sine(frequency: 11025, sampleRate: 44100, seconds: 0.5, phase: .pi / 4)
        let sampled = samplePeak(tone)
        #expect(abs(sampled - 0.70710677) < 1e-4)

        let truePeak = feed(TruePeakMeter(), tone).linear
        #expect(truePeak > sampled)
        // Recovering the hidden peak, not merely reading a hair above the
        // samples: the real inter-sample peak is full scale.
        #expect(truePeak > 0.9)
    }

    @Test func matchesDirectPolyphaseReference() {
        let samples = noise(count: 3000)
        let measured = feed(TruePeakMeter(), samples).linear
        #expect(abs(measured - referenceTruePeak(samples)) < 1e-5)
    }

    // MARK: Block handling

    @Test(arguments: [1, 3, 7, 12, 13, 511, 1024, 1025, 1500])
    func blockSizeDoesNotChangeTheReading(blockSize: Int) {
        let samples = noise(count: 4096, seed: 0x9E37_79B9_7F4A_7C15)
        let whole = feed(TruePeakMeter(), samples).linear

        let chunked = TruePeakMeter()
        var offset = 0
        while offset < samples.count {
            let end = min(offset + blockSize, samples.count)
            feed(chunked, Array(samples[offset ..< end]))
            offset = end
        }
        #expect(abs(chunked.measurement.linear - whole) < 1e-5)
    }

    @Test func emptyBlockReadsSilenceWithoutTrap() {
        let meter = TruePeakMeter()
        #expect(meter.measurement.dBTP == -.infinity)
        #expect(feed(meter, []).dBTP == -.infinity)

        var unused: Float = 0
        #expect(meter.process(&unused, count: 0).dBTP == -.infinity)
        #expect(meter.measurement.dBTP == -.infinity)
    }

    @Test func digitalSilenceReadsNegativeInfinity() {
        let measurement = feed(TruePeakMeter(), [Float](repeating: 0, count: 2048))
        #expect(measurement.linear == 0)
        #expect(measurement.dBTP == -.infinity)
    }

    // MARK: Running state

    @Test func runningPeakKeepsTheLoudestBlock() {
        let meter = TruePeakMeter()
        let loud = feed(meter, sine(frequency: 1000, sampleRate: 48000, seconds: 0.1)).linear
        // The delay line carries, so this block's own reading still sees the
        // loud tail for eleven samples — it comes in below it all the same.
        let quieter = feed(meter, sine(frequency: 1000, sampleRate: 48000, seconds: 0.1, amplitude: 0.1)).linear
        #expect(quieter < loud)
        #expect(meter.measurement.linear == loud)
    }

    @Test func channelsAreTrackedIndependently() {
        let meter = TruePeakMeter(channelCount: 2)
        feed(meter, sine(frequency: 1000, sampleRate: 48000, seconds: 0.1, amplitude: 0.25), channel: 0)
        feed(meter, sine(frequency: 1000, sampleRate: 48000, seconds: 0.1, amplitude: 1.0), channel: 1)

        let left = meter.measurement(channel: 0).linear
        let right = meter.measurement(channel: 1).linear
        #expect(left < right)
        #expect(abs(left * 4 - right) < 0.01)
        #expect(meter.measurement.linear == right)
    }

    @Test func resetClearsPeaksAndDelayLines() {
        let meter = TruePeakMeter(channelCount: 2)
        let tone = sine(frequency: 997, sampleRate: 48000, seconds: 0.05)
        feed(meter, tone, channel: 0)
        feed(meter, tone, channel: 1)
        #expect(meter.measurement.linear > 0.9)

        meter.reset()
        #expect(meter.measurement.dBTP == -.infinity)
        #expect(meter.measurement(channel: 1).dBTP == -.infinity)

        // A cleared delay line makes the next feed identical to a fresh meter's.
        let samples = noise(count: 512)
        let reused = feed(meter, samples).linear
        #expect(abs(reused - feed(TruePeakMeter(), samples).linear) < 1e-6)
    }

    // MARK: Allocation

    @Test func processIsAllocationFree() {
        let meter = TruePeakMeter(channelCount: 2)
        let block = noise(count: 512)
        let iterations = 10000

        let (ambient, processDelta) = block.withUnsafeBufferPointer { buffer -> (Int, Int) in
            guard let base = buffer.baseAddress else { return (0, iterations) }
            for _ in 0 ..< 200 {
                meter.process(base, count: block.count, channel: 0)
                meter.process(base, count: block.count, channel: 1)
            }

            // The default malloc zone counter is process-global, so under
            // `--parallel` it also counts other tests' allocations. The control
            // window (no processing) measures that ambient noise to subtract it.
            var sink = 0
            let controlStart = mallocBlocksInUse()
            for index in 0 ..< iterations {
                sink = sink &+ (index & 1)
            }
            let ambientDelta = mallocBlocksInUse() - controlStart
            _ = sink

            let processStart = mallocBlocksInUse()
            for _ in 0 ..< iterations {
                meter.process(base, count: block.count, channel: 0)
                meter.process(base, count: block.count, channel: 1)
            }
            return (ambientDelta, mallocBlocksInUse() - processStart)
        }

        // A per-call allocation regression would add ~2e4 blocks; a zero-alloc
        // path only tracks ambient noise, well inside this margin.
        #expect(processDelta <= max(ambient, 0) + 4096)
    }
}
