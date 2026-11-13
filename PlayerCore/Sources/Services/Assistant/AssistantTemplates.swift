// AssistantTemplates — the tier that always answers.
//
// Naming and narration both have a FoundationModels tier that can refuse, throttle,
// be turned off, or not exist on the running OS. Neither seam is allowed to leave a
// draft nameless or a stats card blank, so this file holds the deterministic tier
// underneath: a pure function from the SAME aggregates the model gets
// (``PlaylistNamingContext`` / ``InsightNarrationContext``) to a localized string,
// plus the two ladders that route a failure into it.
//
// ── MIXED CONSTRUCTION, AND WHY IT IS CORRECT ────────────────────────────────
//
// A fallback name is localized CHROME with DATA pushed into it: the template shape
// comes from ``AssistantStrings`` (a String Catalog key, translated, reorderable),
// while the genre, artist, decade, count and clock tokens are read verbatim out of
// the library and are never translated. The ASSEMBLED result is then data in full —
// it gets persisted into `playlist.name` and rendered `Text(verbatim:)`, exactly
// like a model-generated name. See ``AssistantStrings``' header.
//
// ── PURITY ────────────────────────────────────────────────────────────────────
//
// Everything here is a pure function of `(context, locale)`: no clock, no
// randomness, no I/O, no FoundationModels reference, no `@available`. That is what
// lets the whole fallback path be table-tested on any host, and what lets the
// ladders below be exercised with a scripted failure instead of a real refusal.
import Foundation

// MARK: - Rendering

public extension LocalizedStringResource {
    /// Resolves this resource in `locale` rather than the process's current one.
    ///
    /// The assistant seams take the target language as a PARAMETER (a name is
    /// generated once, in the language the listener asked in, and then persisted),
    /// so the fallback cannot rely on `Locale.current`. Tests use this same call to
    /// build their expectations, which is what keeps them asserting resource
    /// RESOLUTION rather than a hand-copied English literal.
    func resolved(in locale: Locale) -> String {
        var localized = self
        localized.locale = locale
        return String(localized: localized)
    }
}

// MARK: - Naming

/// Builds a playlist name from a draft's aggregates alone.
public enum AssistantNamingTemplates {
    /// The deterministic name for one draft.
    ///
    /// Always succeeds: the ladder in ``nameResource(for:locale:)`` ends at
    /// ``AssistantStrings/nameGeneric``, which needs no aggregate at all.
    public static func fallbackName(
        for context: PlaylistNamingContext,
        locale: Locale
    ) -> PlaylistNamingResult {
        PlaylistNamingResult(
            name: nameResource(for: context, locale: locale).resolved(in: locale),
            description: descriptionText(for: context, locale: locale)
        )
    }

    /// Which template a draft earns, most specific first.
    ///
    /// Internal rather than private so a test can assert the CHOSEN KEY — the
    /// branch is the interesting part, and comparing rendered English would only
    /// prove the catalog's `defaultValue`.
    static func nameResource(
        for context: PlaylistNamingContext,
        locale: Locale
    ) -> LocalizedStringResource {
        let genre = firstName(in: context.topGenres)
        let decade = context.dominantDecade.map(String.init)
        let mood = context.moodTags.first.map { AssistantStrings.moodWord($0).resolved(in: locale) }
        if let genre {
            if let decade { return AssistantStrings.nameGenreDecade(genre: genre, decade: decade) }
            if let mood { return AssistantStrings.nameMoodGenre(mood: mood, genre: genre) }
            return AssistantStrings.nameGenre(genre: genre)
        }
        if let artist = soloArtist(in: context) { return AssistantStrings.nameArtist(artist: artist) }
        if let decade { return AssistantStrings.nameDecade(decade: decade) }
        if let mood { return AssistantStrings.nameMood(mood: mood) }
        return AssistantStrings.nameGeneric
    }

    // MARK: Private

    /// The one artist a draft is really about, or `nil`.
    ///
    /// Two ways to qualify: the draft holds exactly one distinct artist, or its top
    /// artist covers at least half of it. The second matters because a "more like
    /// X" draft is padded with neighbours, and would otherwise fall through to a
    /// decade or a generic name despite being obviously about X.
    private static func soloArtist(in context: PlaylistNamingContext) -> String? {
        guard let top = context.topArtists.first else { return nil }
        let name = top.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        if context.distinctArtistCount == 1 { return name }
        guard context.trackCount > 0, top.count * 2 >= context.trackCount else { return nil }
        return name
    }

    /// The one-line description, or `nil` for an empty draft.
    private static func descriptionText(for context: PlaylistNamingContext, locale: Locale) -> String? {
        guard context.trackCount > 0 else { return nil }
        let artists = max(context.distinctArtistCount, context.topArtists.count)
        return AssistantStrings
            .nameSummary(trackCount: context.trackCount, artistCount: artists)
            .resolved(in: locale)
    }

    /// The first ranked entry carrying a real name.
    ///
    /// ``AssistantNameCount/name`` is documented as `""` when the underlying value
    /// was unknown — an untagged-genre bucket ranks like any other, and naming a
    /// playlist after it would read as a bug.
    private static func firstName(in ranked: [AssistantNameCount]) -> String? {
        for entry in ranked {
            let name = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { return name }
        }
        return nil
    }
}

// MARK: - Narration

/// Builds a listening narrative from one window's aggregates alone.
public enum AssistantNarrationTemplates {
    /// Below this many seconds the narrative says nothing about duration at all,
    /// rather than claiming "about 0 minutes".
    public static let minimumReportedSeconds: Double = 60

    /// The deterministic narrative for one window.
    public static func fallbackNarrative(
        for context: InsightNarrationContext,
        locale: Locale
    ) -> InsightNarrationResult {
        InsightNarrationResult(narrative: sentences(for: context, locale: locale).joined(separator: " "))
    }

    /// The sentences, in order — internal so a test can assert composition without
    /// re-splitting a joined string.
    static func sentences(for context: InsightNarrationContext, locale: Locale) -> [String] {
        guard context.totalPlays > 0 else {
            return [AssistantStrings.narrativeEmpty.resolved(in: locale)]
        }
        var lines = [
            AssistantStrings
                .narrativeWindow(context.window, plays: context.totalPlays)
                .resolved(in: locale),
        ]
        if let artist = firstRanked(in: context.topArtists) {
            lines.append(
                AssistantStrings
                    .narrativeTopArtist(artist: artist.name, plays: artist.count)
                    .resolved(in: locale)
            )
        }
        if let genre = firstRanked(in: context.topGenres) {
            lines.append(AssistantStrings.narrativeTopGenre(genre: genre.name).resolved(in: locale))
        }
        if let hour = context.peakLocalHour, (0 ..< 24).contains(hour) {
            lines.append(AssistantStrings.narrativePeakHour(hour: hourToken(hour)).resolved(in: locale))
        }
        if let duration = durationResource(context.totalListenedSeconds) {
            lines.append(duration.resolved(in: locale))
        }
        return lines
    }

    /// A locale-neutral 24-hour clock token, e.g. `21:00`.
    ///
    /// Deliberately NOT a `Date.FormatStyle`: formatting an hour as a time of day
    /// needs a `Date`, a `Calendar` and a time zone, none of which a bare local-hour
    /// bucket has. The token is DATA inside a localized sentence, the same way a
    /// genre name is.
    static func hourToken(_ hour: Int) -> String {
        String(format: "%02d:00", hour)
    }

    // MARK: Private

    /// Hours when the window holds at least one, otherwise minutes — or `nil` below
    /// ``minimumReportedSeconds``.
    private static func durationResource(_ seconds: Double) -> LocalizedStringResource? {
        guard seconds.isFinite, seconds >= minimumReportedSeconds else { return nil }
        // Clamped before the `Int` conversion: `totalListenedSeconds` is summed from
        // stored rows, and converting a corrupt one would trap rather than degrade.
        let minutes = Int(min(seconds / 60, 1_000_000_000))
        guard minutes >= 60 else { return AssistantStrings.narrativeMinutes(minutes: minutes) }
        return AssistantStrings.narrativeHours(hours: minutes / 60)
    }

    /// See ``AssistantNamingTemplates`` — an unknown-name bucket is skipped.
    private static func firstRanked(in ranked: [AssistantNameCount]) -> AssistantNameCount? {
        for entry in ranked {
            let name = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { return AssistantNameCount(name: name, count: entry.count) }
        }
        return nil
    }
}

// MARK: - The ladders

/// A ``PlaylistNaming`` that never fails.
///
/// Wraps an optional primary tier — normally the 26+-gated `FMPlaylistNaming` — and
/// answers from ``AssistantNamingTemplates`` whenever it is absent, throws, or
/// returns an empty name. `nil` is the FLOOR configuration, not an error case: on a
/// pre-26 OS, with Intelligence off, or in an App Store build there is no model to
/// wrap and the templates are the whole feature.
///
/// A failure is swallowed SILENTLY and by design. A listener asked for a playlist,
/// not for a naming service; surfacing "the model refused" next to a perfectly good
/// draft would be reporting an implementation detail as a user-facing problem.
public struct FallbackPlaylistNaming: PlaylistNaming {
    private let primary: (any PlaylistNaming)?

    public init(primary: (any PlaylistNaming)?) {
        self.primary = primary
    }

    /// - Throws: `CancellationError` only. Every other error becomes a template
    ///   name — a cancelled request is not a failed one and must not be answered.
    public func suggestName(
        for context: PlaylistNamingContext,
        locale: Locale
    ) async throws -> PlaylistNamingResult {
        let fallback = AssistantNamingTemplates.fallbackName(for: context, locale: locale)
        guard let primary else { return fallback }
        do {
            let result = try await primary.suggestName(for: context, locale: locale)
            return result.name.isEmpty ? fallback : result
        } catch let error as CancellationError {
            throw error
        } catch {
            return fallback
        }
    }
}

/// An ``InsightNarrating`` that never fails. See ``FallbackPlaylistNaming``.
public struct FallbackInsightNarrating: InsightNarrating {
    private let primary: (any InsightNarrating)?

    public init(primary: (any InsightNarrating)?) {
        self.primary = primary
    }

    /// - Throws: `CancellationError` only.
    public func narrate(
        _ context: InsightNarrationContext,
        locale: Locale
    ) async throws -> InsightNarrationResult {
        let fallback = AssistantNarrationTemplates.fallbackNarrative(for: context, locale: locale)
        guard let primary else { return fallback }
        do {
            let result = try await primary.narrate(context, locale: locale)
            return result.narrative.isEmpty ? fallback : result
        } catch let error as CancellationError {
            throw error
        } catch {
            return fallback
        }
    }
}
