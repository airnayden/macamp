import Darwin
@testable import DSP
import Foundation
import Testing

private let sampleRate = 44100.0

private struct StereoResponse {
    var left: [Float]
    var right: [Float]
}

/// Runs `frameCount` frames through `kernel`, with `leftImpulse`/`rightImpulse`
/// placed on frame 0 and silence afterwards.
private func impulseResponse(
    _ kernel: CrossfeedKernel,
    leftImpulse: Float,
    rightImpulse: Float,
    frameCount: Int
) -> StereoResponse {
    var left = [Float](repeating: 0, count: frameCount)
    var right = [Float](repeating: 0, count: frameCount)
    left[0] = leftImpulse
    right[0] = rightImpulse
    left.withUnsafeMutableBufferPointer { leftBuffer in
        right.withUnsafeMutableBufferPointer { rightBuffer in
            guard let leftBase = leftBuffer.baseAddress, let rightBase = rightBuffer.baseAddress else { return }
            kernel.process(left: leftBase, right: rightBase, frameCount: frameCount)
        }
    }
    return StereoResponse(left: left, right: right)
}

/// Magnitude of `response`'s DTFT at `frequency` — the steady-state level the
/// filter presents to that tone, computed from the impulse response directly.
private func responseMagnitude(_ response: [Float], at frequency: Double) -> Double {
    var real = 0.0
    var imaginary = 0.0
    for (index, sample) in response.enumerated() {
        let angle = -2.0 * .pi * frequency * Double(index) / sampleRate
        real += Double(sample) * cos(angle)
        imaginary += Double(sample) * sin(angle)
    }
    return (real * real + imaginary * imaginary).squareRoot()
}

private func mallocBlocksInUse() -> Int {
    var stats = malloc_statistics_t()
    malloc_zone_statistics(malloc_default_zone(), &stats)
    return Int(stats.blocks_in_use)
}

/// Heap-block growth over `iterations` calls of `work`, paired with an ambient
/// control measured over the same wall-clock span.
///
/// `blocks_in_use` is PROCESS-GLOBAL, so the measured window also counts whatever
/// other suites allocate while it runs. Subtracting a control window is only sound
/// when that window spans the same DURATION: concurrent suites allocate as a
/// function of time, not of this loop's iteration count, so an integer-add control
/// matched only on iteration count finishes ~1000x sooner and subtracts almost none
/// of the noise it exists to subtract (measured: 5425 blocks against an 87-block
/// control). Those suites also allocate in BURSTS, so one control window can miss
/// the burst the work window absorbed — both sides are sampled and the larger wins.
///
/// A per-call allocation regression adds at least `iterations` blocks, which no
/// ambient margin this side of the iteration count can mask.
private func allocationProbe(iterations: Int, _ work: () -> Void) -> (measured: Int, ambient: Int) {
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

private func ambientBlocks(over nanoseconds: UInt64) -> Int {
    var sink = 0
    let start = mallocBlocksInUse()
    let began = DispatchTime.now().uptimeNanoseconds
    while DispatchTime.now().uptimeNanoseconds - began < nanoseconds {
        sink = sink &+ 1
    }
    _ = sink
    return mallocBlocksInUse() - start
}

@Suite(.serialized)
struct CrossfeedTests {
    // MARK: Independent oracle — committed libbs2b 3.1.0 vectors

    @Test(
        "the impulse response matches the committed libbs2b vectors",
        arguments: [
            ("default", CrossfeedLevel.default),
            ("cmoy", CrossfeedLevel.cmoy),
            ("jmeier", CrossfeedLevel.jmeier),
        ]
    )
    func matchesReferenceVectors(preset: String, level: CrossfeedLevel) throws {
        let reference = try CrossfeedFixtures.impulseResponse(preset: preset)
        #expect(reference.outLeft.count == 256)

        let kernel = CrossfeedKernel(level: level, sampleRate: sampleRate)
        let measured = impulseResponse(
            kernel,
            leftImpulse: 1,
            rightImpulse: 0,
            frameCount: reference.outLeft.count
        )

        for frame in 0 ..< reference.outLeft.count {
            let leftError = abs(Double(measured.left[frame]) - reference.outLeft[frame])
            let rightError = abs(Double(measured.right[frame]) - reference.outRight[frame])
            #expect(leftError < 1e-4, "\(preset) L[\(frame)] off by \(leftError)")
            #expect(rightError < 1e-4, "\(preset) R[\(frame)] off by \(rightError)")
        }
    }

    // MARK: Frequency dependence

    @Test("the crossfed channel is lowpassed — 1 kHz exceeds 10 kHz")
    func crossfedChannelIsLowpassed() {
        let kernel = CrossfeedKernel(level: .default, sampleRate: sampleRate)
        let measured = impulseResponse(kernel, leftImpulse: 1, rightImpulse: 0, frameCount: 4096)

        let levelAt1k = responseMagnitude(measured.right, at: 1000)
        let levelAt10k = responseMagnitude(measured.right, at: 10000)
        #expect(levelAt1k > levelAt10k, "1 kHz \(levelAt1k) should exceed 10 kHz \(levelAt10k)")
    }

    // MARK: Compensation gain

    @Test(
        "the DC identity (1 − G_h + G)·gain == 1 holds per preset",
        arguments: [CrossfeedLevel.default, CrossfeedLevel.cmoy, CrossfeedLevel.jmeier]
    )
    func compensationGainRestoresUnityAtDC(level: CrossfeedLevel) {
        let coefficients = CrossfeedCoefficients(level: level, sampleRate: sampleRate)
        let product = (1.0 - coefficients.linearHighboostGain + coefficients.linearLowpassGain)
            * coefficients.outputGain
        #expect(abs(product - 1.0) < 1e-9, "product \(product)")
    }

    @Test(
        "the mono response equals the summed L-only reference channels",
        arguments: [
            ("default", CrossfeedLevel.default),
            ("cmoy", CrossfeedLevel.cmoy),
            ("jmeier", CrossfeedLevel.jmeier),
        ]
    )
    func monoResponseEqualsSummedReferenceChannels(preset: String, level: CrossfeedLevel) throws {
        // For an L-only impulse the reference channels are exactly `hb·gain` and
        // `lp·gain`, so their sum IS the mono (L == R) response — the committed
        // vectors are still the only oracle.
        let reference = try CrossfeedFixtures.impulseResponse(preset: preset)
        let kernel = CrossfeedKernel(level: level, sampleRate: sampleRate)
        let measured = impulseResponse(
            kernel,
            leftImpulse: 1,
            rightImpulse: 1,
            frameCount: reference.outLeft.count
        )

        for frame in 0 ..< reference.outLeft.count {
            let expected = reference.outLeft[frame] + reference.outRight[frame]
            #expect(abs(Double(measured.left[frame]) - expected) < 1e-4, "\(preset) mono L[\(frame)]")
            #expect(abs(Double(measured.right[frame]) - expected) < 1e-4, "\(preset) mono R[\(frame)]")
        }
    }

    // MARK: Failure path — out-of-range clamping

    @Test("an out-of-range level clamps into the legal bs2b range")
    func outOfRangeLevelClamps() {
        let tooLow = CrossfeedLevel(cutFrequency: 200, feedDB: 20)
        #expect(tooLow.cutFrequency == 300)
        #expect(tooLow.feedDB == 15)

        let tooHigh = CrossfeedLevel(cutFrequency: 9000, feedDB: 0.1)
        #expect(tooHigh.cutFrequency == 2000)
        #expect(tooHigh.feedDB == 1)

        // A clamped level still derives finite, usable coefficients.
        let coefficients = CrossfeedCoefficients(level: tooLow, sampleRate: sampleRate)
        #expect(coefficients.outputGain.isFinite)
        #expect(coefficients.lowpassB1 > 0 && coefficients.lowpassB1 < 1)
    }

    // MARK: Parameter box

    @Test("the coefficient box hands off a published value without waiting on the render thread")
    func coefficientBoxPublishesLatest() {
        let kernel = CrossfeedKernel(level: .default, sampleRate: sampleRate)
        #expect(kernel.activeCoefficients == CrossfeedCoefficients(level: .default, sampleRate: sampleRate))

        kernel.setLevel(.jmeier, sampleRate: sampleRate)
        #expect(kernel.parameterBox.publishCount == 1)

        var left: [Float] = [0]
        var right: [Float] = [0]
        left.withUnsafeMutableBufferPointer { leftBuffer in
            right.withUnsafeMutableBufferPointer { rightBuffer in
                guard let leftBase = leftBuffer.baseAddress, let rightBase = rightBuffer.baseAddress else { return }
                kernel.process(left: leftBase, right: rightBase, frameCount: 1)
            }
        }
        #expect(kernel.activeCoefficients == CrossfeedCoefficients(level: .jmeier, sampleRate: sampleRate))
    }

    @Test("the box replaces the published value and counts completed publications")
    func coefficientBoxReplacesPublishedValue() {
        let box = CrossfeedCoefficientBox(
            coefficients: CrossfeedCoefficients(level: .default, sampleRate: sampleRate)
        )
        for (index, level) in [CrossfeedLevel.cmoy, .jmeier, .default, .cmoy].enumerated() {
            box.publish(CrossfeedCoefficients(level: level, sampleRate: sampleRate))
            #expect(box.publishCount == UInt64(index + 1))
            #expect(box.latest() == CrossfeedCoefficients(level: level, sampleRate: sampleRate))
        }
    }

    @Test("Concurrent coefficient reads return complete published values")
    func coefficientBoxConcurrentPublication() {
        let first = CrossfeedCoefficients(level: .default, sampleRate: 44100)
        let second = CrossfeedCoefficients(level: .jmeier, sampleRate: 96000)
        let box = CrossfeedCoefficientBox(coefficients: first)
        let group = DispatchGroup()
        let start = DispatchSemaphore(value: 0)
        let torn = AtomicCounter()
        group.enter()
        DispatchQueue.global().async {
            start.wait()
            for index in 0 ..< 100_000 {
                box.publish(index.isMultiple(of: 2) ? first : second)
            }
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            start.signal()
            for _ in 0 ..< 100_000 {
                if let value = box.latest(), value != first, value != second { torn.add(1) }
            }
            group.leave()
        }
        #expect(group.wait(timeout: .now() + 30) == .success)
        #expect(torn.load() == 0)
        #expect(box.publishCount == 100_000)
        #expect(box.latest() == second)
    }

    // MARK: Audio-thread invariant

    @Test("process performs no heap allocation over 10k calls")
    func processIsAllocationFree() {
        let kernel = CrossfeedKernel(level: .default, sampleRate: sampleRate)
        let frameCount = 512
        var left = [Float](repeating: 0, count: frameCount)
        var right = [Float](repeating: 0, count: frameCount)
        for frame in 0 ..< frameCount {
            left[frame] = Float(sin(Double(frame) * 0.05))
            right[frame] = Float(sin(Double(frame) * 0.07))
        }

        left.withUnsafeMutableBufferPointer { leftBuffer in
            right.withUnsafeMutableBufferPointer { rightBuffer in
                guard let leftBase = leftBuffer.baseAddress, let rightBase = rightBuffer.baseAddress else { return }

                let probe = allocationProbe(iterations: 10000) {
                    kernel.process(left: leftBase, right: rightBase, frameCount: frameCount)
                }
                #expect(
                    probe.measured <= max(probe.ambient, 0) + 4096,
                    "process \(probe.measured) vs ambient \(probe.ambient)"
                )
            }
        }
    }
}
