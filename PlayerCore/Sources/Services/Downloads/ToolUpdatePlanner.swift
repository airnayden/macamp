// ToolUpdatePlanner — the pure decisions behind the yt-dlp self-update, with no I/O.
//
// Three questions, all answerable from values alone, so all three are table-testable:
//
//  1. **Is this published tag newer than what is installed?** yt-dlp does not use
//     semantic versions — every release is a DATE STAMP (`2026.08.19`), and nightly
//     builds append a sixth-digit time (`2026.08.19.232305`). Comparison is therefore
//     numeric-component-wise, never lexicographic on the whole string.
//  2. **Is the installed engine old enough to warrant nagging?** YouTube breaks
//     extraction on its own cadence, so an engine older than ``stalenessThresholdDays``
//     is treated as stale regardless of whether a newer tag has been published.
//  3. **Which hex line of a `SHA2-256SUMS` manifest covers this asset?** The manifest
//     is `<64 hex>  <filename>` per line; the installer refuses to swap a binary whose
//     bytes do not hash to the value this parser returns.
//
// Dates go through ``CivilMonth`` rather than `Calendar`/`TimeZone` for the reason
// that file already states at length: both are user- and location-dependent, so the
// same version string would age differently on two machines. `CivilMonth` is exact
// proleptic-Gregorian integer arithmetic, which is what a version STAMP deserves.
//
// This file imports only Foundation and MUST NOT import AppKit/UIKit, Process, or
// URLSession (PlayerCore portability invariant + the downloader boundary gate).
import Foundation

/// Version comparison, staleness, and checksum-manifest parsing for the engine update.
public enum ToolUpdatePlanner {
    // MARK: - Tunable constants

    /// How old an installed engine may be before it counts as stale.
    ///
    /// OWNER-TUNABLE: a product decision, not physics. yt-dlp ships roughly monthly
    /// and YouTube's extractor breakage lands between releases, so three releases'
    /// worth of drift is the point at which "you should update" stops being noise.
    public static let stalenessThresholdDays = 90

    /// The minimum gap between two automatic release-feed checks.
    ///
    /// OWNER-TUNABLE. The throttle exists so launching the app ten times in an hour
    /// makes one request, not ten — the feed is a courtesy, not a heartbeat.
    public static let autoCheckInterval: TimeInterval = 24 * 60 * 60

    /// Seconds in a day, used to express ``stalenessThresholdDays`` as an interval.
    public static let secondsPerDay: TimeInterval = 24 * 60 * 60

    /// The exact number of hex characters a SHA-256 digest occupies.
    public static let checksumHexLength = 64

    // MARK: - Version comparison

    /// Whether `candidate` names a strictly newer engine than `installed`.
    ///
    /// Comparison is component-wise over the numeric parts, so `2026.8.9` correctly
    /// precedes `2026.08.19` (lexicographic string comparison gets that backwards),
    /// and a nightly `2026.08.19.232305` correctly follows the stable `2026.08.19`
    /// it was cut from — a longer version that agrees on every shared component is
    /// the newer of the two.
    ///
    /// An UNPARSEABLE version on either side returns `false`. A comparison that
    /// cannot be decided must never claim "newer": offering an update on the strength
    /// of a version string the app does not understand is how a good binary gets
    /// replaced by a worse one.
    public static func isNewer(_ candidate: String, than installed: String) -> Bool {
        guard let lhs = numericComponents(of: candidate),
              let rhs = numericComponents(of: installed)
        else {
            return false
        }
        for index in 0 ..< max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    /// The ``ToolUpdateAvailability`` implied by an installed version and a published tag.
    ///
    /// The one place `isNewer` is turned into the protocol's vocabulary, so no caller
    /// has to remember which side of the comparison is which.
    public static func availability(installed: String, latest: String) -> ToolUpdateAvailability {
        isNewer(latest, than: installed)
            ? .updateAvailable(installed: installed, latest: latest)
            : .upToDate(version: installed)
    }

    /// The UTC instant a date-stamped version names, or `nil` when it is not one.
    ///
    /// Accepts `YYYY.MM.DD` plus any number of trailing components (a nightly's time
    /// suffix), which are deliberately ignored: staleness is measured in days, so the
    /// hour a nightly was cut is noise. The day is validated against the real length
    /// of its month, so `2026.02.30` is rejected rather than silently sliding into March.
    public static func releaseDate(from version: String) -> Date? {
        guard let components = numericComponents(of: version), components.count >= 3 else { return nil }
        let (year, month, day) = (components[0], components[1], components[2])
        guard (1970 ... 9999).contains(year), (1 ... 12).contains(month) else { return nil }
        let monthIndex = CivilMonth.monthIndex(year: year, month: month)
        let monthStart = CivilMonth.startOfMonthEpochSeconds(atIndex: monthIndex)
        let nextMonthStart = CivilMonth.startOfMonthEpochSeconds(atIndex: monthIndex + 1)
        let daysInMonth = Int((nextMonthStart - monthStart) / secondsPerDay)
        guard (1 ... daysInMonth).contains(day) else { return nil }
        return Date(timeIntervalSince1970: monthStart + Double(day - 1) * secondsPerDay)
    }

    /// Whether `version` is older than ``stalenessThresholdDays`` at `now`.
    ///
    /// An unparseable version is NOT stale. The app cannot date what it cannot read,
    /// and "we don't know" must not render as "your engine is out of date".
    public static func isStale(version: String, now: Date) -> Bool {
        guard let released = releaseDate(from: version) else { return false }
        return now.timeIntervalSince(released) > Double(stalenessThresholdDays) * secondsPerDay
    }

    // MARK: - Automatic-check throttle

    /// Whether enough time has passed since `lastCheck` to query the release feed again.
    ///
    /// A `nil` `lastCheck` means the feed has never been consulted, so the first launch
    /// checks. A `lastCheck` in the FUTURE also checks: that is a clock that moved
    /// backwards, and the alternative is a throttle that silently never expires again.
    public static func shouldAutoCheck(lastCheck: Date?, now: Date) -> Bool {
        guard let lastCheck else { return true }
        let elapsed = now.timeIntervalSince(lastCheck)
        return elapsed < 0 || elapsed >= autoCheckInterval
    }

    // MARK: - SHA2-256SUMS parsing

    /// The lowercase SHA-256 hex digest `manifest` publishes for `assetName`, if any.
    ///
    /// The manifest format is one `<64 hex>  <filename>` record per line. This parser
    /// is deliberately strict about the DIGEST (exactly 64 hex characters, or the line
    /// is skipped) and tolerant about the SEPARATOR and the name decoration, because
    /// the two-space form, a single tab, and coreutils' binary-mode `*name` marker all
    /// appear in the wild and none of them changes what the line means.
    ///
    /// Filenames are matched EXACTLY, case-sensitively: `yt-dlp_macos` and
    /// `yt-dlp_macos.zip` are different assets in the same manifest.
    public static func checksum(forAsset assetName: String, in manifest: String) -> String? {
        for line in manifest.split(whereSeparator: \.isNewline) {
            guard let record = checksumRecord(in: line), record.name == assetName else { continue }
            return record.digest
        }
        return nil
    }

    /// Whether `digest` is a well-formed lowercase-comparable SHA-256 hex string.
    public static func isValidChecksum(_ digest: String) -> Bool {
        digest.count == checksumHexLength && digest.allSatisfy(\.isHexDigit)
    }
}

// MARK: - Parsing internals

private extension ToolUpdatePlanner {
    /// The numeric components of a dot-separated version, or `nil` when any component
    /// is not a run of ASCII digits.
    ///
    /// `omittingEmptySubsequences: false` is load-bearing: the default would silently
    /// read `2026..19` as the two-component `2026.19` instead of rejecting it.
    static func numericComponents(of version: String) -> [Int]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        var components: [Int] = []
        components.reserveCapacity(parts.count)
        for part in parts {
            guard !part.isEmpty,
                  part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = Int(part)
            else {
                return nil
            }
            components.append(value)
        }
        return components
    }

    /// One `<digest> <name>` record, or `nil` for a blank line, a `#` comment, or a
    /// line whose first field is not a 64-character hex digest.
    static func checksumRecord(in line: some StringProtocol) -> (digest: String, name: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        let fields = trimmed.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard fields.count == 2 else { return nil }
        let digest = String(fields[0]).lowercased()
        guard isValidChecksum(digest) else { return nil }
        var name = fields[1].trimmingCharacters(in: .whitespaces)
        // coreutils writes ` *name` for a binary-mode digest; the marker is not part
        // of the file name and would otherwise make every lookup miss.
        if name.hasPrefix("*") { name.removeFirst() }
        guard !name.isEmpty else { return nil }
        return (digest, name)
    }
}
