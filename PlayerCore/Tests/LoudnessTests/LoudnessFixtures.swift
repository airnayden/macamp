// LoudnessFixtures — planar float test tones for the BS.1770-4 suite.
//
// Every tone is produced by the shipped `SignalGenerators.concatenated`
// generator so the suite measures the same synthesis path the rest of the
// audio tests do, rather than a private sine of its own.
import AVFAudio
import Foundation
import PlayerCoreTestSupport

enum LoudnessFixtures {
    /// The EBU Tech 3341 reference tone frequency.
    static let referenceFrequencyHz = 997.0

    /// `seconds` of a tone whose PEAK is `dBFS` below full scale, as planar
    /// floats.
    ///
    /// A pure sine at −23 dBFS peak is what "a −23 dBFS sine" means throughout
    /// BS.1770-4 and EBU Tech 3341 — full scale is a sine that just touches
    /// ±1.0, not one with unity RMS.
    static func tone(
        dBFS: Double,
        seconds: Double,
        sampleRate: Double,
        frequency: Double = referenceFrequencyHz
    ) -> [Float] {
        let buffer = SignalGenerators.concatenated(
            toneA: (freq: frequency, duration: seconds),
            toneB: (freq: frequency, duration: 0),
            sampleRate: sampleRate,
            amplitude: Float(pow(10.0, dBFS / 20.0))
        )
        guard let data = buffer.floatChannelData?.pointee else { return [] }
        return Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
    }

    /// Digital silence — every sample exactly zero.
    static func silence(seconds: Double, sampleRate: Double) -> [Float] {
        [Float](repeating: 0, count: Int((seconds * sampleRate).rounded()))
    }
}
