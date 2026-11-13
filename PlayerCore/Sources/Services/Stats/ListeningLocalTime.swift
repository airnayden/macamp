// ListeningLocalTime — hour-of-day and weekday, in pure arithmetic over stored data.
//
// "I listen to this at 2 a.m." is a statement about the listener's OWN local time at
// the moment they pressed play, so it cannot be recovered from a UTC timestamp alone
// and it must not be recomputed from the machine's current zone. `playEvent` stores
// `utcOffsetSeconds` at capture precisely so this file needs nothing else.
//
// There is deliberately NO `Calendar`, NO `TimeZone` and NO `DateFormatter` here:
//
//  * `Calendar.current` is user-configurable and `TimeZone.current` moves with the
//    device, so the same event would land in a different hour bucket on two machines
//    — or on the same machine after a flight, retroactively rewriting history.
//  * Both consult ICU data shipped with the OS, so a digest generated on one OS
//    version would not be guaranteed byte-identical to one generated on another.
//
// The whole computation is therefore four lines of arithmetic over `startedAt` and
// `utcOffsetSeconds`, both of which are stored data:
//
//     localSeconds  = startedAt + utcOffsetSeconds
//     hourOfDay     = Int(localSeconds % 86400 / 3600)
//     daysSinceEpoch = Int(localSeconds / 86400)
//     weekday       = (daysSinceEpoch + 4) % 7        // 0 = Sunday
//
// The `+ 4` is the calendar's only fixed point: 1970-01-01 was a Thursday, and
// Thursday is index 4 when Sunday is 0.
//
// **Domain invariant — `localSeconds` must be non-negative.** `truncatingRemainder`
// keeps the sign of its operand, `Int(_:)` truncates toward zero, and Swift's `%`
// returns a negative remainder for a negative dividend: all three misbehave below
// the epoch and would produce out-of-range bucket indices. Production data cannot go
// there (`startedAt` is ≈ 1.7e9 and real offsets are within ±14 h), so the clamp in
// ``localSeconds(startedAt:utcOffsetSeconds:)`` exists to stop a pathological *test*
// seed from silently writing outside a histogram.
import Foundation

/// Local-time bucketing for listening statistics, computed from stored data only.
public enum ListeningLocalTime {
    /// Bins in a time-of-day histogram.
    public static let hoursPerDay = 24

    /// Bins in a weekday histogram. Index `0` is Sunday.
    public static let daysPerWeek = 7

    /// Seconds in a civil day. Leap seconds do not exist in Unix time.
    public static let secondsPerDay: Double = 86400

    /// Seconds in an hour.
    public static let secondsPerHour: Double = 3600

    /// Weekday index of 1970-01-01, which was a Thursday.
    public static let epochWeekday = 4

    /// 9999-12-31T23:59:59Z shifted by the widest real UTC offset (+14 h). Clamping
    /// to it keeps `Int(_:)` from trapping on a corrupt but finite timestamp.
    public static let maxLocalSeconds: Double = 253_402_351_199

    /// The listener's own wall-clock instant, as seconds since their local epoch.
    ///
    /// Clamped into `0 ... maxLocalSeconds` so the arithmetic below stays in its
    /// defined domain; a non-finite timestamp is corrupt and collapses to `0`.
    public static func localSeconds(startedAt: Double, utcOffsetSeconds: Int) -> Double {
        let shifted = startedAt + Double(utcOffsetSeconds)
        guard shifted.isFinite else { return 0 }
        return min(max(0, shifted), maxLocalSeconds)
    }

    /// The local hour, `0 ... 23`.
    public static func hourOfDay(localSeconds: Double) -> Int {
        let hour = Int(localSeconds.truncatingRemainder(dividingBy: secondsPerDay) / secondsPerHour)
        return min(max(0, hour), hoursPerDay - 1)
    }

    /// Whole local days since the epoch.
    public static func daysSinceEpoch(localSeconds: Double) -> Int {
        max(0, Int(localSeconds / secondsPerDay))
    }

    /// The local weekday, `0 ... 6`, where `0` is Sunday.
    public static func weekday(localSeconds: Double) -> Int {
        (daysSinceEpoch(localSeconds: localSeconds) + epochWeekday) % daysPerWeek
    }

    /// The local hour an event started in, `0 ... 23`.
    public static func hourOfDay(startedAt: Double, utcOffsetSeconds: Int) -> Int {
        hourOfDay(localSeconds: localSeconds(startedAt: startedAt, utcOffsetSeconds: utcOffsetSeconds))
    }

    /// The local weekday an event started on, `0 ... 6`, where `0` is Sunday.
    public static func weekday(startedAt: Double, utcOffsetSeconds: Int) -> Int {
        weekday(localSeconds: localSeconds(startedAt: startedAt, utcOffsetSeconds: utcOffsetSeconds))
    }
}
