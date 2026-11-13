// ListeningLocalTimeTests — the hour/weekday arithmetic, against hand-computed values.
//
// Every expectation here was worked out on paper from the UTC instant and the stored
// offset, NOT by running a `Calendar` — a test that used one would only prove the
// digest agrees with the machine it ran on, which is the exact property the digest is
// designed not to have.
import Foundation
@testable import Services
import Testing

@Suite("ListeningLocalTime")
struct ListeningLocalTimeTests {
    @Test("a positive offset shifts the hour forward")
    func positiveOffset() {
        // 2026-07-20T09:00:00Z at UTC+01:00 is local Monday 10:00.
        let hour = ListeningLocalTime.hourOfDay(startedAt: DigestInstant.mondayMorning, utcOffsetSeconds: 3600)
        let weekday = ListeningLocalTime.weekday(startedAt: DigestInstant.mondayMorning, utcOffsetSeconds: 3600)
        #expect(hour == 10)
        #expect(weekday == 1)
    }

    @Test("a NEGATIVE offset shifts the hour back, and can move the weekday")
    func negativeOffset() {
        // 2026-07-21T23:30:00Z at UTC−05:00 is local Tuesday 18:30 — same civil day.
        let hour = ListeningLocalTime.hourOfDay(startedAt: DigestInstant.tuesdayEvening, utcOffsetSeconds: -18000)
        let weekday = ListeningLocalTime.weekday(startedAt: DigestInstant.tuesdayEvening, utcOffsetSeconds: -18000)
        #expect(hour == 18)
        #expect(weekday == 2)
    }

    @Test("a negative offset that crosses midnight lands on the PREVIOUS local day")
    func negativeOffsetCrossesMidnight() {
        // 2026-07-22T02:00:00Z at UTC−05:00 is local Tuesday 21:00, not Wednesday.
        let started = DigestInstant.wednesdayAfternoon
        #expect(ListeningLocalTime.hourOfDay(startedAt: started, utcOffsetSeconds: -18000) == 21)
        #expect(ListeningLocalTime.weekday(startedAt: started, utcOffsetSeconds: -18000) == 2)
    }

    @Test("the widest real offset (+14 h) still lands in range")
    func widestOffset() {
        // 2026-07-22T02:00:00Z at UTC+14:00 is local Wednesday 16:00.
        let started = DigestInstant.wednesdayAfternoon
        #expect(ListeningLocalTime.hourOfDay(startedAt: started, utcOffsetSeconds: 50400) == 16)
        #expect(ListeningLocalTime.weekday(startedAt: started, utcOffsetSeconds: 50400) == 3)
    }

    @Test("a DST pair reports the SAME local hour from different UTC hours")
    func daylightSavingPair() {
        // Two Saturdays either side of a US spring-forward. The UTC hours differ by one
        // and so do the stored offsets, and the listener experienced both at 04:00.
        let winter = ListeningLocalTime.hourOfDay(startedAt: DigestInstant.dstBefore, utcOffsetSeconds: -28800)
        let summer = ListeningLocalTime.hourOfDay(startedAt: DigestInstant.dstAfter, utcOffsetSeconds: -25200)
        #expect(winter == 4)
        #expect(summer == 4)
        #expect(ListeningLocalTime.weekday(startedAt: DigestInstant.dstBefore, utcOffsetSeconds: -28800) == 6)
        #expect(ListeningLocalTime.weekday(startedAt: DigestInstant.dstAfter, utcOffsetSeconds: -25200) == 6)
    }

    @Test("the epoch itself is a Thursday")
    func epochWeekday() {
        #expect(ListeningLocalTime.weekday(localSeconds: 0) == 4)
        #expect(ListeningLocalTime.hourOfDay(localSeconds: 0) == 0)
    }

    @Test("the last second of a local day is hour 23, and the next second rolls over")
    func dayBoundary() {
        #expect(ListeningLocalTime.hourOfDay(localSeconds: 86399) == 23)
        #expect(ListeningLocalTime.hourOfDay(localSeconds: 86400) == 0)
        #expect(ListeningLocalTime.weekday(localSeconds: 86399) == 4)
        #expect(ListeningLocalTime.weekday(localSeconds: 86400) == 5)
    }

    @Test("localSeconds clamps below zero, so a pathological seed cannot escape the domain")
    func clampsBelowEpoch() {
        // Without the clamp, `truncatingRemainder` would keep the sign and `%` would
        // return a negative weekday — both out of range for a histogram index.
        let clamped = ListeningLocalTime.localSeconds(startedAt: 3600, utcOffsetSeconds: -36000)
        #expect(clamped == 0)
        #expect(ListeningLocalTime.hourOfDay(localSeconds: clamped) == 0)
        #expect(ListeningLocalTime.weekday(localSeconds: clamped) == 4)
    }

    @Test("a non-finite timestamp collapses to the epoch instead of trapping")
    func nonFiniteCollapses() {
        #expect(ListeningLocalTime.localSeconds(startedAt: .nan, utcOffsetSeconds: 0) == 0)
        #expect(ListeningLocalTime.localSeconds(startedAt: .infinity, utcOffsetSeconds: 0) == 0)
        #expect(ListeningLocalTime.hourOfDay(startedAt: .nan, utcOffsetSeconds: 3600) == 0)
    }

    @Test("an absurd but finite timestamp clamps rather than trapping Int()")
    func absurdTimestampClamps() {
        let clamped = ListeningLocalTime.localSeconds(startedAt: 1e30, utcOffsetSeconds: 0)
        #expect(clamped == ListeningLocalTime.maxLocalSeconds)
        #expect(ListeningLocalTime.hourOfDay(localSeconds: clamped) < ListeningLocalTime.hoursPerDay)
        #expect(ListeningLocalTime.weekday(localSeconds: clamped) < ListeningLocalTime.daysPerWeek)
    }

    @Test("every hour of a day maps to its own bucket, in order")
    func everyHourBuckets() {
        // 2026-07-20T00:00:00Z, offset 0 — a whole local day, hour by hour.
        let midnight: Double = 1_784_505_600
        let hours = (0 ..< 24).map {
            ListeningLocalTime.hourOfDay(startedAt: midnight + Double($0) * 3600, utcOffsetSeconds: 0)
        }
        #expect(hours == Array(0 ..< 24))
    }
}
