// ReplayGainCalculatorTests — the pure (tags + mode + pre-amp) -> dB math:
// mode/tag selection, pre-amp addition, anti-clip (no theoretical clip),
// graceful missing-tag fallback, and the −96…+24 dB clamp.
import AudioEngine // globalGainRange
import Foundation
import Metadata // ReplayGain
@testable import Services
import Testing

struct ReplayGainCalculatorTests {
    private let calc = ReplayGainCalculator()

    /// A fully-populated tag set (track quieter-than / album = the Beatles fixture).
    private let full = ReplayGain(
        referenceLoudness: 89,
        trackGain: -7.5,
        trackPeak: 0.98,
        albumGain: -8.2,
        albumPeak: 0.99
    )

    // MARK: Mode + tag selection

    @Test("track mode uses TRACK_GAIN, album mode uses ALBUM_GAIN")
    func modeSelectsGainTag() {
        #expect(approxEqual(calc.appliedGain(for: full, mode: .track, preamp: 0), -7.5))
        #expect(approxEqual(calc.appliedGain(for: full, mode: .album, preamp: 0), -8.2))
    }

    @Test("off mode is always unity, even with tags + pre-amp")
    func offModeIsUnity() {
        #expect(calc.appliedGain(for: full, mode: .off, preamp: 6) == 0)
    }

    @Test("album mode falls back to the track tags when album tags are absent")
    func albumFallsBackToTrack() {
        let trackOnly = ReplayGain(trackGain: -5, trackPeak: 0.8)
        #expect(approxEqual(calc.appliedGain(for: trackOnly, mode: .album, preamp: 0), -5))
    }

    // MARK: Pre-amp

    @Test("the pre-amp is added on top of the selected gain")
    func preampIsAdded() {
        #expect(approxEqual(calc.appliedGain(for: full, mode: .track, preamp: 3), -4.5))
        #expect(approxEqual(calc.appliedGain(for: full, mode: .track, preamp: -4), -11.5))
        #expect(approxEqual(calc.appliedGain(for: full, mode: .album, preamp: 2), -6.2))
    }

    // MARK: Anti-clip

    @Test("a boosted hot track is reduced so the peak never exceeds full scale")
    func antiClipPreventsTheoreticalClip() {
        // +12 dB on a 0.9 peak would clip badly; anti-clip must pull it back.
        let hot = ReplayGain(trackGain: 12, trackPeak: 0.9)
        let applied = calc.appliedGain(for: hot, mode: .track, preamp: 0)

        #expect(applied < 12, "gain \(applied) was not reduced from +12")
        // The whole point: no theoretical clip after applying the gain.
        let projectedPeak = 0.9 * pow(10.0, applied / 20.0)
        #expect(projectedPeak <= 1.0 + 1e-9, "projected peak \(projectedPeak) clips")
        // It should land at *exactly* full scale (max loudness without clipping).
        #expect(approxEqual(projectedPeak, 1.0))
    }

    @Test("album anti-clip limits against ALBUM_PEAK")
    func antiClipUsesAlbumPeak() {
        let hot = ReplayGain(albumGain: 10, albumPeak: 0.95)
        let applied = calc.appliedGain(for: hot, mode: .album, preamp: 0)
        let projectedPeak = 0.95 * pow(10.0, applied / 20.0)
        #expect(projectedPeak <= 1.0 + 1e-9, "projected peak \(projectedPeak) clips")
    }

    @Test("a negative gain is never altered by anti-clip (it cannot clip)")
    func negativeGainUntouched() {
        // full.trackGain is -7.5 with a 0.98 peak: attenuation never clips.
        #expect(approxEqual(calc.appliedGain(for: full, mode: .track, preamp: 0), -7.5))
    }

    // MARK: Missing tags

    @Test("no tags at all → graceful 0 dB, no crash")
    func missingTagsFallBackToZero() {
        let empty = ReplayGain()
        #expect(calc.appliedGain(for: empty, mode: .track, preamp: 0) == 0)
        #expect(calc.appliedGain(for: empty, mode: .album, preamp: 6) == 0)
    }

    @Test("peak-only file: no boost without a loudness reference")
    func peakOnlyNeverBoosts() {
        let quietPeak = ReplayGain(trackPeak: 0.5) // headroom, no gain tag
        #expect(calc.appliedGain(for: quietPeak, mode: .track, preamp: 0) == 0)
    }

    @Test("peak-only file above full scale is still pulled down (anti-clip)")
    func peakOnlyHotFileAttenuates() {
        let hotPeak = ReplayGain(trackPeak: 1.5) // recorded above full scale
        let applied = calc.appliedGain(for: hotPeak, mode: .track, preamp: 0)
        #expect(applied < 0, "hot peak-only file was not attenuated (\(applied))")
        let projectedPeak = 1.5 * pow(10.0, applied / 20.0)
        #expect(projectedPeak <= 1.0 + 1e-9, "projected peak \(projectedPeak) clips")
    }

    // MARK: Clamp

    @Test("an absurd negative gain clamps to the floor (−96 dB)")
    func clampsToFloor() {
        let veryQuiet = ReplayGain(trackGain: -300)
        let applied = calc.appliedGain(for: veryQuiet, mode: .track, preamp: 0)
        #expect(approxEqual(applied, Double(globalGainRange.lowerBound)))
    }

    @Test("an absurd positive gain (no peak) clamps to the ceiling (+24 dB)")
    func clampsToCeiling() {
        let veryLoud = ReplayGain(trackGain: 300) // no peak → anti-clip cannot help
        let applied = calc.appliedGain(for: veryLoud, mode: .track, preamp: 0)
        #expect(approxEqual(applied, Double(globalGainRange.upperBound)))
    }

    @Test("anti-clip can hold a huge gain below the +24 clamp ceiling")
    func antiClipBeatsClamp() {
        let veryLoudHot = ReplayGain(trackGain: 300, trackPeak: 0.5)
        let applied = calc.appliedGain(for: veryLoudHot, mode: .track, preamp: 0)
        // −20·log10(0.5) ≈ 6.02 dB — far below the +24 clamp.
        #expect(approxEqual(applied, -20.0 * log10(0.5)))
        #expect(applied < Double(globalGainRange.upperBound))
    }
}
