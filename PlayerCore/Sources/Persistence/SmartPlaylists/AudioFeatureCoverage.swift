// AudioFeatureCoverage — how much of the library carries usable audio analysis.
//
// Two consumers, one measurement:
//
//  * The analysis view model's `analyzedFraction` ("34% analyzed"). It must be a
//    LIBRARY-WIDE fact, never derived from ``AudioAnalyzing/progress`` — that
//    tuple's `total` is a snapshot of the STALE set taken once at pass start, so
//    a fully analysed library reports `(0, 0)` and a mid-pass library scan can
//    push `completed` past `total`.
//  * The `requiresAnalysis` hint. ``SmartPlaylistAudioFeaturePredicate`` compiles
//    to `(<column> IS NULL OR <range>)`, so an un-analysed track is EXEMPTED from
//    a feature predicate rather than excluded by it. That is correct on a partly
//    analysed library — but on a library with no analysis at all it means every
//    feature clause is a tautology and the rule quietly matches everything. The
//    hint is what lets the UI say "analyse your library first" instead of
//    presenting a vacuous result as a real one.
//
// Both counts are `COUNT(*)` over indexed columns with no row materialised, so
// this stays bounded on a 100k library.
import Foundation
import GRDB

/// How much of a track population carries audio analysis, under the two
/// different readings the two consumers need.
///
/// The readings differ because ``SmartPlaylistCompiler`` joins
/// `trackAudioFeature` on `trackId` ALONE, while the analysis pass treats a row
/// whose version or `(fileSize, mtime)` fingerprint has drifted as absent:
///
///  * ``analyzed`` (fingerprint-checked) answers "how much is still to do" — the
///    progress reading, and the one that agrees with the pass.
///  * ``measured`` (row exists) answers "how much can a rule actually read" — the
///    vacuity reading behind ``AudioFeatureCoverageReader/requiresAnalysis(_:rules:profileId:analysisVersion:)``.
///
/// Using ``analyzed`` for the hint would fire it on a library whose every row is
/// merely fingerprint-stale, even though those rows are still filtering rules.
public struct AudioFeatureCoverage: Sendable, Equatable, Hashable {
    /// Tracks carrying a `trackAudioFeature` row that matches both the current
    /// analysis version and the file's `(fileSize, mtime)` fingerprint.
    public let analyzed: Int

    /// Tracks carrying **any** `trackAudioFeature` row, fresh or stale — exactly
    /// what the rule compiler's `LEFT JOIN` can see.
    public let measured: Int

    /// Tracks in the population.
    public let total: Int

    /// Clamps into `0 <= analyzed <= measured <= total`, so no caller can build a
    /// fraction above 1 — the same defence the view model applies to the pass's
    /// progress.
    public init(analyzed: Int, measured: Int, total: Int) {
        let boundedTotal = max(0, total)
        let boundedMeasured = min(max(0, measured), boundedTotal)
        self.total = boundedTotal
        self.measured = boundedMeasured
        self.analyzed = min(max(0, analyzed), boundedMeasured)
    }

    /// `analyzed / total`, in `0...1`.
    ///
    /// Zero for an empty population, so UI copy reads "0% analyzed" rather than
    /// dividing by zero.
    public var fraction: Double {
        guard total > 0 else { return 0 }
        return Double(analyzed) / Double(total)
    }

    /// The population is non-empty and **no** track in it carries a readable
    /// analysis row — the state in which every audio-feature predicate
    /// degenerates to a tautology.
    public var isUnmeasured: Bool {
        total > 0 && measured == 0
    }
}

/// Bounded coverage queries over `trackAudioFeature`, plus the smart-playlist
/// `requiresAnalysis` hint they back.
///
/// This is an ADDITIVE layer: it never changes how a rule set compiles or what it
/// matches. ``SmartPlaylistCompiler`` keeps its no-op-when-absent semantics
/// verbatim; this type only lets a caller ask how meaningful the answer was.
public enum AudioFeatureCoverageReader {
    /// Coverage over **every** `present` track, unscoped by profile.
    ///
    /// Profile-unscoped on purpose: analysis describes the FILE, `trackAudioFeature`
    /// carries no `profileId`, and ``AudioAnalyzing`` walks exactly this population.
    /// A scoped denominator would make the coverage read disagree with the pass
    /// that fills it.
    ///
    /// - Parameter analysisVersion: The extractor version rows must carry to
    ///   count as analysed — pass `AudioAnalysisService.analysisVersion`. It
    ///   travels as an argument because `Persistence` sits *below* `Services` and
    ///   cannot import that constant.
    public static func libraryCoverage(_ db: Database, analysisVersion: Int) throws -> AudioFeatureCoverage {
        try coverage(db, scope: nil, analysisVersion: analysisVersion)
    }

    /// Coverage over the `present` tracks `profileId` can actually see.
    ///
    /// The population a rule set evaluates against, so this — not
    /// ``libraryCoverage(_:analysisVersion:)`` — is what the hint measures: a
    /// profile whose roots hold nothing analysed gets a vacuous rule even when
    /// another profile's folders are fully analysed.
    public static func visibleCoverage(
        _ db: Database,
        profileId: Int64,
        analysisVersion: Int
    ) throws -> AudioFeatureCoverage {
        let scope = try LibraryVisibility.predicate(db, profileId: profileId, column: "track.filePath")
        return try coverage(db, scope: scope, analysisVersion: analysisVersion)
    }

    /// Whether `rules` asks about audio features that nothing in `profileId`'s
    /// library can answer.
    ///
    /// True only when BOTH hold: the rule set reads `trackAudioFeature`, and the
    /// profile's visible population is non-empty with no readable analysis row in
    /// it. In that state every feature clause matches through its `IS NULL` arm,
    /// so the materialised result is whatever the rule set's *other* predicates
    /// allow — a result the UI must label rather than present as feature-filtered.
    ///
    /// Deliberately keyed on the POPULATION, not on the materialised ids: an
    /// empty result caused by a genre predicate matching nothing would otherwise
    /// masquerade as "needs analysis".
    public static func requiresAnalysis(
        _ db: Database,
        rules: SmartPlaylistRules,
        profileId: Int64,
        analysisVersion: Int
    ) throws -> Bool {
        guard rules.readsAudioFeatures else { return false }
        return try visibleCoverage(db, profileId: profileId, analysisVersion: analysisVersion).isUnmeasured
    }
}

// MARK: - Rule introspection

public extension SmartPlaylistRules {
    /// Whether any predicate reads `trackAudioFeature`.
    ///
    /// The grouped predicate enum makes this a one-case test rather than a
    /// thirteen-case switch — the reason ``SmartPlaylistPredicate`` is grouped by
    /// data source in the first place.
    var readsAudioFeatures: Bool {
        predicates.contains { predicate in
            if case .audioFeature = predicate {
                return true
            }
            return false
        }
    }
}

// MARK: - Counting

private extension AudioFeatureCoverageReader {
    /// The freshness test, as the positive twin of
    /// `AudioAnalysisService.staleFingerprintClause`.
    ///
    /// The pass asks `NOT EXISTS(…)` ("still to do"); this asks `EXISTS(…)`
    /// ("already done"), so the two partition the same population and
    /// `analyzed + stale == total` by construction. **They must stay in sync**:
    /// `Persistence` sits below `Services`, so the clause cannot be shared and is
    /// restated here instead.
    ///
    /// `COALESCE(…, 0)` mirrors the pass for the same reason it exists there —
    /// `track.fileSize`/`track.mtime` are nullable, and a bare comparison against
    /// `NULL` is never true, so a nil-fingerprint track would never count as
    /// analysed however often it was analysed.
    ///
    /// Note this is STRICTER than the compiler's `LEFT JOIN trackAudioFeature`,
    /// which matches on `trackId` alone. A row whose file changed since it was
    /// analysed still feeds a rule, but does not count as coverage — the numbers
    /// it carries describe bytes that are no longer on disk.
    static var freshAnalysisClause: String {
        """
        EXISTS (
          SELECT 1 FROM trackAudioFeature
          WHERE trackAudioFeature.trackId = track.id
            AND trackAudioFeature.analysisVersion = ?
            AND trackAudioFeature.fileSize = COALESCE(track.fileSize, 0)
            AND trackAudioFeature.mtime = COALESCE(track.mtime, 0)
        )
        """
    }

    /// All three counts in one conditional-aggregate pass over the population.
    ///
    /// Argument order is the `?` order in the FINAL string, and the analysis
    /// version comes FIRST here because ``freshAnalysisClause`` sits in the
    /// `SELECT` list, ahead of the `WHERE`. Getting this wrong fails as wrong
    /// numbers, not as an error.
    static func coverage(
        _ db: Database,
        scope: LibraryVisibility.Predicate?,
        analysisVersion: Int
    ) throws -> AudioFeatureCoverage {
        let scopeSQL = scope.map { " AND \($0.sql)" } ?? ""
        var arguments: [any DatabaseValueConvertible] = [analysisVersion, Availability.present.rawValue]
        arguments.append(contentsOf: scope?.arguments ?? [])
        let row = try Row.fetchOne(db, sql: """
        SELECT
          SUM(CASE WHEN \(freshAnalysisClause) THEN 1 ELSE 0 END) AS analyzed,
          SUM(CASE WHEN \(anyAnalysisClause) THEN 1 ELSE 0 END) AS measured,
          COUNT(*) AS total
        FROM track
        WHERE track.availability = ?\(scopeSQL)
        """, arguments: StatementArguments(arguments))
        guard let row else { return AudioFeatureCoverage(analyzed: 0, measured: 0, total: 0) }
        let analyzed: Int = row["analyzed"] ?? 0
        let measured: Int = row["measured"] ?? 0
        let total: Int = row["total"] ?? 0
        return AudioFeatureCoverage(analyzed: analyzed, measured: measured, total: total)
    }

    /// What ``SmartPlaylistCompiler``'s `LEFT JOIN trackAudioFeature` can see: a
    /// row for the track, whatever version or fingerprint it carries.
    static var anyAnalysisClause: String {
        "EXISTS (SELECT 1 FROM trackAudioFeature WHERE trackAudioFeature.trackId = track.id)"
    }
}
