// Audio-feature predicates against a real library, and the coverage hint that
// tells the UI when their answer meant nothing.
//
// The two halves are inseparable. A feature predicate compiles to
// `(<column> IS NULL OR <range>)`, so an un-analysed track is EXEMPTED from the
// filter rather than excluded by it — correct on a partly analysed library,
// where "energy above 0.7" should not hide everything the user has not analysed
// yet. On a library with NO analysis at all the same rule matches every track,
// which is indistinguishable from "no energy filter was asked for". The hint is
// the only thing that separates those two outcomes, so it is asserted right
// beside the semantics it qualifies.
import Foundation
import GRDB
import Persistence
import Testing

/// The version `SmartPlaylistFixtures` stamps on its analysis rows.
///
/// Passed explicitly rather than imported from `AudioAnalysisService`: the reader
/// takes it as an argument precisely so `Persistence` never reaches up into
/// `Services`, and this suite honours that boundary.
private let fixtureAnalysisVersion = 1

@Suite("SmartPlaylistAudioFeatureCoverageTests")
struct SmartPlaylistAudioFeatureCoverageTests {
    /// Track 1 is analysed at energy 0.8, track 4 at 0.2, tracks 2 and 3 not at
    /// all. A `>= 0.7` rule keeps the analysed qualifier, drops the analysed
    /// non-qualifier, and lets both un-analysed tracks through untouched.
    @Test("an energy predicate keeps analyzed qualifiers and exempts unanalyzed tracks")
    func energyPredicateKeepsQualifiersAndExemptsUnanalyzedTracks() throws {
        let database = try SmartPlaylistFixtures.makeLibrary()

        let matched = try SmartPlaylistFixtures.matchedIDs(
            database,
            rules: SmartPlaylistFixtures.rules(.audioFeature(.energy(range: SmartPlaylistRange(lower: 0.7))))
        )

        #expect(Set(matched) == [1, 2, 3])
        #expect(matched.contains(4) == false)
    }

    /// The exemption is scoped to the feature clause alone: composing it with a
    /// hard `all` filter still narrows the result.
    @Test("an energy predicate composes with a hard filter without weakening it")
    func energyPredicateComposesWithAHardFilter() throws {
        let database = try SmartPlaylistFixtures.makeLibrary()
        let rules = SmartPlaylistRules(
            match: .all,
            predicates: [
                .audioFeature(.energy(range: SmartPlaylistRange(lower: 0.7))),
                .metadata(.availability(equals: .present)),
            ]
        )

        let matched = try SmartPlaylistFixtures.matchedIDs(database, rules: rules)

        #expect(Set(matched) == [1, 2])
    }

    /// The plan's failure path. A feature rule over a library with no analysis
    /// does NOT throw and does not empty the playlist — it matches everything,
    /// because every feature clause resolves through its `IS NULL` arm. The hint
    /// is what stops that being presented as a filtered result.
    @Test("a feature rule over an unanalyzed library matches everything without error and hints")
    func featureRuleOverAnUnanalyzedLibraryHintsInsteadOfFailing() throws {
        let database = try makeUnanalyzedLibrary()
        let rules = SmartPlaylistFixtures.rules(.audioFeature(.energy(range: SmartPlaylistRange(lower: 0.7))))

        let matched = try SmartPlaylistFixtures.matchedIDs(database, rules: rules)
        let hint = try requiresAnalysis(database, rules: rules)

        #expect(Set(matched) == [1, 2, 3, 4])
        #expect(hint)
    }

    @Test("the hint clears once any track carries an analysis row")
    func hintClearsOnceAnyTrackCarriesAnAnalysisRow() throws {
        let database = try SmartPlaylistFixtures.makeLibrary()
        let rules = SmartPlaylistFixtures.rules(.audioFeature(.energy(range: SmartPlaylistRange(lower: 0.7))))

        #expect(try requiresAnalysis(database, rules: rules) == false)
    }

    @Test("the hint ignores rule sets that never read audio features")
    func hintIgnoresRuleSetsWithoutFeaturePredicates() throws {
        let database = try makeUnanalyzedLibrary()
        let rules = SmartPlaylistFixtures.rules(.metadata(.genre(equals: "Rock")))

        #expect(rules.readsAudioFeatures == false)
        #expect(try requiresAnalysis(database, rules: rules) == false)
    }

    /// The reason coverage carries two counts. The fixture's rows are stamped
    /// with a fingerprint the tracks do not have, so they are STALE — yet the
    /// compiler joins on `trackId` alone and still filters with them. Measuring
    /// the hint on freshness would fire it on a library whose rules are working.
    @Test("coverage separates readable analysis rows from current ones")
    func coverageSeparatesReadableRowsFromCurrentOnes() throws {
        let database = try SmartPlaylistFixtures.makeLibrary()

        let coverage = try visibleCoverage(database, profileId: SmartPlaylistFixtures.profileID)

        #expect(coverage.total == 3)
        #expect(coverage.measured == 2)
        #expect(coverage.analyzed == 0)
        #expect(coverage.isUnmeasured == false)
    }

    /// Coverage answers the hint's question about the population a rule set
    /// actually runs over, so it follows the same visibility scoping the
    /// compiler applies.
    @Test("visible coverage is scoped to the profile's library roots")
    func visibleCoverageIsScopedToTheProfilesRoots() throws {
        let database = try SmartPlaylistFixtures.makeLibrary()
        try database.writer.write { db in
            try SmartPlaylistFixtures.insertProfile(db, id: SmartPlaylistFixtures.otherProfileID, name: "Profile B")
            try SmartPlaylistFixtures.insertRoot(db, profileId: SmartPlaylistFixtures.profileID, path: "/A")
            try SmartPlaylistFixtures.insertRoot(db, profileId: SmartPlaylistFixtures.otherProfileID, path: "/B")
        }

        let owner = try visibleCoverage(database, profileId: SmartPlaylistFixtures.profileID)
        let stranger = try visibleCoverage(database, profileId: SmartPlaylistFixtures.otherProfileID)

        #expect(owner.total == 3)
        #expect(owner.measured == 2)
        #expect(stranger.total == 0)
        #expect(stranger.isUnmeasured == false)
    }
}

// MARK: - Helpers

private extension SmartPlaylistAudioFeatureCoverageTests {
    /// ``SmartPlaylistFixtures/makeLibrary()`` without the analysis rows — the
    /// same four tracks, the same profile, nothing measured.
    func makeUnanalyzedLibrary() throws -> AppDatabase {
        let database = try AppDatabase.makeEmpty()
        try database.writer.write { db in
            try SmartPlaylistFixtures.insertProfile(db, id: SmartPlaylistFixtures.profileID, name: "Profile A")
            for var track in SmartPlaylistFixtures.libraryTracks {
                try track.insert(db)
            }
            try SmartPlaylistFixtures.insertPlaylist(
                db,
                id: SmartPlaylistFixtures.playlistID,
                profileId: SmartPlaylistFixtures.profileID
            )
        }
        return database
    }

    func requiresAnalysis(_ database: AppDatabase, rules: SmartPlaylistRules) throws -> Bool {
        try database.writer.read { db in
            try AudioFeatureCoverageReader.requiresAnalysis(
                db,
                rules: rules,
                profileId: SmartPlaylistFixtures.profileID,
                analysisVersion: fixtureAnalysisVersion
            )
        }
    }

    func visibleCoverage(_ database: AppDatabase, profileId: Int64) throws -> AudioFeatureCoverage {
        try database.writer.read { db in
            try AudioFeatureCoverageReader.visibleCoverage(
                db,
                profileId: profileId,
                analysisVersion: fixtureAnalysisVersion
            )
        }
    }
}
