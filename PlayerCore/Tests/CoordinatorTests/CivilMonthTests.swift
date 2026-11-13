// CivilMonthTests — the determinism primitive the whole statistics layer stands on.
//
// Every expected value below is a hand-computed UTC instant, NOT a value produced by
// `Calendar`. That is the point: if this file ever needs `Calendar` to state its own
// expectations, the helper has stopped being independent of the user's locale,
// calendar identity and time zone — which is the property a digest's byte-equality
// across machines depends on.
import Foundation
@testable import Services
import Testing

@Suite("CivilMonth — UTC civil-month arithmetic")
struct CivilMonthTests {
    // Hand-computed UTC instants (seconds since 1970-01-01T00:00:00Z).
    private static let epoch: Double = 0 // 1970-01-01
    private static let lastSecondOf1969: Double = -1 // 1969-12-31T23:59:59Z
    private static let year1900: Double = -2_208_988_800 // 1900-01-01
    private static let leapDay2024: Double = 1_709_208_000 // 2024-02-29T12:00:00Z
    private static let march2000: Double = 951_868_800 // 2000-03-01
    private static let july2026: Double = 1_784_937_600 // 2026-07-25
    private static let july2024: Double = 1_719_792_000 // 2024-07-01

    /// `civilYearMonth` rendered as its rollup key, so assertions read as dates and
    /// no tuple ever reaches the `#expect` macro.
    private func key(_ epochSeconds: Double) -> String {
        let civil = CivilMonth.civilYearMonth(fromEpochSeconds: epochSeconds)
        return CivilMonth.yearMonthKey(year: civil.year, month: civil.month)
    }

    @Test("known instants map to their UTC civil month")
    func knownInstants() {
        #expect(key(Self.epoch) == "1970-01")
        #expect(key(Self.lastSecondOf1969) == "1969-12")
        #expect(key(Self.year1900) == "1900-01")
        #expect(key(Self.leapDay2024) == "2024-02")
        #expect(key(Self.march2000) == "2000-03")
        #expect(key(Self.july2026) == "2026-07")
    }

    @Test("the last second of a month still belongs to that month")
    func monthEndBoundary() {
        #expect(key(Self.july2024) == "2024-07")
        #expect(key(Self.july2024 - 1) == "2024-06")
    }

    @Test("a sub-second instant floors onto its own day, in both directions")
    func fractionalSecondsFloor() {
        #expect(key(0.75) == "1970-01")
        // -0.25 s is still 1969-12-31: truncating toward zero here would move the
        // instant a whole month forward.
        #expect(key(-0.25) == "1969-12")
    }

    @Test("month indices are contiguous and order months chronologically")
    func monthIndexOrdering() {
        let december = CivilMonth.monthIndex(year: 2024, month: 12)
        let january = CivilMonth.monthIndex(year: 2025, month: 1)
        #expect(january == december + 1)
        let span = CivilMonth.monthIndex(year: 2026, month: 7) - CivilMonth.monthIndex(year: 2024, month: 7)
        #expect(span == 24)
    }

    @Test("monthIndex and yearMonth are exact inverses, including before year 0")
    func monthIndexRoundtrips() {
        for year in [-1, 0, 1, 1899, 1970, 2024, 2026] {
            for month in 1 ... 12 {
                let index = CivilMonth.monthIndex(year: year, month: month)
                let civil = CivilMonth.yearMonth(atIndex: index)
                #expect(civil.year == year)
                #expect(civil.month == month)
            }
        }
    }

    @Test("startOfMonth lands on the month it names, and one second earlier does not")
    func startOfMonthRoundtrips() {
        let first = CivilMonth.monthIndex(year: 2023, month: 1)
        let last = CivilMonth.monthIndex(year: 2027, month: 12)
        for index in first ... last {
            let start = CivilMonth.startOfMonthEpochSeconds(atIndex: index)
            #expect(CivilMonth.monthIndex(fromEpochSeconds: start) == index)
            #expect(CivilMonth.monthIndex(fromEpochSeconds: start - 1) == index - 1)
        }
    }

    @Test("startOfMonth matches hand-computed instants")
    func startOfMonthKnownValues() {
        #expect(CivilMonth.startOfMonthEpochSeconds(year: 1970, month: 1) == 0)
        #expect(CivilMonth.startOfMonthEpochSeconds(year: 2024, month: 7) == Self.july2024)
        #expect(CivilMonth.startOfMonthEpochSeconds(year: 2026, month: 7) == 1_782_864_000)
        #expect(CivilMonth.startOfMonthEpochSeconds(year: 1900, month: 1) == Self.year1900)
    }

    @Test("keys are zero-padded so lexicographic order equals chronological order")
    func yearMonthKeyFormatting() {
        #expect(CivilMonth.yearMonthKey(year: 2026, month: 7) == "2026-07")
        #expect(CivilMonth.yearMonthKey(year: 2026, month: 12) == "2026-12")
        #expect(CivilMonth.yearMonthKey(fromEpochSeconds: Self.july2026) == "2026-07")
        #expect(CivilMonth.yearMonthKey(atIndex: CivilMonth.monthIndex(year: 2024, month: 6)) == "2024-06")
        #expect("2024-06" < "2024-07")
        #expect("2024-12" < "2025-01")
    }

    @Test("a non-finite timestamp collapses to the epoch instead of trapping")
    func nonFiniteInputIsSafe() {
        #expect(key(.nan) == "1970-01")
        #expect(key(.infinity) == "1970-01")
        #expect(key(-.infinity) == "1970-01")
    }

    @Test("a finite but absurd timestamp clamps instead of overflowing Int")
    func absurdFiniteInputClamps() {
        #expect(key(1e300) == "9999-12")
        #expect(key(-1e300) == "0001-01")
    }
}
