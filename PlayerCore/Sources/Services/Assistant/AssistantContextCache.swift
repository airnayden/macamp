// AssistantContextCache — the bounded prompt context, built once per hour instead
// of once per request.
//
// ``AssistantLibraryContext`` used to carry the profile's genre vocabulary and
// nothing else, because the aggregates behind "most-played artists" and the free-text
// summary had no measured source (Todo 17 recorded them as missing). They do now:
// ``ListeningDigest`` is exactly that aggregate, and it is derived from `playEvent` /
// `playEventRollup` / `playSegmentHeat` — so every claim this type puts in a prompt is
// one the statistics pipeline already measured. NOTHING here is invented; a facet with
// no rows simply stays empty.
//
// The catch is cost. A digest is a full keyset scan of a profile's listening history,
// and `FMAssistantBackend` asks its `contextProvider` for a context on EVERY parse. So
// the result is memoised, keyed by `(profileId, digestVersion, generatedAt-bucket)`:
//
//  * `profileId` — the whole context is profile-scoped, so two profiles never share an
//    entry. This is also what makes a profile switch safe: the incoming profile misses.
//  * `digestVersion` — a payload this build does not recognise can never be served.
//  * `generatedAt-bucket` — ``bucketSeconds`` of wall clock. Listening history moves
//    slowly; an hour-old picture of a listener's top genres is still a true one, and
//    the alternative is re-scanning the history between two typed sentences.
//
// The entry is STORED under the digest's OWN `digestVersion` / `generatedAt`, not under
// the bucket that was probed — the stamp a reader validates is therefore the one the
// data actually carries, so a build that straddles a bucket boundary expires an hour
// early rather than an hour late.
//
// At most one entry per profile is retained: a new bucket REPLACES the slot rather than
// growing the map, so the cache is O(profiles) forever and needs no eviction policy.
//
// A digest failure is SWALLOWED and degrades to a genres-only context. The assistant's
// job is to parse a request; losing the listener's taste summary makes the prompt
// thinner, never wrong, and must not turn a parse into an error.
import Foundation

/// Memoises one profile's ``AssistantLibraryContext`` for ``bucketSeconds``.
public actor AssistantContextCache {
    /// Wall-clock width of one cache bucket. An hour: long enough that a
    /// conversation costs one digest scan, short enough that today's listening is
    /// reflected within the same session.
    public static let bucketSeconds: TimeInterval = 3600

    /// One memoised context plus the two stamps that decide whether it is still good.
    private struct Entry {
        let digestVersion: Int
        let generatedAtBucket: Int64
        let context: AssistantLibraryContext
    }

    private let genres: @Sendable (Int64) async -> [String]
    private let digests: (any ListeningDigestBuilding)?
    private let now: @Sendable () -> Date
    private var entries: [Int64: Entry] = [:]

    /// - Parameters:
    ///   - genres: The profile's genre vocabulary — the list the model is told to
    ///     choose from, and the list its answer is validated against. A closure
    ///     rather than a repository so this type stays free of `Persistence`.
    ///   - digests: The listening digest behind ``AssistantLibraryContext/artists``
    ///     and ``AssistantLibraryContext/summary``. `nil` yields a genres-only
    ///     context, which is what a preview or a hermetic UI-test run wants.
    ///   - now: The clock the bucket is derived from. Injected so a test can cross a
    ///     boundary without waiting an hour.
    public init(
        genres: @escaping @Sendable (Int64) async -> [String],
        digests: (any ListeningDigestBuilding)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.genres = genres
        self.digests = digests
        self.now = now
    }

    /// The profile's prompt context, rebuilt only when its bucket has expired.
    public func context(profileId: Int64) async -> AssistantLibraryContext {
        let bucket = Self.bucket(for: now())
        if let entry = entries[profileId],
           entry.digestVersion == ListeningDigest.currentVersion,
           entry.generatedAtBucket == bucket
        {
            return entry.context
        }
        let vocabulary = await genres(profileId)
        let digest = await digest(profileId: profileId)
        let context = AssistantLibraryContext(
            genres: vocabulary,
            artists: Self.topArtists(in: digest),
            summary: Self.summary(for: digest)
        )
        entries[profileId] = Entry(
            digestVersion: digest?.digestVersion ?? ListeningDigest.currentVersion,
            generatedAtBucket: digest.map { Self.bucket(forEpochSeconds: Double($0.generatedAt)) } ?? bucket,
            context: context
        )
        return context
    }

    /// Drops every memoised context. The library's genre vocabulary changes on a
    /// scan, so a caller that has just imported music can force the next request to
    /// see it rather than waiting out the bucket.
    public func invalidate() {
        entries.removeAll()
    }

    private func digest(profileId: Int64) async -> ListeningDigest? {
        guard let digests else { return nil }
        return try? await digests.buildDigest(profileId: profileId)
    }
}

// MARK: - Bucketing

public extension AssistantContextCache {
    /// The bucket index `date` falls in — integer division of epoch seconds, so it
    /// needs no `Calendar` and is therefore locale- and timezone-independent, the
    /// same discipline ``ListeningDigest`` itself follows.
    static func bucket(for date: Date) -> Int64 {
        bucket(forEpochSeconds: date.timeIntervalSince1970)
    }

    static func bucket(forEpochSeconds seconds: Double) -> Int64 {
        Int64((max(0, seconds) / bucketSeconds).rounded(.down))
    }
}

// MARK: - Digest projection

/// The digest → prompt projection.
///
/// Pure and public for the same reason ``AssistantLibraryContext/instructionsText(locale:)``
/// is: these produce the EXACT text a prompt carries, so a test can measure that text
/// without standing up a cache, a database or a model.
public extension AssistantContextCache {
    /// The window a taste summary is drawn from: the most recent span that actually
    /// has plays. Preferring recency keeps the picture current; falling back keeps a
    /// listener who has not opened the app this month from getting an empty prompt.
    static let summaryWindows: [ListeningWindowKind] = [.last30Days, .last12Months, .allTime]

    /// Named genres in one summary sentence. Three is what fits the sentence without
    /// reading as a dump of the whole library.
    static let summaryGenreLimit = 3

    static func preferredWindow(in digest: ListeningDigest?) -> ListeningWindowDigest? {
        guard let digest else { return nil }
        return summaryWindows
            .compactMap { digest.window($0) }
            .first { $0.totalPlays > 0 }
    }

    /// The profile's most-played artist names, in the digest's own ranked order.
    /// Unnamed entries are dropped — `""` is how a snapshot records "unknown", and
    /// offering it to the model would name an artist that does not exist.
    static func topArtists(in digest: ListeningDigest?) -> [String] {
        preferredWindow(in: digest)?.topArtists.map(\.name).filter { !$0.isEmpty } ?? []
    }

    /// One factual sentence about what this listener actually plays, or `""` when
    /// nothing was measured.
    ///
    /// The window is NAMED in the sentence so the claim is exact: "recently" would be
    /// a different statement depending on which fallback produced it.
    static func summary(for digest: ListeningDigest?) -> String {
        guard let window = preferredWindow(in: digest) else { return "" }
        let genres = window.topGenres
            .map(\.name)
            .filter { !$0.isEmpty }
            .prefix(summaryGenreLimit)
        guard !genres.isEmpty else { return "" }
        return "\(phrase(for: window.window)) this listener played mostly: \(genres.joined(separator: ", "))."
    }

    /// English prompt wording for a window. Prompt text is not user-facing copy — it
    /// is the same English the rest of `instructionsText(locale:)` is written in — so
    /// it deliberately does not go through a String Catalog.
    static func phrase(for window: ListeningWindowKind) -> String {
        switch window {
        case .last7Days: "In the last week"
        case .last30Days: "In the last month"
        case .last12Months: "In the last year"
        case .allTime: "Across their whole history"
        }
    }
}
