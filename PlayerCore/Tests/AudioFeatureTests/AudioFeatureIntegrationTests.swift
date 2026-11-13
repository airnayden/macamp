// End-to-end: extract -> persist -> a rule filters / a mix arcs, and a second
// profile gets all of it for free.
//
// The unit suites either side of this one are hermetic by design — the analysis
// suites use a fake extractor and never compile a rule, the smart-playlist
// suites hand-write `trackAudioFeature` rows and never run a pass. That leaves
// exactly one thing unproven: that the rows the pass WRITES are the rows the
// rule compiler and the mix ranker READ. These tests close that seam by driving
// the real ``AudioAnalysisService`` and then querying through the real
// ``SmartPlaylistCompiler`` and ``MixCandidateResolver``.
import Foundation
import GRDB
import Persistence
import PlayerCoreTestSupport
import Services
import Testing

@MainActor
@Suite("AudioFeatureIntegrationTests")
struct AudioFeatureIntegrationTests {
    /// With the whole library analysed, nothing reaches the feature clause's
    /// `IS NULL` arm, so the rule is a true filter rather than a partial one.
    @Test("an analysis pass makes an energy rule filter for real")
    func analysisPassMakesAnEnergyRuleFilterForReal() async throws {
        let context = try IntegrationFixture.make(energies: [0.9, 0.8, 0.4, 0.1])

        context.service.start()
        await pollUntil { !context.service.isRunning }

        #expect(try featureCount(context.database) == 4)
        #expect(context.service.failedCount == 0)
        let matched = try IntegrationFixture.matchedIDs(
            context.database,
            rules: IntegrationFixture.energyAtLeast(0.7),
            profileId: IntegrationFixture.ownerID
        )
        #expect(Set(matched) == [1, 2])
    }

    /// The coverage the "34% analyzed" copy reads, taken over a library the pass
    /// has just finished. Every track here is decodable, so it reaches exactly
    /// `1` — a library with a permanently undecodable file never would.
    @Test("library coverage reaches full after a clean pass, and clears the hint")
    func libraryCoverageReachesFullAfterACleanPass() async throws {
        let context = try IntegrationFixture.make(energies: [0.9, 0.8, 0.4, 0.1])
        let before = try IntegrationFixture.libraryCoverage(context.database)
        #expect(before.fraction == 0)
        #expect(try IntegrationFixture.requiresAnalysis(context.database))

        context.service.start()
        await pollUntil { !context.service.isRunning }

        let after = try IntegrationFixture.libraryCoverage(context.database)
        #expect(after.analyzed == 4)
        #expect(after.total == 4)
        #expect(after.fraction == 1)
        #expect(try IntegrationFixture.requiresAnalysis(context.database) == false)
    }

    /// The mix side of the same seam: the energies the pass wrote come back
    /// through ``MixCandidateResolver`` and shape the arc.
    ///
    /// `[0.1, 0.3, 0.5, 0.7, 0.9]` deals to `[0.1, 0.5, 0.9, 0.7, 0.3]` — the
    /// peak lands in the middle and both halves are monotone by construction.
    @Test("an analysis pass feeds the mix energy arc")
    func analysisPassFeedsTheMixEnergyArc() async throws {
        let context = try IntegrationFixture.make(energies: [0.1, 0.3, 0.5, 0.7, 0.9])
        context.service.start()
        await pollUntil { !context.service.isRunning }

        let candidates = try await IntegrationFixture.candidates(
            context.database,
            profileId: IntegrationFixture.ownerID,
            trackIds: context.trackIds
        )
        let arced = try #require(MixRanking.energyArced(candidates))

        #expect(candidates.compactMap(\.energy).count == 5)
        #expect(arced.map(\.trackId) == [1, 3, 5, 4, 2])
    }

    /// ``MixRanking/energyArcCoverage`` measures the SELECTION it is handed, not
    /// the pool it was drawn from — the property todo 8 recorded. Handing it the
    /// same four analysed tracks inside a wider unanalysed list therefore
    /// suppresses the arc, which is what makes "80% of the pool" the wrong
    /// mental model and "80% of what you pass" the right one.
    @Test("the energy arc engages at 80% coverage of what it is given, and not below")
    func energyArcEngagesAtEightyPercentOfWhatItIsGiven() {
        let analysed = IntegrationFixture.candidates(energies: [0.1, 0.3, 0.7, 0.9])

        let atGate = MixRanking.energyArced(analysed + IntegrationFixture.candidates(energies: [nil]))
        let belowGate = MixRanking.energyArced(analysed + IntegrationFixture.candidates(energies: [nil, nil]))
        let farBelowGate = MixRanking.energyArced(analysed + IntegrationFixture.candidates(energies: Array(
            repeating: nil,
            count: 6
        )))

        #expect(atGate != nil)
        #expect(belowGate == nil)
        #expect(farBelowGate == nil)
    }

    /// Analysis describes the FILE, so `trackAudioFeature` carries no
    /// `profileId`. A second profile must therefore read exactly the same rows —
    /// and the spy's call count is the proof that it read them rather than
    /// recomputing them.
    @Test("a second profile reads the same features with zero re-analysis")
    func secondProfileReadsTheSameFeaturesWithZeroReanalysis() async throws {
        let context = try IntegrationFixture.make(energies: [0.9, 0.8, 0.4, 0.1], withStranger: true)
        context.service.start()
        await pollUntil { !context.service.isRunning }
        let callsAfterFirstPass = context.extractor.extractCallCount
        #expect(callsAfterFirstPass == 4)

        let rules = IntegrationFixture.energyAtLeast(0.7)
        let owned = try IntegrationFixture.matchedIDs(
            context.database,
            rules: rules,
            profileId: IntegrationFixture.ownerID
        )
        let strange = try IntegrationFixture.matchedIDs(
            context.database,
            rules: rules,
            profileId: IntegrationFixture.strangerID
        )
        let ownedFacts = try await IntegrationFixture.energies(
            context.database,
            profileId: IntegrationFixture.ownerID,
            trackIds: context.trackIds
        )
        let strangeFacts = try await IntegrationFixture.energies(
            context.database,
            profileId: IntegrationFixture.strangerID,
            trackIds: context.trackIds
        )

        #expect(owned == strange)
        #expect(ownedFacts == strangeFacts)
        #expect(context.extractor.extractCallCount == callsAfterFirstPass)
    }

    /// The other half of the same claim: re-running the pass after a second
    /// profile has consumed the rows finds nothing stale, so no track is ever
    /// analysed twice on anyone's behalf.
    @Test("a repeat pass after a second profile has read the rows analyses nothing")
    func repeatPassAfterASecondProfileReadsTheRowsAnalysesNothing() async throws {
        let context = try IntegrationFixture.make(energies: [0.9, 0.8, 0.4, 0.1], withStranger: true)
        context.service.start()
        await pollUntil { !context.service.isRunning }
        _ = try await IntegrationFixture.energies(
            context.database,
            profileId: IntegrationFixture.strangerID,
            trackIds: context.trackIds
        )

        context.service.start()
        await pollUntil { !context.service.isRunning }

        #expect(context.service.progress == (0, 0))
        #expect(context.extractor.extractCallCount == 4)
        #expect(try featureCount(context.database) == 4)
    }
}

// MARK: - Fixture

/// A library, a profile or two, and a pass wired to a spying extractor.
@MainActor
private struct IntegrationFixture {
    static let ownerID: Int64 = 2
    static let strangerID: Int64 = 3

    let database: AppDatabase
    let service: AudioAnalysisService
    let extractor: FakeAudioFeatureExtractor
    let trackIds: [Int64]

    /// One present track per entry in `energies`, each configured to extract that
    /// energy — so a rule threshold can be chosen against known values.
    static func make(energies: [Double], withStranger: Bool = false) throws -> IntegrationFixture {
        let database = try AppDatabase.makeEmpty()
        try database.writer.write { db in
            var owner = ProfileRecord(id: ownerID, name: "Owner", createdAt: FeatureFixtures.epoch)
            try owner.insert(db)
            guard withStranger else { return }
            var stranger = ProfileRecord(id: strangerID, name: "Stranger", createdAt: FeatureFixtures.epoch)
            try stranger.insert(db)
        }
        let tracks = try insertTracks(database, count: energies.count)
        let extractor = FakeAudioFeatureExtractor()
        for (track, energy) in zip(tracks, energies) {
            extractor.setResult(
                AudioFeatureResult(bpm: 120, energy: energy, brightness: 0.5),
                for: url(of: track)
            )
        }
        return IntegrationFixture(
            database: database,
            service: AudioAnalysisService(database: database, extractor: extractor, now: { FeatureFixtures.epoch }),
            extractor: extractor,
            trackIds: tracks.compactMap(\.id)
        )
    }

    static func energyAtLeast(_ lower: Double) -> SmartPlaylistRules {
        SmartPlaylistRules(predicates: [.audioFeature(.energy(range: SmartPlaylistRange(lower: lower)))])
    }

    static func matchedIDs(_ database: AppDatabase, rules: SmartPlaylistRules, profileId: Int64) throws -> [Int64] {
        try database.writer.read { db in
            try SmartPlaylistCompiler
                .compile(rules, profileId: profileId, now: FeatureFixtures.epoch, in: db)
                .request
                .fetchAll(db)
        }
    }

    static func libraryCoverage(_ database: AppDatabase) throws -> AudioFeatureCoverage {
        try database.writer.read { db in
            try AudioFeatureCoverageReader.libraryCoverage(
                db,
                analysisVersion: AudioAnalysisService.analysisVersion
            )
        }
    }

    static func requiresAnalysis(_ database: AppDatabase) throws -> Bool {
        try database.writer.read { db in
            try AudioFeatureCoverageReader.requiresAnalysis(
                db,
                rules: energyAtLeast(0.7),
                profileId: ownerID,
                analysisVersion: AudioAnalysisService.analysisVersion
            )
        }
    }

    /// The energies the mix pipeline sees, resolved through the production
    /// ``MixCandidateResolving`` rather than read back directly.
    static func energies(
        _ database: AppDatabase,
        profileId: Int64,
        trackIds: [Int64]
    ) async throws -> [Int64: Double?] {
        let facts = try await MixCandidateResolver(database).facts(profileId: profileId, trackIds: trackIds)
        return facts.mapValues(\.energy)
    }

    static func candidates(
        _ database: AppDatabase,
        profileId: Int64,
        trackIds: [Int64]
    ) async throws -> [MixCandidate] {
        let facts = try await MixCandidateResolver(database).facts(profileId: profileId, trackIds: trackIds)
        return trackIds.map { trackId in
            MixCandidate(
                trackId: trackId,
                provenance: .rulesResult,
                score: 1,
                energy: facts[trackId]?.energy
            )
        }
    }

    /// Bare candidates with ids from 100 up, so they never collide with a
    /// fixture library's ids.
    static func candidates(energies: [Double?]) -> [MixCandidate] {
        energies.enumerated().map { index, energy in
            MixCandidate(
                trackId: Int64(100 + index),
                provenance: .rulesResult,
                score: 1,
                energy: energy
            )
        }
    }
}
