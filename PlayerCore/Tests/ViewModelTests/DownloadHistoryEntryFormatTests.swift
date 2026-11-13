// DownloadHistoryEntryFormatTests — the three strings a History row derives from its
// stored columns.
//
// Split from `DownloadHistoryViewModelTests.swift` for the SwiftLint 400-line file
// budget. The load-bearing case is `theAbsoluteTimestampIgnoresTheDeviceZone`: the
// capture-local timestamp is the whole reason v17 stores `utcOffsetSeconds`, and a
// single-offset fixture cannot tell a correct implementation from one that simply read
// `TimeZone.current` on a machine that happens to sit at that offset.
import Foundation
import Testing
@testable import ViewModels

/// 2023-11-14 22:13:20 UTC — chosen so a positive offset crosses midnight into the NEXT
/// day and a negative one falls back into the afternoon, which moves the DATE field and
/// not merely the clock.
private let fixtureEpoch: TimeInterval = 1_700_000_000

struct DownloadHistoryEntryFormatTests {
    private let posix = Locale(identifier: "en_US_POSIX")

    /// Foundation separates the time from its AM/PM marker with a NARROW NO-BREAK
    /// SPACE (U+202F), which renders identically to a plain space and makes a failed
    /// comparison read as `"…12:13 AM" == "…12:13 AM"`. The claim under test is the
    /// wall clock, not which space character this OS version chose, so both
    /// non-breaking forms are folded before comparing.
    private func folded(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\u{202F}", with: " ")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    /// `fixtureEpoch` is 2023-11-14 22:13:20 UTC, chosen so a positive offset crosses
    /// midnight into the NEXT day and a negative one falls back into the afternoon —
    /// the date field moves, not just the clock, so a broken implementation cannot
    /// coincidentally agree.
    @Test func theAbsoluteTimestampRendersTheWallClockOfTheCaptureZone() {
        let east = DownloadHistoryEntryFormat.absoluteTimestamp(
            downloadedAt: fixtureEpoch,
            utcOffsetSeconds: 7200,
            locale: posix
        )
        let west = DownloadHistoryEntryFormat.absoluteTimestamp(
            downloadedAt: fixtureEpoch,
            utcOffsetSeconds: -18000,
            locale: posix
        )

        #expect(folded(east) == "Nov 15, 2023 at 12:13 AM")
        #expect(folded(west) == "Nov 14, 2023 at 5:13 PM")
    }

    /// The claim that matters and the one a single-offset fixture cannot make: ONE
    /// instant, two stored offsets, two different answers. An implementation that
    /// rendered in `TimeZone.current` returns the same string twice and fails here
    /// on every machine, in every zone.
    @Test func theAbsoluteTimestampIgnoresTheDeviceZone() {
        let sofia = DownloadHistoryEntryFormat.absoluteTimestamp(
            downloadedAt: fixtureEpoch,
            utcOffsetSeconds: 7200,
            locale: posix
        )
        let tokyo = DownloadHistoryEntryFormat.absoluteTimestamp(
            downloadedAt: fixtureEpoch,
            utcOffsetSeconds: 32400,
            locale: posix
        )

        #expect(sofia != tokyo)
        #expect(folded(tokyo) == "Nov 15, 2023 at 7:13 AM")
    }

    @Test func aCaptureZoneIsBuiltFromTheStoredOffset() {
        #expect(DownloadHistoryEntryFormat.captureZone(utcOffsetSeconds: 7200).secondsFromGMT() == 7200)
        #expect(DownloadHistoryEntryFormat.captureZone(utcOffsetSeconds: -18000).secondsFromGMT() == -18000)
    }

    /// A corrupt offset must degrade, never trap: the pane still has to draw the row.
    @Test func anImpossibleOffsetFallsBackToGMT() {
        #expect(DownloadHistoryEntryFormat.captureZone(utcOffsetSeconds: 999_999).secondsFromGMT() == 0)
    }

    @Test func theRelativePhraseIsMeasuredAgainstTheSuppliedInstant() {
        let now = Date(timeIntervalSince1970: fixtureEpoch + 2 * 86400)

        let phrase = DownloadHistoryEntryFormat.relativeTimestamp(
            downloadedAt: fixtureEpoch,
            now: now,
            locale: posix
        )

        #expect(phrase == "2 days ago")
    }

    @Test func theBadgeNamesTheStoredContainer() {
        #expect(DownloadHistoryEntryFormat.formatToken("m4a") == "M4A")
        #expect(DownloadHistoryEntryFormat.formatToken("flac") == "FLAC")
    }

    /// A row written by a later build naming a container this one does not know still
    /// shows what it was, rather than a blank badge.
    @Test func anUnknownContainerTokenSurvivesAsItself() {
        #expect(DownloadHistoryEntryFormat.formatToken("wav") == "WAV")
        #expect(DownloadHistoryEntryFormat.quality("insane") == nil)
    }

    @Test func aKnownQualityResolvesToThisBuildsVocabulary() {
        #expect(DownloadHistoryEntryFormat.quality("best") == .best)
        #expect(DownloadHistoryEntryFormat.quality("medium") == .medium)
    }

    @Test func aTitlelessRowIsNamedByItsSourceURL() {
        let url = "https://www.youtube.com/watch?v=abc"

        #expect(DownloadHistoryEntryFormat.displayTitle(title: nil, sourceURL: url) == url)
        #expect(DownloadHistoryEntryFormat.displayTitle(title: "   ", sourceURL: url) == url)
        #expect(DownloadHistoryEntryFormat.displayTitle(title: "Real", sourceURL: url) == "Real")
    }
}
