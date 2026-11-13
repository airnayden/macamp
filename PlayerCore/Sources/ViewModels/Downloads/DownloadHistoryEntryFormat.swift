// DownloadHistoryEntryFormat — how one `downloadHistory` row becomes text.
//
// Pure, shell-free and `nonisolated`, so the History pane's three derived strings can
// be asserted from `swift test --filter ViewModelTests` instead of only from a running
// window. Nothing here reads the clock, the database or the filesystem.
//
// ── THE ABSOLUTE TIMESTAMP IS THE POINT OF `utcOffsetSeconds` ────────────────
//
// v17 stores `utcOffsetSeconds` — seconds EAST of GMT at the moment the download
// finished — precisely so a row can be rendered at the wall-clock time it was actually
// taken. So ``absoluteTimestamp(downloadedAt:utcOffsetSeconds:locale:)`` renders the
// instant in a FIXED zone built from that stored offset and NEVER in `TimeZone.current`:
// a download taken at 21:40 in Sofia reads 21:40 forever, including after the listener
// flies to Tokyo or the clocks go back. Rendering it in the device's present zone would
// silently answer a different question ("what time would that instant be here, now?"),
// which is both wrong and — because it agrees with the stored offset whenever the
// listener has not moved — invisible in a test written against the machine's own zone.
// `DownloadHistoryEntryFormatTests` therefore pins two different offsets over ONE
// instant, which no device-zone implementation can satisfy.
//
// The RELATIVE phrase is the opposite case and is deliberately NOT offset-adjusted: an
// age is a difference between two instants, and a difference is the same number in
// every zone.
//
// This file imports only Foundation + Services; it MUST NOT import AppKit or UIKit
// (PlayerCore portability invariant), nor URLSession or Process (the downloader
// boundary gate — `PlayerCore/Sources/ViewModels` is scanned wholesale).
import Foundation
import Services

/// Derives a history row's date, badge and title text from its stored columns.
public enum DownloadHistoryEntryFormat {
    /// The zone the download was taken in, rebuilt from the stored offset.
    ///
    /// A fixed-offset zone, not a named one: the column records an offset, and the
    /// region it belonged to is not recoverable from it (several regions share +02:00,
    /// and the same region's offset moves across a DST boundary). An offset outside
    /// what `TimeZone` accepts degrades to GMT rather than trapping — a corrupt row
    /// should render slightly wrong, never crash the pane.
    public static func captureZone(utcOffsetSeconds: Int) -> TimeZone {
        TimeZone(secondsFromGMT: utcOffsetSeconds) ?? TimeZone(secondsFromGMT: 0) ?? .gmt
    }

    /// The wall-clock time the download finished, in the zone it finished in.
    ///
    /// - Parameters:
    ///   - downloadedAt: Seconds since the Unix epoch, as stored.
    ///   - utcOffsetSeconds: Seconds east of GMT at capture, as stored.
    ///   - locale: The locale to phrase and order the fields in. Defaulted for call
    ///     sites; passed explicitly by tests so an assertion does not depend on the
    ///     machine's region.
    public static func absoluteTimestamp(
        downloadedAt: TimeInterval,
        utcOffsetSeconds: Int,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        let zone = captureZone(utcOffsetSeconds: utcOffsetSeconds)
        // The calendar is pinned to the LOCALE's own system and to the capture zone
        // rather than left to default: `Date.FormatStyle` otherwise reaches for
        // `Calendar.autoupdatingCurrent`, whose zone is the device's — which is exactly
        // the reading this function exists to avoid.
        var calendar = Calendar(identifier: locale.calendar.identifier)
        calendar.locale = locale
        calendar.timeZone = zone
        return Date(timeIntervalSince1970: downloadedAt).formatted(
            Date.FormatStyle(
                date: .abbreviated,
                time: .shortened,
                locale: locale,
                calendar: calendar,
                timeZone: zone
            )
        )
    }

    /// How long ago the download finished, phrased for reading ("2 days ago").
    ///
    /// `RelativeDateTimeFormatter`'s `.named`/`.full` pairing — the configuration
    /// `.relative(presentation: .named)` wraps, which is the call `StatsRecentPlaysView`
    /// makes, so an age is phrased identically on both surfaces.
    ///
    /// The formatter is built here rather than cached because `RelativeDateTimeFormatter`
    /// is not `Sendable` and this function is `nonisolated`; a local instance never
    /// escapes, and a row asks for one phrase per body evaluation.
    ///
    /// - Parameter now: The instant to measure against. A parameter rather than a read
    ///   of the clock inside, so the phrase is assertable without tolerating a window —
    ///   which `FormatStyle`'s spelling of the same formatter does not allow.
    public static func relativeTimestamp(
        downloadedAt: TimeInterval,
        now: Date = Date(),
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.dateTimeStyle = .named
        formatter.unitsStyle = .full
        return formatter.localizedString(for: Date(timeIntervalSince1970: downloadedAt), relativeTo: now)
    }

    /// The container token a row's badge leads with — `"M4A"`, `"MP3"`, …
    ///
    /// Resolved THROUGH ``DownloadAudioFormat`` so a value this build knows is spelled
    /// the way this build spells it, with the stored token upper-cased as the fallback
    /// for a row written by a future version that learned a container this one has not.
    /// A format name is a codec token, never translatable copy.
    public static func formatToken(_ rawAudioFormat: String) -> String {
        let known = DownloadAudioFormat(rawValue: rawAudioFormat)
        return (known?.rawValue ?? rawAudioFormat).uppercased(with: Locale(identifier: "en_US_POSIX"))
    }

    /// The stored quality as this build's vocabulary, or `nil` for a token it does not
    /// know — in which case the badge shows the container alone rather than inventing
    /// a name for a tier it cannot describe.
    public static func quality(_ rawAudioQuality: String) -> DownloadAudioQuality? {
        DownloadAudioQuality(rawValue: rawAudioQuality)
    }

    /// What a row is titled: the captured title, falling back to the URL it came from.
    ///
    /// A download can legitimately finish with no title — the metadata pass may have
    /// failed while the transfer succeeded — and the source URL is the only other thing
    /// that names the row to the person who queued it. An all-whitespace title is
    /// treated as absent, not rendered as a blank row.
    public static func displayTitle(title: String?, sourceURL: String) -> String {
        guard let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return sourceURL
        }
        return title
    }
}
