@testable import AudioEngine
import Foundation
import Testing

private let headroomSampleRate: Double = 44100

private func peakingBank(gainDB: Double, frequency: Double = 1000, preampDB: Double = 0) -> ParametricEQConfiguration {
    ParametricEQConfiguration(
        filters: [ParametricFilter(type: .peaking, frequency: frequency, gainDB: gainDB, qFactor: 1)],
        preampDB: preampDB
    )
}

// MARK: - The AutoEq max_gain sweep

struct HeadroomSweepTests {
    @Test func peakingBankPeaksAtItsStatedGain() {
        let peak = peakingBank(gainDB: 6).maximumFilterResponseDB(sampleRate: headroomSampleRate)

        #expect(abs(peak - 6) < 0.1)
    }

    /// A geometric grid alone straddles a narrow bell; folding each filter's own
    /// centre frequency into the grid is what keeps this exact.
    @Test func narrowPeakingBankStillPeaksAtItsStatedGain() {
        let filter = ParametricFilter(type: .peaking, frequency: 3150, gainDB: 9, qFactor: 12)
        let peak = ParametricEQConfiguration(filters: [filter])
            .maximumFilterResponseDB(sampleRate: headroomSampleRate)

        #expect(abs(peak - 9) < 0.1)
    }

    /// A shelf plateaus well outside its corner, so the band edge — not the
    /// corner — is the grid point that has to catch it.
    @Test func lowShelfPeaksOnItsPlateau() {
        let filter = ParametricFilter(type: .lowShelf, frequency: 500, gainDB: 6, qFactor: 0.7)
        let peak = ParametricEQConfiguration(filters: [filter])
            .maximumFilterResponseDB(sampleRate: headroomSampleRate)

        #expect(abs(peak - 6) < 0.1)
    }

    @Test func cutOnlyBankPeaksAtUnity() {
        let peak = peakingBank(gainDB: -6).maximumFilterResponseDB(sampleRate: headroomSampleRate)

        #expect(abs(peak) < 0.1)
    }

    @Test func emptyBankPeaksAtExactlyZero() {
        #expect(ParametricEQConfiguration.bypass.maximumFilterResponseDB(sampleRate: headroomSampleRate) == 0)
    }

    @Test func sweepStaysBelowNyquist() {
        let grid = HeadroomSweep.frequencies(sampleRate: 22050, including: [20000])

        #expect(grid.allSatisfy { $0 <= 11025 })
        #expect(grid.contains { $0 >= 11024 })
    }
}

// MARK: - Compound peak and the suggestion

@MainActor
struct HeadroomSuggestionTests {
    @Test func compoundPeakSumsReplayGainAndTheFilterPeak() throws {
        let engine = FakePlaybackEngine()
        engine.gainComposer.setReplayGain(5)

        let analysis = engine.gainComposer.headroomAnalysis(
            parametricConfiguration: peakingBank(gainDB: 6),
            sampleRate: headroomSampleRate
        )

        #expect(abs(analysis.compoundPeakDB - 11) < 0.1)
        let trim = try #require(analysis.suggestedTrimDB)
        #expect(abs(trim - -11) < 0.1)
    }

    @Test func preampsJoinTheCompoundPeakWithoutDoubleCountingTheFilters() throws {
        let engine = FakePlaybackEngine()
        engine.gainComposer.setGraphicPreamp(2)
        let configuration = peakingBank(gainDB: 6, preampDB: 3)
        try engine.setParametricConfiguration(configuration)

        let analysis = engine.gainComposer.headroomAnalysis(
            parametricConfiguration: configuration,
            sampleRate: headroomSampleRate
        )

        #expect(abs(analysis.parametricPeakDB - 6) < 0.1)
        #expect(analysis.parametricPreampDB == 3)
        #expect(abs(analysis.compoundPeakDB - 11) < 0.1)
    }

    @Test func suggestionApplicationRoutesThroughTheGainComposer() {
        let engine = FakePlaybackEngine()
        engine.gainComposer.setReplayGain(5)
        let analysis = engine.gainComposer.headroomAnalysis(
            parametricConfiguration: peakingBank(gainDB: 6),
            sampleRate: headroomSampleRate
        )

        #expect(engine.gainComposer.applyHeadroomSuggestion(analysis))

        #expect(abs(engine.gainComposer.headroomTrimDB - -11) < 0.1)
        #expect(abs(engine.gainComposer.composedGainDB - -6) < 0.1)
        #expect(abs(engine.globalGain - -6) < 0.1)
    }

    @Test func analysisAloneNeverMovesTheLedger() {
        let engine = FakePlaybackEngine()
        engine.gainComposer.setReplayGain(5)

        _ = engine.gainComposer.headroomAnalysis(
            parametricConfiguration: peakingBank(gainDB: 6),
            sampleRate: headroomSampleRate
        )

        #expect(engine.gainComposer.headroomTrimDB == 0)
        #expect(abs(engine.globalGain - 5) < 0.1)
    }

    @Test func anAcceptedSuggestionIsIdempotent() {
        let engine = FakePlaybackEngine()
        engine.gainComposer.setReplayGain(5)
        let configuration = peakingBank(gainDB: 6)
        let first = engine.gainComposer.headroomAnalysis(
            parametricConfiguration: configuration,
            sampleRate: headroomSampleRate
        )
        engine.gainComposer.applyHeadroomSuggestion(first)

        let second = engine.gainComposer.headroomAnalysis(
            parametricConfiguration: configuration,
            sampleRate: headroomSampleRate
        )

        #expect(abs(second.compoundPeakDB) < 0.1)
        #expect(second.suggestedTrimDB == nil)
        #expect(!engine.gainComposer.applyHeadroomSuggestion(second))
    }

    @Test func furtherBoostAfterATrimSuggestsTheRemainder() throws {
        let engine = FakePlaybackEngine()
        engine.gainComposer.setReplayGain(5)
        let configuration = peakingBank(gainDB: 6)
        engine.gainComposer.applyHeadroomSuggestion(
            engine.gainComposer.headroomAnalysis(
                parametricConfiguration: configuration,
                sampleRate: headroomSampleRate
            )
        )

        engine.gainComposer.setGraphicPreamp(6)
        let analysis = engine.gainComposer.headroomAnalysis(
            parametricConfiguration: configuration,
            sampleRate: headroomSampleRate
        )

        let trim = try #require(analysis.suggestedTrimDB)
        #expect(abs(trim - -6) < 0.1)
        #expect(engine.gainComposer.applyHeadroomSuggestion(analysis))
        #expect(abs(engine.gainComposer.headroomTrimDB - -17) < 0.1)
    }

    @Test func nothingBoostingSurfacesNoSuggestion() {
        let engine = FakePlaybackEngine()

        let analysis = engine.gainComposer.headroomAnalysis(
            parametricConfiguration: nil,
            sampleRate: headroomSampleRate
        )

        #expect(analysis.compoundPeakDB == 0)
        #expect(analysis.suggestedTrimDB == nil)
        #expect(analysis.resolvedTrimDB == nil)
        #expect(!engine.gainComposer.applyHeadroomSuggestion(analysis))
        #expect(engine.gainComposer.headroomTrimDB == 0)
    }

    @Test func attenuatingPathSurfacesNoSuggestion() {
        let engine = FakePlaybackEngine()
        engine.gainComposer.setReplayGain(-4)

        let analysis = engine.gainComposer.headroomAnalysis(
            parametricConfiguration: peakingBank(gainDB: -2),
            sampleRate: headroomSampleRate
        )

        #expect(analysis.compoundPeakDB < 0)
        #expect(analysis.suggestedTrimDB == nil)
        #expect(!engine.gainComposer.applyHeadroomSuggestion(analysis))
    }

    @Test func aTrimBelowDisplayResolutionIsNotOffered() {
        let engine = FakePlaybackEngine()
        engine.gainComposer.setReplayGain(0.05)

        let analysis = engine.gainComposer.headroomAnalysis(
            parametricConfiguration: nil,
            sampleRate: headroomSampleRate
        )

        #expect(analysis.compoundPeakDB > 0)
        #expect(analysis.suggestedTrimDB == nil)
    }
}
