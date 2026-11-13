// ProfileArchiveExporter — gathers one profile into a `.macampprofile` file.
//
// Everything is read through the BOUNDED repository windows (`playEvents`,
// `rollups`, `allSegmentHeat`, `archivedTrackStates`), page by page, so exporting a
// profile with years of history never materialises more than one capped page of rows
// at a time. The encode and the file write happen in a detached task, off whatever
// actor asked for the export.
//
// The payload cannot leak a machine-local path: `ProfileArchiveProfile` has no
// `avatarImagePath` field, no archived row has a `filePath` field, `libraryRoot` is
// never read, and the karaoke cache directory preference is not part of
// ``PortableSettings``. That is enforced by the shape of the types, and pinned by a
// no-path-leak test.
import Foundation
import GRDB

/// Writes a profile and its complete listening history to a portable archive.
public struct ProfileArchiveExporter: Sendable {
    /// Rows per bounded page while gathering.
    public static let pageSize = PlayEventRepository.fetchLimit

    private let profiles: any ProfileRepositoryProviding
    private let events: any PlayEventRepositoryProviding
    private let heat: any PlaySegmentHeatRepositoryProviding
    private let tracks: TrackRepository
    private let eqPresets: any EQPresetStoring
    private let pageSize: Int

    public init(
        profiles: any ProfileRepositoryProviding,
        events: any PlayEventRepositoryProviding,
        heat: any PlaySegmentHeatRepositoryProviding,
        tracks: TrackRepository,
        eqPresets: any EQPresetStoring,
        pageSize: Int = ProfileArchiveExporter.pageSize
    ) {
        self.profiles = profiles
        self.events = events
        self.heat = heat
        self.tracks = tracks
        self.eqPresets = eqPresets
        self.pageSize = max(1, pageSize)
    }

    /// Convenience over the application database.
    public init(_ appDatabase: AppDatabase, pageSize: Int = ProfileArchiveExporter.pageSize) {
        self.init(
            profiles: ProfileRepository(appDatabase),
            events: PlayEventRepository(appDatabase),
            heat: PlaySegmentHeatRepository(appDatabase),
            tracks: TrackRepository(appDatabase),
            eqPresets: GRDBEQPresetStore(appDatabase),
            pageSize: pageSize
        )
    }

    /// Assembles the archive payload for one profile.
    ///
    /// - Parameters:
    ///   - profileId: The profile to export.
    ///   - settings: The shell's portable preferences snapshot, or `nil` to omit the
    ///     settings section. PlayerCore cannot read `AppSettings`, so the mapping is
    ///     the shell's job and the snapshot arrives here already built.
    /// - Throws: ``ProfileArchiveError/profileNotFound(profileId:)`` when the profile
    ///   does not exist.
    public func makeArchive(profileId: Int64, settings: PortableSettings?) async throws -> ProfileArchive {
        guard let profile = try profiles.profile(id: profileId) else {
            throw ProfileArchiveError.profileNotFound(profileId: profileId)
        }
        return try await ProfileArchive(
            profile: ProfileArchiveProfile(
                name: profile.name,
                lastName: profile.lastName,
                bio: profile.bio,
                avatarId: profile.avatarId,
                createdAt: profile.createdAt.timeIntervalSince1970
            ),
            events: gatherEvents(profileId: profileId),
            rollups: gatherRollups(profileId: profileId),
            segmentHeat: gatherSegmentHeat(profileId: profileId),
            trackStates: gatherTrackStates(profileId: profileId),
            settings: settings,
            eqPresets: gatherEQPresets()
        )
    }

    /// Assembles the archive and writes it atomically to `url`.
    ///
    /// The encode and the write both run in a detached task, so a main-actor caller
    /// never serialises a large history on the UI thread.
    public func export(profileId: Int64, settings: PortableSettings?, to url: URL) async throws {
        let archive = try await makeArchive(profileId: profileId, settings: settings)
        try await Task.detached(priority: .userInitiated) {
            let data = try archive.encodedJSON()
            try data.write(to: url, options: .atomic)
        }.value
    }

    /// The file name a profile should be offered under, extension included.
    public static func suggestedFileName(for profileName: String) -> String {
        let trimmed = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let illegal = CharacterSet(charactersIn: "/:\\")
        let cleaned = trimmed.components(separatedBy: illegal).joined(separator: "-")
        let base = cleaned.isEmpty ? "profile" : cleaned
        return "\(base).\(ProfileArchive.fileExtension)"
    }
}

// MARK: - Bounded gathering

private extension ProfileArchiveExporter {
    func gatherEvents(profileId: Int64) async throws -> [ProfileArchivePlayEvent] {
        var gathered: [ProfileArchivePlayEvent] = []
        var cursor: PageCursor<Double>?
        repeat {
            let page = try await events.playEvents(profileId: profileId, before: cursor, limit: pageSize)
            gathered.append(contentsOf: page.items.map(Self.archived))
            cursor = page.nextCursor
        } while cursor != nil
        return gathered
    }

    func gatherRollups(profileId: Int64) async throws -> [ProfileArchiveRollup] {
        var gathered: [ProfileArchiveRollup] = []
        var cursor: PageCursor<String>?
        repeat {
            let page = try await events.rollups(profileId: profileId, after: cursor, limit: pageSize)
            gathered.append(contentsOf: page.items.map(Self.archived))
            cursor = page.nextCursor
        } while cursor != nil
        return gathered
    }

    func gatherSegmentHeat(profileId: Int64) async throws -> [ProfileArchiveSegmentHeat] {
        var gathered: [ProfileArchiveSegmentHeat] = []
        var cursor: PageCursor<Int64>?
        repeat {
            let page = try await heat.allSegmentHeat(profileId: profileId, after: cursor, limit: pageSize)
            gathered.append(contentsOf: page.items.map(Self.archived))
            cursor = page.nextCursor
        } while cursor != nil
        return gathered
    }

    func gatherTrackStates(profileId: Int64) async throws -> [ProfileArchiveTrackState] {
        var gathered: [ProfileArchiveTrackState] = []
        var cursor: PageCursor<Int64>?
        repeat {
            let page = try await tracks.archivedTrackStates(
                profileId: profileId,
                after: cursor,
                limit: pageSize
            )
            gathered.append(contentsOf: page.items.map(\.archived))
            cursor = page.nextCursor
        } while cursor != nil
        return gathered
    }

    /// Custom presets only — the built-ins are code constants and are never stored,
    /// so they are never archived either. `loadAll` is already name-ordered and the
    /// preset table is user-sized (a handful of rows).
    func gatherEQPresets() throws -> [ProfileArchiveEQPreset] {
        try eqPresets.loadAll().map {
            ProfileArchiveEQPreset(
                name: $0.name,
                bandGains: $0.bandGains.map(Double.init),
                preamp: $0.preamp.map(Double.init)
            )
        }
    }
}

// MARK: - Record → payload

private extension ProfileArchiveExporter {
    static func archived(_ event: PlayEventRecord) -> ProfileArchivePlayEvent {
        ProfileArchivePlayEvent(
            track: ProfileArchiveTrackIdentity(
                artistName: event.artistName,
                title: event.title,
                albumTitle: event.albumTitle,
                durationSeconds: event.durationSeconds
            ),
            genre: event.genre,
            startedAt: event.startedAt,
            utcOffsetSeconds: event.utcOffsetSeconds,
            secondsListened: event.secondsListened,
            completionFraction: event.completionFraction,
            skipped: event.skipped,
            sourceSurface: event.sourceSurface,
            shuffle: event.shuffle
        )
    }

    static func archived(_ rollup: PlayEventRollupRecord) -> ProfileArchiveRollup {
        ProfileArchiveRollup(
            yearMonth: rollup.yearMonth,
            artistKey: rollup.artistKey,
            genreKey: rollup.genreKey,
            plays: rollup.plays,
            listenedSeconds: rollup.listenedSeconds,
            skips: rollup.skips,
            completions: rollup.completions
        )
    }

    static func archived(_ heat: PlaySegmentHeatRecord) -> ProfileArchiveSegmentHeat {
        ProfileArchiveSegmentHeat(
            track: ProfileArchiveTrackIdentity(
                artistName: heat.artistName,
                title: heat.title,
                albumTitle: heat.albumTitle,
                durationSeconds: heat.durationSeconds
            ),
            genre: heat.genre,
            bucketCounts: heat.bucketCounts,
            totalPasses: heat.totalPasses,
            updatedAt: heat.updatedAt
        )
    }
}
