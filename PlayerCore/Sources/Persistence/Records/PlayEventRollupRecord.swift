import GRDB

/// A permanent monthly summary of one profile's plays for a single artist/genre pair.
///
/// Maps the `playEventRollup` table. Raw events age out after the rolling horizon;
/// these rows do not, which is what preserves long-term taste at bounded cost. The
/// compactor upserts against `UNIQUE(profileId, yearMonth, artistKey, genreKey)`.
public struct PlayEventRollupRecord: Codable, Sendable, Equatable, Hashable {
    /// Stands in for an unknown artist or genre. SQL treats `NULL != NULL`, so a NULL
    /// key would land in its own bucket on every `GROUP BY` and defeat the unique
    /// constraint; collapsing to the empty string keeps unknowns in one bucket.
    public static let unknownKey = ""

    /// Auto-incremented rowid primary key. `nil` until the record is inserted.
    public var id: Int64?
    /// Owning profile (`ON DELETE CASCADE`).
    public var profileId: Int64
    /// The summarised month, formatted `"YYYY-MM"`.
    public var yearMonth: String
    /// Artist, or ``unknownKey`` when absent.
    public var artistKey: String
    /// Genre, or ``unknownKey`` when absent.
    public var genreKey: String
    /// Plays recorded in the month.
    public var plays: Int
    /// Total seconds actually heard in the month.
    public var listenedSeconds: Double
    /// Plays cut short in the month.
    public var skips: Int
    /// Plays heard through to the end in the month.
    public var completions: Int

    public init(
        id: Int64? = nil,
        profileId: Int64,
        yearMonth: String,
        artistKey: String = PlayEventRollupRecord.unknownKey,
        genreKey: String = PlayEventRollupRecord.unknownKey,
        plays: Int = 0,
        listenedSeconds: Double = 0,
        skips: Int = 0,
        completions: Int = 0
    ) {
        self.id = id
        self.profileId = profileId
        self.yearMonth = yearMonth
        self.artistKey = artistKey
        self.genreKey = genreKey
        self.plays = plays
        self.listenedSeconds = listenedSeconds
        self.skips = skips
        self.completions = completions
    }
}

extension PlayEventRollupRecord: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "playEventRollup"

    public enum Columns {
        public static let id = Column(CodingKeys.id)
        public static let profileId = Column(CodingKeys.profileId)
        public static let yearMonth = Column(CodingKeys.yearMonth)
        public static let artistKey = Column(CodingKeys.artistKey)
        public static let genreKey = Column(CodingKeys.genreKey)
        public static let plays = Column(CodingKeys.plays)
        public static let listenedSeconds = Column(CodingKeys.listenedSeconds)
        public static let skips = Column(CodingKeys.skips)
        public static let completions = Column(CodingKeys.completions)
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
