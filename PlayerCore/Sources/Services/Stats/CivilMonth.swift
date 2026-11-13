// CivilMonth — UTC civil-calendar month arithmetic, in pure integer arithmetic.
//
// This is the ONE month implementation the statistics layer shares. The rollup
// compactor derives its `yearMonth` keys and its 24-month horizon from it, and the
// listening digest must derive its own month buckets from the SAME code — two
// implementations would eventually disagree on a boundary and silently split one
// month across a raw event and a rollup.
//
// It deliberately uses NEITHER `Calendar` NOR `TimeZone`:
//
//  * `Calendar.current` is user-configurable (Gregorian/Buddhist/Japanese eras,
//    first-weekday, minimum-days-in-first-week) and `TimeZone.current` moves with
//    the device, so the same event would land in different months on two machines
//    — or on the same machine after a flight.
//  * Both consult ICU data that ships with the OS, so a digest generated on one
//    OS version is not guaranteed byte-identical to one generated on another.
//
// Instead this is Howard Hinnant's public-domain `civil_from_days` /
// `days_from_civil` pair (chrono-Compatible-Date-Algorithms), which is exact
// proleptic-Gregorian integer arithmetic with no floating point and no external
// data. Months are always **UTC** civil months: `utcOffsetSeconds` is recorded per
// event for local-hour facets, and is intentionally NOT applied here — bucketing by
// local month would make a listener's history re-bucket itself whenever they move.
import Foundation

/// UTC civil-calendar month arithmetic, shared by every statistics consumer.
public enum CivilMonth {
    /// Months in a civil year.
    public static let monthsPerYear = 12

    /// The UTC civil `(year, month)` containing `epochSeconds`.
    ///
    /// - Parameter epochSeconds: An instant as seconds since the Unix epoch.
    /// - Returns: `year` in proleptic-Gregorian terms and `month` in `1...12`.
    public static func civilYearMonth(fromEpochSeconds epochSeconds: Double) -> (year: Int, month: Int) {
        let civil = civilDate(fromDaysSinceEpoch: daysSinceEpoch(fromEpochSeconds: epochSeconds))
        return (civil.year, civil.month)
    }

    /// Months elapsed since year 0, month 1 — a total order over civil months.
    ///
    /// Comparing indices is how "precedes by more than N whole months" is expressed
    /// without any date arithmetic at the call site.
    public static func monthIndex(year: Int, month: Int) -> Int {
        year * monthsPerYear + (month - 1)
    }

    /// The ``monthIndex(year:month:)`` of the month containing `epochSeconds`.
    public static func monthIndex(fromEpochSeconds epochSeconds: Double) -> Int {
        let civil = civilYearMonth(fromEpochSeconds: epochSeconds)
        return monthIndex(year: civil.year, month: civil.month)
    }

    /// The civil `(year, month)` that `index` names — the inverse of
    /// ``monthIndex(year:month:)``.
    public static func yearMonth(atIndex index: Int) -> (year: Int, month: Int) {
        let year = floorDiv(index, monthsPerYear)
        return (year, index - year * monthsPerYear + 1)
    }

    /// The `"YYYY-MM"` key stored in `playEventRollup.yearMonth`.
    ///
    /// Zero-padded and fixed-width so lexicographic ordering equals chronological
    /// ordering — which is what lets the rollup keyset paginate on the raw column.
    public static func yearMonthKey(year: Int, month: Int) -> String {
        String(format: "%04d-%02d", year, month)
    }

    /// The `"YYYY-MM"` key of the month containing `epochSeconds`.
    public static func yearMonthKey(fromEpochSeconds epochSeconds: Double) -> String {
        let civil = civilYearMonth(fromEpochSeconds: epochSeconds)
        return yearMonthKey(year: civil.year, month: civil.month)
    }

    /// The `"YYYY-MM"` key of the month `index` names.
    public static func yearMonthKey(atIndex index: Int) -> String {
        let civil = yearMonth(atIndex: index)
        return yearMonthKey(year: civil.year, month: civil.month)
    }

    /// The UTC instant, in epoch seconds, at which the civil month begins.
    public static func startOfMonthEpochSeconds(year: Int, month: Int) -> Double {
        Double(daysFromCivil(year: year, month: month, day: 1) * secondsPerDay)
    }

    /// The UTC instant, in epoch seconds, at which the month `index` names begins.
    public static func startOfMonthEpochSeconds(atIndex index: Int) -> Double {
        let civil = yearMonth(atIndex: index)
        return startOfMonthEpochSeconds(year: civil.year, month: civil.month)
    }
}

// MARK: - Hinnant's days ⇄ civil algorithms

private extension CivilMonth {
    static let secondsPerDay = 86400
    /// Days per 400-year Gregorian era (the cycle over which the calendar repeats).
    static let daysPerEra = 146_097
    /// Days from 0000-03-01 to 1970-01-01 — the shift that moves the epoch onto a
    /// March-first year so leap day lands last and needs no special case.
    static let epochToEraShift = 719_468
    /// 0001-01-01T00:00:00Z. Clamping keeps a corrupt but finite `startedAt` from
    /// trapping `Int(_:)`; no real capture can fall outside this range.
    static let minEpochSeconds: Double = -62_135_596_800
    /// 9999-12-31T23:59:59Z.
    static let maxEpochSeconds: Double = 253_402_300_799

    /// Integer division that rounds toward negative infinity.
    ///
    /// Swift's `/` truncates toward zero, which would put every pre-1970 instant one
    /// day (and every negative month index one year) late.
    static func floorDiv(_ dividend: Int, _ divisor: Int) -> Int {
        let quotient = dividend / divisor
        let hasRemainder = dividend % divisor != 0
        return hasRemainder && ((dividend < 0) != (divisor < 0)) ? quotient - 1 : quotient
    }

    /// Whole days since 1970-01-01, flooring so a negative instant maps to the day
    /// that contains it.
    ///
    /// A non-finite timestamp is corrupt, not merely extreme, so it collapses to the
    /// epoch — which puts it in a long-aged month the compactor folds away, rather
    /// than at year 9999 where it would sit raw forever.
    static func daysSinceEpoch(fromEpochSeconds epochSeconds: Double) -> Int {
        guard epochSeconds.isFinite else { return 0 }
        let clamped = min(max(epochSeconds, minEpochSeconds), maxEpochSeconds)
        return floorDiv(Int(clamped.rounded(.down)), secondsPerDay)
    }

    /// Howard Hinnant's public-domain `civil_from_days`, restricted to `(year, month)`
    /// — the day-of-month step is dropped because no caller needs it.
    ///
    /// `doe`/`yoe`/`doy` are day-of-era, year-of-era and day-of-year in his notation;
    /// `shiftedMonth` is his `mp`, the month index of a March-first year (which is why
    /// leap day needs no special case: it falls at the END of the shifted year).
    static func civilDate(fromDaysSinceEpoch days: Int) -> (year: Int, month: Int) {
        let shifted = days + epochToEraShift
        let era = floorDiv(shifted, daysPerEra)
        let doe = shifted - era * daysPerEra // [0, 146096]
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365 // [0, 399]
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100) // [0, 365]
        let shiftedMonth = (5 * doy + 2) / 153 // [0, 11]
        let month = shiftedMonth + (shiftedMonth < 10 ? 3 : -9) // [1, 12]
        let year = yoe + era * 400 + (month <= 2 ? 1 : 0)
        return (year, month)
    }

    /// Howard Hinnant's public-domain `days_from_civil` — the exact inverse of
    /// ``civilDate(fromDaysSinceEpoch:)``.
    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let shiftedYear = year - (month <= 2 ? 1 : 0)
        let era = floorDiv(shiftedYear, 400)
        let yoe = shiftedYear - era * 400 // [0, 399]
        let doy = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1 // [0, 365]
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy // [0, 146096]
        return era * daysPerEra + doe - epochToEraShift
    }
}
