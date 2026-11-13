import DSP
import Foundation
import Services
import Testing

@Suite("Fake-lossless spectral detector — committed fixtures")
struct SpectralDetectorFixtureTests {
    @Test("A FLAC transcoded from a 128 kbps MP3 reads as suspect at ~16 kHz")
    func transcodedFixtureIsSuspect() async throws {
        let verdict = try await SpectralIntegrityAnalyzer().inspect(SpectralFixtures.transcoded)

        guard case let .suspectTranscode(cutoffHz) = verdict else {
            Issue.record("expected .suspectTranscode, got \(verdict)")
            return
        }
        #expect(cutoffHz > 15500)
        #expect(cutoffHz < 16500)
    }

    /// The load-bearing half of the pair. A detector that flags real lossless
    /// material is worse than no detector, so this fixture is deliberately the
    /// hardest possible case: flat white noise, full band, no rolloff to mistake
    /// for an encoder's lowpass.
    @Test("A true-lossless FLAC of the same signal reads as consistent")
    func losslessFixtureIsConsistent() async throws {
        let verdict = try await SpectralIntegrityAnalyzer().inspect(SpectralFixtures.lossless)

        guard case let .consistent(cutoffHz) = verdict else {
            Issue.record("expected .consistent, got \(verdict)")
            return
        }
        #expect(cutoffHz > 20000)
        #expect(!verdict.isSuspect)
    }

    @Test("The two fixtures disagree — the detector is reading the audio, not the container")
    func fixturesAreDistinguished() async throws {
        let analyzer = SpectralIntegrityAnalyzer()
        let suspect = try await analyzer.inspect(SpectralFixtures.transcoded)
        let clean = try await analyzer.inspect(SpectralFixtures.lossless)

        #expect(suspect.isSuspect)
        #expect(!clean.isSuspect)
        let suspectCutoff = try #require(suspect.cutoffHz)
        let cleanCutoff = try #require(clean.cutoffHz)
        #expect(cleanCutoff - suspectCutoff > 5000)
    }
}

@Suite("Fake-lossless spectral detector — indeterminate paths")
struct SpectralDetectorIndeterminateTests {
    @Test("Digital silence is indeterminate, not consistent")
    func silentFileIsIndeterminate() async throws {
        let fixture = TemporaryAudioFile(name: "silence.wav")
        defer { fixture.remove() }
        try fixture.writeSilence(sampleRate: 44100, seconds: 2)

        let verdict = try await SpectralIntegrityAnalyzer().inspect(fixture.url)

        #expect(verdict == .indeterminate(.silentOrTooQuiet))
        #expect(verdict.cutoffHz == nil)
    }

    @Test("A file too short to average is indeterminate")
    func shortFileIsIndeterminate() async throws {
        let fixture = TemporaryAudioFile(name: "blip.wav")
        defer { fixture.remove() }
        try fixture.write(sampleRate: 44100, seconds: 0.1) { frame, sampleRate in
            0.5 * Float(sin(2 * Double.pi * 1000 * Double(frame) / sampleRate))
        }

        let verdict = try await SpectralIntegrityAnalyzer().inspect(fixture.url)

        #expect(verdict == .indeterminate(.insufficientAudio))
    }

    @Test("Silence produces no NaN or infinity anywhere in the estimate")
    func silenceDoesNotDivideByZero() {
        let estimator = SpectralCutoffEstimator(sampleRate: 44100)
        estimator.append([Float](repeating: 0, count: 44100))

        let outcome = estimator.finish()

        #expect(outcome == .indeterminate(.silentOrTooQuiet))
        #expect(outcome.estimate == nil)
    }

    @Test("An estimator that was never fed declines instead of trapping")
    func emptyEstimatorIsIndeterminate() {
        #expect(SpectralCutoffEstimator(sampleRate: 44100).finish() == .indeterminate(.insufficientAudio))
    }

    @Test("A sample rate with no room for the reference band is declined")
    func unusableSampleRateIsDeclined() {
        let estimator = SpectralCutoffEstimator(sampleRate: 2000)
        estimator.append((0 ..< 40000).map { Float(sin(Double($0) * 0.31)) * 0.4 })

        #expect(estimator.finish() == .indeterminate(.unusableSampleRate))
    }
}

@Suite("Fake-lossless rule — the heuristic is a heuristic")
struct FakeLosslessRuleTests {
    private func estimate(cutoffHz: Double, sampleRate: Double) -> SpectralCutoffOutcome {
        .estimated(
            SpectralCutoffEstimate(
                cutoffHz: cutoffHz,
                nyquistHz: sampleRate / 2,
                noiseFloorDB: -80,
                thresholdDB: -55,
                windowCount: 20
            )
        )
    }

    @Test("A 16 kHz cutoff at 44.1 kHz is suspect")
    func lowCutoffAtCDRateIsSuspect() {
        let verdict = FakeLosslessRule.verdict(for: estimate(cutoffHz: 16000, sampleRate: 44100))
        #expect(verdict == .suspectTranscode(cutoffHz: 16000))
    }

    @Test("Content reaching Nyquist is consistent")
    func fullBandIsConsistent() {
        let verdict = FakeLosslessRule.verdict(for: estimate(cutoffHz: 22050, sampleRate: 44100))
        #expect(verdict == .consistent(cutoffHz: 22050))
    }

    /// Both conditions must hold. A 96 kHz file stopping at 21 kHz is 0.44 of
    /// Nyquist — deeply "suspicious" by ratio alone — yet it is the single most
    /// ordinary shape a hi-res recording takes. The 20 kHz ceiling is what keeps
    /// every hi-res file out of the report.
    @Test("A hi-res file stopping just above hearing is consistent despite a low ratio")
    func hiResIsNotFlaggedByRatioAlone() throws {
        let outcome = estimate(cutoffHz: 21000, sampleRate: 96000)
        let ratio = try #require(outcome.estimate).cutoffRatio

        #expect(ratio < FakeLosslessRule.suspectCutoffRatio)
        #expect(FakeLosslessRule.verdict(for: outcome) == .consistent(cutoffHz: 21000))
    }

    @Test("A cutoff just under both bounds is suspect, just over either is not")
    func boundariesHold() {
        let sampleRate = 44100.0
        let ratioBound = FakeLosslessRule.suspectCutoffRatio * sampleRate / 2

        #expect(FakeLosslessRule.verdict(for: estimate(cutoffHz: ratioBound - 1, sampleRate: sampleRate)).isSuspect)
        #expect(!FakeLosslessRule.verdict(for: estimate(cutoffHz: ratioBound + 1, sampleRate: sampleRate)).isSuspect)
        #expect(!FakeLosslessRule.verdict(for: estimate(cutoffHz: 20001, sampleRate: 96000)).isSuspect)
    }

    @Test("An indeterminate measurement never becomes a clean verdict")
    func indeterminatePassesThrough() {
        for reason in SpectralIndeterminateReason.allCases {
            let verdict = FakeLosslessRule.verdict(for: .indeterminate(reason))
            #expect(verdict == .indeterminate(reason))
            #expect(!verdict.isSuspect)
            #expect(verdict.cutoffHz == nil)
        }
    }
}
