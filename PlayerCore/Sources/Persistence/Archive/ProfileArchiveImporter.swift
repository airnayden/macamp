// ProfileArchiveImporter — restores a `.macampprofile` as a brand-new profile.
//
// Import is ALWAYS additive: it allocates a fresh profile row and never merges into,
// renames, or overwrites an existing one (Guest keeps id 1). Three classes of state
// are dropped on the way in, by construction rather than by policy:
//
//   * `avatarImagePath` — machine-local, nulled.
//   * `libraryRoot` rows — never exported, never written.
//   * the PIN (`pinHash` / `pinSalt`) — never exported, always nil on the new row.
//
// The whole write is ONE `dbWriter.write` transaction, so a malformed payload — a
// truncated heatmap blob, an EQ preset with the wrong band count — rolls the entire
// import back and leaves no partial profile behind.
//
// Settings and custom EQ presets are an OPT-IN second step. Even then, nothing is
// overwritten: presets are inserted under a renamed title when the name is taken,
// and the preferences snapshot is handed back to the SHELL to apply (PlayerCore
// cannot, and must not, reach UserDefaults).
import Foundation
import GRDB

/// What an import actually did, including everything it had to drop.
public struct ProfileArchiveImportSummary: Sendable, Equatable {
    /// The rowid of the newly created profile.
    public var profileId: Int64
    /// Raw play events restored. Always the full archived set.
    public var importedEvents: Int
    /// Monthly rollups restored. Always the full archived set.
    public var importedRollups: Int
    /// Replay heatmaps restored. Always the full archived set.
    public var importedSegmentHeat: Int
    /// Heatmaps whose track matched nothing local and were filed under a synthetic
    /// negative id. They still feed every digest facet from their own snapshot.
    public var unmatchedSegmentHeat: Int
    /// Per-track counter rows restored (matched tracks only).
    public var importedTrackStates: Int
    /// Counter rows DROPPED because their track matched nothing local. The foreign
    /// key demands a real local track, so there is nowhere to put them — surfaced
    /// here so the UI can say so rather than losing them silently.
    public var droppedTrackStates: Int
    /// Custom EQ presets inserted. Zero unless the caller opted in.
    public var importedEQPresets: Int
    /// The names presets had to be inserted under because the original was taken.
    public var renamedEQPresets: [String]
    /// The archived preferences snapshot, for the SHELL to apply as globals. `nil`
    /// unless the caller opted in AND the archive carried one.
    public var settings: PortableSettings?

    public init(
        profileId: Int64,
        importedEvents: Int = 0,
        importedRollups: Int = 0,
        importedSegmentHeat: Int = 0,
        unmatchedSegmentHeat: Int = 0,
        importedTrackStates: Int = 0,
        droppedTrackStates: Int = 0,
        importedEQPresets: Int = 0,
        renamedEQPresets: [String] = [],
        settings: PortableSettings? = nil
    ) {
        self.profileId = profileId
        self.importedEvents = importedEvents
        self.importedRollups = importedRollups
        self.importedSegmentHeat = importedSegmentHeat
        self.unmatchedSegmentHeat = unmatchedSegmentHeat
        self.importedTrackStates = importedTrackStates
        self.droppedTrackStates = droppedTrackStates
        self.importedEQPresets = importedEQPresets
        self.renamedEQPresets = renamedEQPresets
        self.settings = settings
    }
}

/// Restores a `.macampprofile` archive into the local database.
public struct ProfileArchiveImporter: Sendable {
    /// Rows per page while scanning the local library for identity matches.
    public static let pageSize = TrackRepository.archiveFetchLimit

    /// The fallback disambiguating suffix for a colliding EQ preset name.
    ///
    /// A preset name is user-visible, so the shell passes a LOCALIZED suffix; this
    /// English default exists only so a headless caller (tests, the CLI) still gets
    /// a sensible name.
    public static let defaultImportedPresetSuffix = "(imported)"

    let dbWriter: any DatabaseWriter
    private let tracks: TrackRepository
    private let pageSize: Int

    public init(_ dbWriter: any DatabaseWriter, pageSize: Int = ProfileArchiveImporter.pageSize) {
        self.dbWriter = dbWriter
        tracks = TrackRepository(dbWriter)
        self.pageSize = max(1, pageSize)
    }

    /// Convenience over the application database.
    public init(_ appDatabase: AppDatabase, pageSize: Int = ProfileArchiveImporter.pageSize) {
        self.init(appDatabase.writer, pageSize: pageSize)
    }

    /// Reads, decodes and imports an archive file.
    ///
    /// Decoding happens BEFORE the transaction opens, so a truncated or corrupt file
    /// surfaces as ``ProfileArchiveError`` with nothing written at all.
    @discardableResult
    public func importArchive(
        at url: URL,
        applyingSettingsAndEQPresets applying: Bool,
        importedPresetSuffix: String = ProfileArchiveImporter.defaultImportedPresetSuffix
    ) async throws -> ProfileArchiveImportSummary {
        let archive = try await Task.detached(priority: .userInitiated) {
            let data = try Data(contentsOf: url)
            return try ProfileArchive.decoded(from: data)
        }.value
        return try await importArchive(
            archive,
            applyingSettingsAndEQPresets: applying,
            importedPresetSuffix: importedPresetSuffix
        )
    }

    /// Imports an already-decoded archive as a NEW profile.
    ///
    /// - Parameters:
    ///   - archive: The decoded payload.
    ///   - applying: Whether to also insert the archived custom EQ presets and hand
    ///     the preferences snapshot back for the shell to apply. Statistics restore
    ///     unconditionally; only these two globals are opt-in.
    ///   - importedPresetSuffix: Appended to a preset name that is already taken.
    @discardableResult
    public func importArchive(
        _ archive: ProfileArchive,
        applyingSettingsAndEQPresets applying: Bool,
        importedPresetSuffix: String = ProfileArchiveImporter.defaultImportedPresetSuffix
    ) async throws -> ProfileArchiveImportSummary {
        let matcher = try await makeMatcher(for: archive)
        let plan = ProfileArchiveWritePlan(
            archive: archive,
            matcher: matcher,
            applyingSettingsAndEQPresets: applying,
            importedPresetSuffix: importedPresetSuffix
        )
        return try await dbWriter.write { db in
            try plan.write(into: db)
        }
    }

    /// Walks the LOCAL library one bounded page at a time, offering every row to a
    /// matcher seeded with the archive's identities.
    ///
    /// Memory is bounded by the archive (already fully in memory), not by the
    /// library, and the scan is skipped outright when the archive names no tracks.
    func makeMatcher(for archive: ProfileArchive) async throws -> ProfileArchiveTrackMatcher {
        var matcher = ProfileArchiveTrackMatcher(identities: archive.referencedTrackIdentities)
        guard !matcher.isEmpty else { return matcher }
        var cursor: PageCursor<Int64>?
        repeat {
            let page = try await tracks.archiveTrackIdentities(after: cursor, limit: pageSize)
            for local in page.items {
                matcher.offer(local)
            }
            cursor = page.nextCursor
        } while cursor != nil
        return matcher
    }
}
