// CoreAudioRateCatalog — reduces the HAL's rate RANGES to pickable rates.
import CoreAudio
import Foundation
import Services

enum CoreAudioRateCatalog {
    /// The rates a continuous-range device is offered.
    ///
    /// A span like 8000–192000 (aggregate and virtual devices advertise these) is not
    /// a list, and offering every integer hertz in it is not a picker. These are the
    /// rates audio files are actually mastered at — the two families (48 kHz × 2ⁿ and
    /// 44.1 kHz × 2ⁿ) plus the low telephony rates a USB headset can report.
    static let standardRates: [Double] = [
        8000, 11025, 16000, 22050, 32000, 44100, 48000,
        64000, 88200, 96000, 176_400, 192_000, 352_800, 384_000,
    ]

    static func rates(in ranges: [AudioValueRange]) -> [Double] {
        var found: Set<Double> = []
        for range in ranges {
            if OutputDeviceRateChange.matches(range.mMinimum, range.mMaximum) {
                found.insert(range.mMinimum)
            } else {
                let inside = standardRates.filter { $0 >= range.mMinimum && $0 <= range.mMaximum }
                found.formUnion(inside)
            }
        }
        return found.sorted()
    }
}
