import Foundation
@testable import Services
import Testing

/// `sample_tracks` — the filter lowering, the `present`-only rule and the seeded,
/// reproducible draw.
@Suite("LibraryToolbox sampling")
struct LibraryToolboxSampleTests {
    private func sample(
        _ toolbox: LibraryToolbox,
        _ values: [String: ToolboxJSON]
    ) async throws -> [Int64] {
        let result = try await toolbox.execute("sample_tracks", arguments: ToolArguments(values))
        return result.rows.compactMap { $0.payload.objectValue?["id"]?.numberValue }.map { Int64($0) }
    }

    @Test("a genre filter matches case-insensitively and excludes the missing file")
    func genreFilterExcludesMissingFiles() async throws {
        let database = try ToolboxFixtures.makeLibrary()
        let toolbox = ToolboxFixtures.makeToolbox(database)
        let ids = try await sample(toolbox, ["genre": .string("electronic")])
        #expect(ids == [2], "track 4 is Electronic but `missing`, so it must not be sampled")
    }

    @Test("a year window narrows the draw")
    func yearWindowNarrows() async throws {
        let database = try ToolboxFixtures.makeLibrary()
        let toolbox = ToolboxFixtures.makeToolbox(database)
        let ids = try await sample(toolbox, ["year_min": .int(1990), "year_max": .int(2005)])
        #expect(Set(ids) == [1, 3])
    }

    @Test("an unanalysed track is NEVER excluded by a tempo bound")
    func unanalysedSurvivesATempoBound() async throws {
        let database = try ToolboxFixtures.makeLibrary()
        let toolbox = ToolboxFixtures.makeToolbox(database)
        let ids = try await sample(toolbox, ["tempo_min": .int(120), "genre": .string("Jazz")])
        #expect(ids == [3], "track 3 has a NULL bpm, which the compiler treats as satisfying the bound")
    }

    @Test("an energy bound excludes an analysed track that misses it")
    func energyBoundExcludesAnalysed() async throws {
        let database = try ToolboxFixtures.makeLibrary()
        let toolbox = ToolboxFixtures.makeToolbox(database)
        let quiet = try await sample(toolbox, ["energy_max": .number(0.5), "year_max": .int(2020)])
        #expect(!quiet.contains(2), "track 2 measures 0.82 energy and must fall outside a 0.5 ceiling")
        #expect(quiet.contains(1))
    }

    @Test("the same seed always draws the same sample")
    func seedIsReproducible() async throws {
        let database = try ToolboxFixtures.makeLibrary()
        let toolbox = ToolboxFixtures.makeToolbox(database)
        let first = try await sample(toolbox, ["genre": .string("Filler"), "limit": .int(8), "seed": .int(7)])
        let again = try await sample(toolbox, ["genre": .string("Filler"), "limit": .int(8), "seed": .int(7)])
        #expect(first == again)
        #expect(first.count == 8)
    }

    @Test("a different seed draws a different sample")
    func seedActuallyShuffles() async throws {
        let database = try ToolboxFixtures.makeLibrary()
        let toolbox = ToolboxFixtures.makeToolbox(database)
        let seven = try await sample(toolbox, ["genre": .string("Filler"), "limit": .int(8), "seed": .int(7)])
        let eight = try await sample(toolbox, ["genre": .string("Filler"), "limit": .int(8), "seed": .int(8)])
        #expect(seven != eight)
        #expect(seven.count == eight.count)
    }

    @Test("the draw is bounded by the requested limit and by the tool's own ceiling")
    func drawIsBounded() async throws {
        let database = try ToolboxFixtures.makeLibrary()
        let toolbox = ToolboxFixtures.makeToolbox(database)
        let ids = try await sample(toolbox, ["genre": .string("Filler")])
        #expect(ids.count == LibraryToolbox.defaultSampleLimit)

        let rendered = await toolbox.run("sample_tracks", arguments: ToolArguments([
            "limit": .int(LibraryToolbox.maximumSampleLimit + 1),
        ]), profile: .cloud)
        #expect(rendered == "Argument \"limit\" must be between 1 and \(LibraryToolbox.maximumSampleLimit).")
    }

    @Test("an unmatched filter says so rather than returning an empty list")
    func unmatchedFilterSaysSo() async throws {
        let database = try ToolboxFixtures.makeLibrary()
        let toolbox = ToolboxFixtures.makeToolbox(database)
        let result = try await toolbox.execute("sample_tracks", arguments: ToolArguments([
            "genre": .string("Polka"),
        ]))
        #expect(result.renderedText(profile: .onDevice) == "No playable tracks match those bounds.")
    }

    @Test("another profile's track is never sampled")
    func samplingIsProfileScoped() async throws {
        let database = try ToolboxFixtures.makeLibrary()
        let toolbox = ToolboxFixtures.makeToolbox(database)
        let ids = try await sample(toolbox, ["genre": .string("Rock")])
        #expect(ids.isEmpty)
    }

    @Test("an energy bound outside 0...1 is refused")
    func energyBoundsAreValidated() async throws {
        let database = try ToolboxFixtures.makeLibrary()
        let toolbox = ToolboxFixtures.makeToolbox(database)
        let rendered = await toolbox.run("sample_tracks", arguments: ToolArguments([
            "energy_min": .number(4),
        ]), profile: .cloud)
        #expect(rendered == "Argument \"energy_min\" must be between 0 and 1.")
    }
}

// MARK: - The shuffle itself

@Suite("ToolboxSampling")
struct ToolboxSamplingTests {
    @Test("the permutation is a pure function of the seed")
    func permutationIsPure() {
        let values = (1 ... 20).map(Int64.init)
        #expect(ToolboxSampling.shuffled(values, seed: 3) == ToolboxSampling.shuffled(values, seed: 3))
        #expect(ToolboxSampling.shuffled(values, seed: 3) != ToolboxSampling.shuffled(values, seed: 4))
    }

    @Test("the shuffle is a permutation — nothing is lost or duplicated")
    func shuffleIsAPermutation() {
        let values = (1 ... 50).map(Int64.init)
        for seed in UInt64(0) ..< 8 {
            #expect(ToolboxSampling.shuffled(values, seed: seed).sorted() == values)
        }
    }

    @Test("degenerate inputs are returned untouched")
    func degenerateInputs() {
        #expect(ToolboxSampling.shuffled([], seed: 1).isEmpty)
        #expect(ToolboxSampling.shuffled([7], seed: 1) == [7])
    }
}
