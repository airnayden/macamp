// LoudnessAnalyzerTests — the BS.1770-4 acceptance vectors.
//
// The three positive vectors are the ones that actually pin the arithmetic: a
// reference tone must read its own level, a tone below the absolute gate must
// read nothing at all, and a quiet passage in front of a loud one must not
// drag the answer down. Everything else here guards a failure path.
import Foundation
import Services
import Testing

struct LoudnessAnalyzerTests {
    /// EBU Tech 3341 states its expected readings to ±0.1 LU.
    private let tolerance = 0.1

    // MARK: Reference level

    @Test("a −23 dBFS 997 Hz stereo sine reads −23.0 LUFS", arguments: [48000.0, 44100.0])
    func referenceToneReadsItsOwnLevel(sampleRate: Double) throws {
        let tone = LoudnessFixtures.tone(dBFS: -23, seconds: 20, sampleRate: sampleRate)
        let measured = LoudnessAnalyzer.measure(channels: [tone, tone], sampleRate: sampleRate)

        let integrated = try #require(measured.integratedLUFS)
        #expect(abs(integrated + 23.0) < tolerance, "measured \(integrated) LUFS at \(sampleRate) Hz")
        #expect(measured.blockCount == 197)
        #expect(measured.gatedBlockLoudness.count == 197)
    }

    @Test("mono is measured as one unweighted channel, so it reads 3 dB below dual-mono")
    func monoReadsThreeDecibelsBelowDualMono() throws {
        let tone = LoudnessFixtures.tone(dBFS: -23, seconds: 5, sampleRate: 48000)
        let mono = try #require(LoudnessAnalyzer.measure(channels: [tone], sampleRate: 48000).integratedLUFS)
        let stereo = try #require(LoudnessAnalyzer.measure(channels: [tone, tone], sampleRate: 48000).integratedLUFS)

        #expect(abs((stereo - mono) - 10.0 * log10(2.0)) < 0.01)
    }

    // MARK: The absolute gate

    @Test("a −80 dBFS tone is 10 dB under the absolute gate, so nothing survives it")
    func toneBelowAbsoluteGateYieldsTheSentinel() {
        let tone = LoudnessFixtures.tone(dBFS: -80, seconds: 20, sampleRate: 48000)
        let measured = LoudnessAnalyzer.measure(channels: [tone, tone], sampleRate: 48000)

        #expect(measured.integratedLUFS == nil)
        #expect(measured.gatedBlockLoudness.isEmpty)
        // The blocks WERE produced — they just all read ≈ −80 LKFS and were
        // dropped, which is the case a −60 dBFS vector would silently miss.
        #expect(measured.blockCount == 197)
    }

    // MARK: The relative gate

    @Test("a quiet 10 s lead-in does not pull a −23 dBFS body away from −23.0 LUFS")
    func relativeGateDiscardsTheQuietPassage() throws {
        let measured = LoudnessAnalyzer.measure(channels: [steppedTone, steppedTone], sampleRate: 48000)

        let integrated = try #require(measured.integratedLUFS)
        #expect(abs(integrated + 23.0) < tolerance, "measured \(integrated) LUFS")
    }

    @Test("the returned block set keeps blocks the relative gate rejects")
    func returnedBlocksAreOnlyAbsoluteGated() throws {
        let measured = LoudnessAnalyzer.measure(channels: [steppedTone, steppedTone], sampleRate: 48000)

        // Every block clears −70 LKFS, so the absolute gate drops none of them.
        #expect(measured.gatedBlockLoudness.count == measured.blockCount)

        let ungatedMean = try #require(LoudnessGating.meanLoudness(of: measured.gatedBlockLoudness))
        let relativeThreshold = ungatedMean + LoudnessGating.relativeGateOffsetLU
        let rejected = measured.gatedBlockLoudness.filter { $0 <= relativeThreshold }
        // Pre-applying the relative gate would have deleted these 97 quiet
        // blocks and biased any album pooled from them high.
        #expect(rejected.count == 97)
    }

    // MARK: Failure paths

    @Test("no channels at all returns the sentinel without throwing")
    func emptyChannelListIsSilent() {
        #expect(LoudnessAnalyzer.measure(channels: [], sampleRate: 48000) == .silent)
    }

    @Test("zero-length channels return the sentinel without throwing")
    func zeroLengthInputIsSilent() {
        #expect(LoudnessAnalyzer.measure(channels: [[], []], sampleRate: 48000) == .silent)
    }

    @Test("digital silence returns the sentinel without throwing")
    func digitalSilenceIsSilent() {
        let quiet = LoudnessFixtures.silence(seconds: 5, sampleRate: 48000)
        let measured = LoudnessAnalyzer.measure(channels: [quiet, quiet], sampleRate: 48000)

        #expect(measured.integratedLUFS == nil)
        #expect(measured.gatedBlockLoudness.isEmpty)
        #expect(measured.blockCount == 47)
    }

    @Test("a clip shorter than one 400 ms block produces no block at all")
    func subBlockLengthClipProducesNoBlocks() {
        let tone = LoudnessFixtures.tone(dBFS: -23, seconds: 0.3, sampleRate: 48000)
        let measured = LoudnessAnalyzer.measure(channels: [tone, tone], sampleRate: 48000)

        #expect(measured.integratedLUFS == nil)
        #expect(measured.blockCount == 0)
    }

    @Test("a non-positive sample rate returns the sentinel without dividing by zero")
    func invalidSampleRateIsSilent() {
        let tone = LoudnessFixtures.tone(dBFS: -23, seconds: 1, sampleRate: 48000)
        #expect(LoudnessAnalyzer.measure(channels: [tone, tone], sampleRate: 0) == .silent)
    }

    // MARK: Streaming equivalence

    @Test("feeding ragged chunks measures identically to one whole-buffer call")
    func chunkedFeedMatchesWholeBuffer() {
        let tone = LoudnessFixtures.tone(dBFS: -23, seconds: 3, sampleRate: 48000)
        let wholeBuffer = LoudnessAnalyzer.measure(channels: [tone, tone], sampleRate: 48000)

        let analyzer = LoudnessAnalyzer(sampleRate: 48000, channelCount: 2)
        tone.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            // Deliberately coprime with the 4800-frame sub-block so chunk
            // boundaries never line up with block boundaries.
            for span in [1, 4801, 337, 19999].cycled(upTo: buffer.count) {
                let taken = min(span, buffer.count - offset)
                guard taken > 0 else { break }
                analyzer.append(channels: [base + offset, base + offset], frameCount: taken)
                offset += taken
            }
        }

        // Not bit-equality: a sub-block assembled from several `vDSP_svesqD`
        // calls sums in a different order than one call over the whole 4800.
        // A broken history carry would differ by whole decibels, not 1e-9.
        let chunked = analyzer.finish().gatedBlockLoudness
        #expect(chunked.count == wholeBuffer.gatedBlockLoudness.count)
        for (lhs, rhs) in zip(chunked, wholeBuffer.gatedBlockLoudness) {
            #expect(abs(lhs - rhs) < 1e-9)
        }
    }

    // MARK: Fixtures

    /// 10 s at −36 dBFS followed by 20 s at −23 dBFS — the relative-gate vector.
    private var steppedTone: [Float] {
        LoudnessFixtures.tone(dBFS: -36, seconds: 10, sampleRate: 48000)
            + LoudnessFixtures.tone(dBFS: -23, seconds: 20, sampleRate: 48000)
    }
}

private extension [Int] {
    /// Repeats the sequence until the emitted spans cover `total`.
    func cycled(upTo total: Int) -> [Int] {
        guard !isEmpty else { return [] }
        var spans: [Int] = []
        var covered = 0
        while covered < total {
            let span = self[spans.count % count]
            spans.append(span)
            covered += span
        }
        return spans
    }
}
