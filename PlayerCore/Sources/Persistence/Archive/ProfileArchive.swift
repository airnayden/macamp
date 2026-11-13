// ProfileArchive — the versioned `.macampprofile` payload and its codec.
//
// One file = one profile's identity + its complete listening history (events,
// monthly rollups, replay heatmaps, per-track counters) + an OPT-IN preferences and
// custom-EQ snapshot. Importing it always creates a NEW profile; it never merges
// into, or overwrites, an existing one.
//
// ## The encoder contract (do not vary it)
// ``makeEncoder()`` is `JSONEncoder()` with `outputFormatting = [.sortedKeys]` and
// NOTHING else set — byte-for-byte the same contract `ListeningDigest.makeEncoder()`
// uses. Two consequences are load-bearing:
//   * `Data` renders as base64 (the default `dataEncodingStrategy`), which is how the
//     400-byte heatmap blob travels deterministically.
//   * There is no date strategy, because there are no `Date`s in the payload — every
//     instant is a plain `Double` of epoch seconds, which JSON round-trips exactly.
// Changing either would break the archive's own roundtrip test AND the
// `digest(imported) == digest(source)` guarantee it rests on.
//
// Foundation only — no AppKit/UIKit (PlayerCore portability invariant).
import Foundation

/// A complete, portable snapshot of one profile.
public struct ProfileArchive: Codable, Sendable, Equatable {
    /// The payload version this build writes.
    ///
    /// Bump ONLY when the meaning of an existing field changes. Adding a new optional
    /// field needs no bump: an older reader ignores it and a newer reader sees `nil`.
    public static let currentVersion = 1

    /// The file extension the shell writes and opens (`Alex.macampprofile`).
    public static let fileExtension = "macampprofile"

    /// The payload version this archive was written with.
    public var archiveVersion: Int
    /// Profile identity, minus the custom avatar path and the PIN.
    public var profile: ProfileArchiveProfile
    /// Every raw `playEvent` row for the profile.
    public var events: [ProfileArchivePlayEvent]
    /// Every permanent monthly `playEventRollup` row for the profile.
    public var rollups: [ProfileArchiveRollup]
    /// Every `playSegmentHeat` replay heatmap for the profile.
    public var segmentHeat: [ProfileArchiveSegmentHeat]
    /// Every `profileTrackState` counter row, each carrying its track's snapshot.
    public var trackStates: [ProfileArchiveTrackState]
    /// The portable preferences snapshot. Applied only when the importer opts in.
    public var settings: PortableSettings?
    /// Custom EQ presets. Applied only when the importer opts in, and never by
    /// overwriting an existing preset — see the rename-on-collision rule in
    /// ``ProfileArchiveImporter``.
    public var eqPresets: [ProfileArchiveEQPreset]

    public init(
        archiveVersion: Int = ProfileArchive.currentVersion,
        profile: ProfileArchiveProfile,
        events: [ProfileArchivePlayEvent] = [],
        rollups: [ProfileArchiveRollup] = [],
        segmentHeat: [ProfileArchiveSegmentHeat] = [],
        trackStates: [ProfileArchiveTrackState] = [],
        settings: PortableSettings? = nil,
        eqPresets: [ProfileArchiveEQPreset] = []
    ) {
        self.archiveVersion = archiveVersion
        self.profile = profile
        self.events = events
        self.rollups = rollups
        self.segmentHeat = segmentHeat
        self.trackStates = trackStates
        self.settings = settings
        self.eqPresets = eqPresets
    }

    /// Decodes tolerantly: every collection is optional on the wire and defaults to
    /// empty, so an archive from a build that predates a section still imports.
    ///
    /// Swift's synthesized decoder does NOT fall back to a property's default value,
    /// which is precisely why this is written by hand.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        archiveVersion = try container.decode(Int.self, forKey: .archiveVersion)
        profile = try container.decode(ProfileArchiveProfile.self, forKey: .profile)
        events = try container.decodeIfPresent([ProfileArchivePlayEvent].self, forKey: .events) ?? []
        rollups = try container.decodeIfPresent([ProfileArchiveRollup].self, forKey: .rollups) ?? []
        segmentHeat = try container
            .decodeIfPresent([ProfileArchiveSegmentHeat].self, forKey: .segmentHeat) ?? []
        trackStates = try container
            .decodeIfPresent([ProfileArchiveTrackState].self, forKey: .trackStates) ?? []
        settings = try container.decodeIfPresent(PortableSettings.self, forKey: .settings)
        eqPresets = try container.decodeIfPresent([ProfileArchiveEQPreset].self, forKey: .eqPresets) ?? []
    }
}

// MARK: - Codec

public extension ProfileArchive {
    /// The ONE encoder configuration the archive is ever written with.
    ///
    /// `[.sortedKeys]` and nothing else — same contract as `ListeningDigest`.
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    /// The matching decoder. Plain, because the encoder sets no strategy.
    static func makeDecoder() -> JSONDecoder {
        JSONDecoder()
    }

    /// This archive as deterministic `.macampprofile` bytes.
    func encodedJSON() throws -> Data {
        try Self.makeEncoder().encode(self)
    }

    /// Parses `.macampprofile` bytes, mapping every failure to a typed error.
    ///
    /// A truncated or corrupt file surfaces as
    /// ``ProfileArchiveError/malformed(_:)`` rather than a raw `DecodingError`, and a
    /// payload from a future build as
    /// ``ProfileArchiveError/unsupportedVersion(found:supported:)`` — both BEFORE any
    /// database write, so a bad file can never leave a partial profile behind.
    static func decoded(from data: Data) throws -> ProfileArchive {
        let archive: ProfileArchive
        do {
            archive = try makeDecoder().decode(ProfileArchive.self, from: data)
        } catch {
            throw ProfileArchiveError.malformed(String(describing: error))
        }
        guard archive.archiveVersion >= 1 else {
            throw ProfileArchiveError.malformed("archiveVersion must be >= 1")
        }
        guard archive.archiveVersion <= currentVersion else {
            throw ProfileArchiveError.unsupportedVersion(
                found: archive.archiveVersion,
                supported: currentVersion
            )
        }
        return archive
    }

    /// Every distinct track identity referenced anywhere in the payload, in a stable
    /// order. The importer seeds its matcher from this.
    var referencedTrackIdentities: [ProfileArchiveTrackIdentity] {
        var seen: Set<ProfileArchiveTrackIdentity> = []
        var ordered: [ProfileArchiveTrackIdentity] = []
        func append(_ identity: ProfileArchiveTrackIdentity) {
            guard seen.insert(identity).inserted else { return }
            ordered.append(identity)
        }
        for event in events {
            append(event.track)
        }
        for heat in segmentHeat {
            append(heat.track)
        }
        for state in trackStates {
            append(state.track)
        }
        return ordered
    }
}

// MARK: - Errors

/// Why an export or import could not complete.
public enum ProfileArchiveError: Error, Sendable, Equatable {
    /// No `profile` row with this id exists, so there is nothing to export.
    case profileNotFound(profileId: Int64)
    /// The bytes are not a decodable archive (truncated, corrupt, or not JSON). The
    /// payload is the underlying decoding failure, for logs — never for the UI.
    case malformed(String)
    /// The archive was written by a newer build than this one can read.
    case unsupportedVersion(found: Int, supported: Int)
    /// An archived EQ preset did not carry exactly
    /// ``ProfileArchiveEQPreset/bandCount`` band gains.
    case invalidEQPreset(name: String, bandCount: Int)
}

extension ProfileArchiveError: CustomStringConvertible {
    /// Developer-facing English (logs and tests). User-facing copy is localized in
    /// the shell, keyed off the case — never taken from here.
    public var description: String {
        switch self {
        case let .profileNotFound(profileId):
            "No profile with id \(profileId)"
        case let .malformed(detail):
            "The profile archive is not readable: \(detail)"
        case let .unsupportedVersion(found, supported):
            "Archive version \(found) is newer than the supported version \(supported)"
        case let .invalidEQPreset(name, bandCount):
            "EQ preset \"\(name)\" has \(bandCount) bands, expected \(ProfileArchiveEQPreset.bandCount)"
        }
    }
}

extension ProfileArchiveError: LocalizedError {
    public var errorDescription: String? {
        description
    }
}
