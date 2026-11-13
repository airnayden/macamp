@testable import AudioEngine
import AudioToolbox
import AVFAudio
import Foundation
import PlayerCoreTestSupport
import Testing

private let probeSeconds = 1.0

/// Renders a left-only `frequency` tone through a crossfeed node programmed to
/// `level`, terminating at `outputNode` — never `mainMixerNode`, whose mono pan
/// law would corrupt the level assertions.
private func renderCrossfed(level: CrossfeedLevel, frequency: Double) throws -> AVAudioPCMBuffer {
    let format = try CrossfeedProbe.stereoFormat()
    let crossfeed = try #require(CrossfeedAudioUnit.makeNode())
    crossfeed.unit.setLevel(level)
    return try OfflineRenderHarness.render(format: format, duration: probeSeconds) { engine in
        let source = CrossfeedProbe.leftOnlySine(format: format, frequency: frequency)
        engine.attach(source)
        engine.attach(crossfeed.node)
        engine.connect(source, to: crossfeed.node, format: format)
        return crossfeed.node
    }
}

/// Coverage of ``CrossfeedAudioUnit`` — the render node that runs todo 6's
/// ``CrossfeedKernel`` inside an `AVAudioEngine` graph.
///
/// Every case is headless: the graph runs in `.offline` manual-rendering mode, so
/// no audio hardware and no output device are involved.
@Suite(.serialized)
struct CrossfeedNodeTests {
    // MARK: Independent oracle — measured level vs the committed vectors' DTFT

    @Test(
        "the crossfed channel's level matches the reference DTFT at 1 kHz and 10 kHz",
        arguments: [
            ("default", CrossfeedLevel.default),
            ("cmoy", CrossfeedLevel.cmoy),
            ("jmeier", CrossfeedLevel.jmeier),
        ]
    )
    func crossfedLevelMatchesReferenceDTFT(preset: String, level: CrossfeedLevel) throws {
        let reference = try CrossfeedProbe.crossfedImpulseResponse(preset: preset)
        #expect(reference.count == 256)

        for frequency in [1000.0, 10000.0] {
            let rendered = try renderCrossfed(level: level, frequency: frequency)
            let measured = try CrossfeedProbe.steadyStateRMS(rendered, channel: 1)
            // A sine of peak `a` through a filter of magnitude |H| has RMS
            // `a·|H|/√2`, and the reference IR is the response to a unit impulse
            // on the left — so its DTFT IS |H| for the crossfed channel.
            let expected = Double(CrossfeedProbe.amplitude)
                * CrossfeedProbe.responseMagnitude(reference, at: frequency)
                / 2.0.squareRoot()
            let error = abs(CrossfeedProbe.decibels(measured) - CrossfeedProbe.decibels(expected))
            #expect(
                error < 0.5,
                """
                \(preset) @ \(frequency) Hz: \(CrossfeedProbe.decibels(measured)) dB \
                vs \(CrossfeedProbe.decibels(expected)) dB
                """
            )
        }
    }

    @Test("the crossfed channel is lowpassed — 1 kHz renders above 10 kHz")
    func crossfedChannelIsLowpassedThroughTheGraph() throws {
        let lowTone = try CrossfeedProbe.steadyStateRMS(
            renderCrossfed(level: .default, frequency: 1000),
            channel: 1
        )
        let highTone = try CrossfeedProbe.steadyStateRMS(
            renderCrossfed(level: .default, frequency: 10000),
            channel: 1
        )
        #expect(lowTone > highTone, "1 kHz \(lowTone) should exceed 10 kHz \(highTone)")
        #expect(highTone > 0, "the crossfed channel rendered digital silence")
    }

    // MARK: Failure path — an out-of-range request clamps and still renders

    @Test("an out-of-range level clamps per component and the node still renders")
    func outOfRangeLevelClampsAndRenders() throws {
        let clamped = CrossfeedLevel(cutFrequency: 50, feedDB: 99)
        #expect(clamped.cutFrequency == 300)
        #expect(clamped.feedDB == 15)

        let crossfeed = try #require(CrossfeedAudioUnit.makeNode())
        crossfeed.unit.setLevel(clamped)
        #expect(crossfeed.unit.level == clamped)

        let rendered = try renderCrossfed(level: clamped, frequency: 1000)
        let crossfed = try CrossfeedProbe.steadyStateRMS(rendered, channel: 1)
        let direct = try CrossfeedProbe.steadyStateRMS(rendered, channel: 0)
        #expect(crossfed.isFinite && crossfed > 0)
        #expect(direct.isFinite && direct > 0)
    }

    // MARK: Format change — the node retunes itself from the bus it is prepared at

    @Test(
        "preparing the unit at a new sample rate re-derives the coefficients",
        arguments: [44100.0, 48000.0, 96000.0]
    )
    func preparingRetunesForTheBusSampleRate(rate: Double) throws {
        let unit = try CrossfeedAudioUnit(componentDescription: CrossfeedAudioUnit.componentDescription)
        unit.setLevel(.jmeier)
        let format = try CrossfeedProbe.stereoFormat(rate)
        try unit.inputBusses[0].setFormat(format)
        try unit.outputBusses[0].setFormat(format)
        unit.maximumFramesToRender = 512
        try unit.allocateRenderResources()
        defer { unit.deallocateRenderResources() }

        let published = try #require(unit.kernel.parameterBox.latest())
        #expect(published == CrossfeedCoefficients(level: .jmeier, sampleRate: rate))
    }

    // MARK: Audio-thread invariant

    @Test("the render block performs no heap allocation over 10k blocks")
    func renderBlockIsAllocationFree() throws {
        let frameCount: AUAudioFrameCount = 512
        let format = try CrossfeedProbe.stereoFormat()
        let unit = try CrossfeedAudioUnit(componentDescription: CrossfeedAudioUnit.componentDescription)
        try unit.inputBusses[0].setFormat(format)
        try unit.outputBusses[0].setFormat(format)
        unit.maximumFramesToRender = frameCount
        try unit.allocateRenderResources()
        defer { unit.deallocateRenderResources() }

        let output = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        let outputList = output.mutableAudioBufferList
        let render = unit.internalRenderBlock
        let pull: AURenderPullInputBlock = { _, _, frames, _, list in
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            for index in 0 ..< buffers.count {
                let samples = UnsafeMutableBufferPointer<Float>(buffers[index])
                for frame in 0 ..< Int(frames) {
                    samples[frame] = index == 0 ? 0.25 : 0
                }
            }
            return noErr
        }

        var flags = AudioUnitRenderActionFlags()
        var timestamp = AudioTimeStamp()
        timestamp.mFlags = .sampleTimeValid

        var status: AUAudioUnitStatus = noErr
        let probe = CrossfeedProbe.allocationProbe(iterations: 10000) {
            status = render(&flags, &timestamp, frameCount, 0, outputList, nil, pull)
        }

        #expect(status == noErr)
        #expect(
            probe.measured <= max(probe.ambient, 0) + 4096,
            "render \(probe.measured) vs ambient \(probe.ambient)"
        )
    }
}
