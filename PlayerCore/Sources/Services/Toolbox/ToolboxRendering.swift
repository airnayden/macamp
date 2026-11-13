// ToolboxRendering — the ONE place a library row is turned into text a model sees.
//
// ── NO `filePath`, ANYWHERE, EVER ─────────────────────────────────────────────
//
// Every row a tool emits is built here, and nothing here reads
// ``TrackRecord/filePath``. That is the same survivability/privacy discipline the
// stats digest states ("no `filePath` or instrumental path appears in events,
// rollups, heatmaps, or archive payloads") applied to the tool layer: a rendered
// result crosses into a model's context — and, at the `.cloud` tier, off the
// machine — so the library's layout on disk must not be in it. Routing EVERY row
// through this file is what makes that assertable by a sweep over one file rather
// than by reviewing ten.
//
// Titles are rendered as-is (`Text(verbatim:)`'s rule, one layer down): a track
// title is data the listener owns, not app copy.
//
// This file imports Foundation + Persistence; it MUST NOT import AppKit or UIKit
// (PlayerCore portability invariant).
import Foundation
import Persistence

/// Row builders shared by every tool. See the file header for the one hard rule.
enum ToolboxRendering {
    /// The separator between a row's facets. A middle dot rather than a comma so a
    /// title containing a comma stays readable.
    static let separator = " · "

    /// `#12 Title — Artist · Album (1975)` — the compact identity line.
    static func compactLine(_ track: TrackRecord) -> String {
        var parts = ["#\(track.id ?? 0) \(title(track))"]
        if let artist = nonEmpty(track.artistName) {
            parts[0] += " — \(artist)"
        }
        if let album = nonEmpty(track.albumTitle) {
            parts.append(album + yearSuffix(track.year))
        } else if let year = track.year {
            parts.append(String(year))
        }
        return parts.joined(separator: separator)
    }

    /// ``compactLine(_:)`` plus genre, duration and availability — what
    /// `get_tracks` answers with.
    static func detailedLine(_ track: TrackRecord) -> String {
        var parts = [compactLine(track)]
        if let genre = nonEmpty(track.genre) {
            parts.append(genre)
        }
        if let duration = durationText(track.duration) {
            parts.append(duration)
        }
        parts.append(track.availability.rawValue)
        return parts.joined(separator: separator)
    }

    /// The machine form of a track row. Ids and display text only.
    static func payload(_ track: TrackRecord) -> ToolboxJSON {
        .object([
            "id": .int(track.id ?? 0),
            "title": string(track.title),
            "artist": string(track.artistName),
            "album": string(track.albumTitle),
            "genre": string(track.genre),
            "year": track.year.map { ToolboxJSON.int($0) } ?? .null,
            "durationSeconds": track.duration.map { ToolboxJSON.number($0) } ?? .null,
            "availability": .string(track.availability.rawValue),
        ])
    }

    /// A compact identity row.
    static func compactRow(_ track: TrackRecord) -> ToolResultRow {
        ToolResultRow(text: compactLine(track), payload: payload(track))
    }

    /// A row carrying genre, duration and availability too.
    static func detailedRow(_ track: TrackRecord) -> ToolResultRow {
        ToolResultRow(text: detailedLine(track), payload: payload(track))
    }

    /// `#12 Title — Artist` for something the PLAYER holds.
    ///
    /// Routed through this file for exactly the reason every other row is: a queue
    /// entry is rendered for a model too, and ``ToolboxPlaybackEntry`` deliberately
    /// carries no path for the sweep to find. The `#id` prefix is dropped when the
    /// entry has no library row, so the model is never handed `#0` to refer back to.
    ///
    /// Carries NO duration: the track this names is usually the one whose position
    /// is reported in the same sentence ("0:32 of 3:10"), and stating its length
    /// twice would spend an on-device budget on a repetition.
    static func compactLine(_ entry: ToolboxPlaybackEntry) -> String {
        var head = nonEmpty(entry.title) ?? "(untitled)"
        if let trackId = entry.trackId {
            head = "#\(trackId) " + head
        }
        guard let artist = nonEmpty(entry.artist) else { return head }
        return head + " — \(artist)"
    }

    /// ``compactLine(_:)`` plus the entry's length — a queued track has no playhead
    /// beside it, so its duration is worth a row.
    static func queueLine(_ entry: ToolboxPlaybackEntry) -> String {
        let head = compactLine(entry)
        guard let duration = durationText(entry.durationSeconds) else { return head }
        return head + separator + duration
    }

    /// The machine form of a player entry. Ids and display text only.
    static func payload(_ entry: ToolboxPlaybackEntry) -> ToolboxJSON {
        .object([
            "id": entry.trackId.map { ToolboxJSON.int($0) } ?? .null,
            "title": string(entry.title),
            "artist": string(entry.artist),
            "durationSeconds": entry.durationSeconds.map { ToolboxJSON.number($0) } ?? .null,
        ])
    }

    static func row(_ entry: ToolboxPlaybackEntry) -> ToolResultRow {
        ToolResultRow(text: queueLine(entry), payload: payload(entry))
    }

    /// Why a track cannot be played, in the words the availability state means.
    ///
    /// Total over ``Availability`` with no `default:` — a fourth state must break
    /// the build here rather than silently render as "unavailable".
    static func unavailableReason(_ availability: Availability) -> String {
        switch availability {
        case .present: "available"
        case .missing: "missing from disk"
        case .externalOffline: "on a drive that is not connected"
        }
    }
}

// MARK: - Field helpers

extension ToolboxRendering {
    /// The title, or a stable placeholder — a row with no title still has to be
    /// nameable so the model can refer to it by id.
    static func title(_ track: TrackRecord) -> String {
        nonEmpty(track.title) ?? "(untitled)"
    }

    /// `nil` for absent OR blank, so a padded-out tag renders as absent.
    static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    static func string(_ value: String?) -> ToolboxJSON {
        nonEmpty(value).map { ToolboxJSON.string($0) } ?? .null
    }

    static func yearSuffix(_ year: Int?) -> String {
        year.map { " (\($0))" } ?? ""
    }

    /// `m:ss`, or `h:mm:ss` past an hour. Locale-independent by construction —
    /// the digest's determinism rule applied to a rendered figure.
    static func durationText(_ seconds: Double?) -> String? {
        guard let seconds, seconds.isFinite, seconds > 0 else { return nil }
        let total = Int(seconds.rounded())
        let secondsPart = total % 60
        let minutesPart = (total / 60) % 60
        let hoursPart = total / 3600
        let padded = secondsPart < 10 ? "0\(secondsPart)" : String(secondsPart)
        guard hoursPart > 0 else { return "\(minutesPart):\(padded)" }
        let paddedMinutes = minutesPart < 10 ? "0\(minutesPart)" : String(minutesPart)
        return "\(hoursPart):\(paddedMinutes):\(padded)"
    }

    /// A whole-number-friendly rendering of a measured double.
    static func measure(_ value: Double, decimals: Int = 2) -> String {
        String(format: "%.\(decimals)f", value)
    }
}
