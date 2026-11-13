import GRDB

/// The availability state of a track's backing file.
///
/// Stored as `TEXT` in the `track.availability` column and guarded by a `CHECK`
/// constraint that permits only these three raw values. Modelled as an enum
/// (never a `Bool`) so the scanner / availability subsystem can distinguish a
/// file that is gone from one that lives on an external volume that is merely
/// not currently mounted.
public enum Availability: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    /// The file is present and reachable on a local volume.
    case present
    /// The file used to exist but can no longer be found.
    case missing
    /// The file lives on an external volume that is not currently mounted.
    case externalOffline
}
