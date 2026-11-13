// OutputDeviceError — the typed failure vocabulary of the output-device seam, and
// the two constants that make the bounded rate-change wait testable without a HAL.
//
// Foundation only. See `OutputDeviceControlling.swift` for why no CoreAudio symbol
// may appear anywhere in this directory.
import Foundation
import Models

/// Why an output-device operation failed.
///
/// Every case is actionable by the caller: a coordinator that cannot switch a rate
/// proceeds to load the track anyway (todo 15), and a picker whose remembered device
/// vanished falls back to the system default (todo 16). None of them is a crash.
public enum OutputDeviceError: Error, Sendable, Equatable, Hashable {
    /// The identifier no longer names an attached output device.
    ///
    /// The normal cause is a replug between enumeration and use — HAL identifiers
    /// are transient — not a programming error.
    case deviceNotFound(OutputDeviceID)

    /// The device does not advertise `rate` among its available nominal rates.
    ///
    /// Carries what it *does* advertise so a caller can pick a neighbour instead of
    /// re-querying.
    case rateUnsupported(rate: Double, deviceID: OutputDeviceID, available: [Double])

    /// The set was dispatched but the device did not report the new rate within the
    /// bounded wait.
    ///
    /// A timeout is NOT a rollback: the set already reached the HAL and may still
    /// land afterwards. The contract for callers is to stop waiting and carry on —
    /// never to re-issue or attempt to revert (todo 15's recorded semantics).
    case rateChangeTimedOut(rate: Double, deviceID: OutputDeviceID, afterSeconds: Double)

    /// A platform audio call returned a non-success status.
    ///
    /// `operation` names the call site in plain text for logs; `status` is the raw
    /// `OSStatus`, carried as `Int32` so this enum stays free of CoreAudio types.
    case platformFailure(operation: String, status: Int32)
}

/// Constants governing a nominal sample-rate change.
///
/// They live in PlayerCore — not in the macOS HAL module — precisely so
/// `FakeOutputDeviceController` can honour the SAME bounds the production
/// implementation does. That is what makes the timeout path assertable by a
/// portable test with no audio hardware in sight.
public enum OutputDeviceRateChange {
    /// How long to wait for a device to report the rate it was asked to adopt.
    ///
    /// Setting `kAudioDevicePropertyNominalSampleRate` is ASYNCHRONOUS: the call
    /// returns immediately and the device re-clocks some milliseconds later,
    /// announcing the new value through a property listener. Two seconds is the
    /// ceiling every caller is bounded by; slower devices exist, and for them the
    /// answer is to stop waiting, not to wait longer — a track must never be held
    /// hostage to a re-clocking USB interface.
    public static let boundedWaitSeconds: Double = 2.0

    /// How close two nominal rates must be to count as the same rate.
    ///
    /// Nominal rates are `Float64`, and a device can report 44100.000001 for what it
    /// was set to as 44100. Half a hertz is orders of magnitude below the gap
    /// between any two real rates (44100 vs 48000), so this can never collapse two
    /// distinct rates into one.
    public static let rateMatchEpsilon: Double = 0.5

    /// Whether two nominal rates are the same rate.
    public static func matches(_ lhs: Double, _ rhs: Double) -> Bool {
        abs(lhs - rhs) <= rateMatchEpsilon
    }
}
