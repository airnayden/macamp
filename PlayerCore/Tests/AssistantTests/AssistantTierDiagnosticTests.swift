// AssistantTierDiagnosticTests — the ladder now says WHY it fell through, and the
// saying must not change WHERE it fell through to.
//
// Every case below pairs the new claim with the old one: alongside each diagnostic
// assertion there is an assertion that the tier order, the produced proposal and
// ``AssistantViewModel/lastError`` are exactly what `AssistantConnectorLadderTests`
// already pins. A diagnostic that silently vetoed a fall-through would pass a test
// that only looked at `lastTierDiagnostic`.
import Foundation
import PlayerCoreTestSupport
import Services
import Testing
@testable import ViewModels

@MainActor
@Suite("Assistant tier diagnostics")
struct AssistantTierDiagnosticTests {
    private static let connectorSpec = PlaylistQuerySpec(genres: ["Jazz"])
    private static let modelSpec = PlaylistQuerySpec(genres: ["Blues"])
    private static let heuristicSpec = PlaylistQuerySpec(genres: ["Rock"])

    private func armPool(_ harness: SubmitHarness) {
        harness.fallback.setSpec(Self.heuristicSpec)
        harness.smartPlaylists.configure { $0.previewTrackIds = [1] }
        harness.mixGenerator.setDraft(SubmitHarness.draft([1]))
    }

    private func resolvedGenres(_ harness: SubmitHarness) -> [String] {
        guard let first = harness.smartPlaylists.recording.previewRequests.first else { return [] }
        return SubmitHarness.genreNames(first.rules.predicates)
    }

    // MARK: Connector tier

    @Test("a connector that throws is recorded, and the heuristic tier still answers")
    func aThrowingConnectorIsRecorded() async {
        let connector = FakeAssistantQueryParser()
        connector.setFailure()
        let harness = SubmitHarness(connectorParser: connector, connectorAvailability: { true })
        armPool(harness)

        let proposal = await harness.viewModel.submit(text: "upbeat 90s rock", profileId: 1)

        #expect(harness.viewModel.lastTierDiagnostic?.isConnectorTier == true)
        if case .connectorFailed = harness.viewModel.lastTierDiagnostic {} else {
            Issue.record("a throwing connector must record .connectorFailed")
        }
        #expect(proposal != nil)
        #expect(harness.viewModel.lastError == nil)
        #expect(resolvedGenres(harness) == ["Rock"])
    }

    @Test("a connector whose own predicate says no is recorded as unavailable")
    func anUnreadyConnectorIsRecorded() async {
        let connector = FakeAssistantQueryParser(spec: Self.connectorSpec)
        let model = FakeAssistantQueryParser(spec: Self.modelSpec)
        let harness = SubmitHarness(
            modelParser: model,
            connectorParser: connector,
            connectorAvailability: { false }
        )
        armPool(harness)

        let proposal = await harness.viewModel.submit(text: "some jazz", profileId: 1)

        #expect(harness.viewModel.lastTierDiagnostic == .connectorUnavailable)
        #expect(proposal != nil)
        #expect(connector.recording.requests.isEmpty)
        #expect(resolvedGenres(harness) == ["Blues"])
    }

    /// The wedged-connector path `AssistantConnectorLadderTests` already covers,
    /// re-asserted here for the diagnostic it now leaves behind.
    @Test("a connector that never answers is recorded as timed out")
    func aHangingConnectorIsRecordedAsTimedOut() async {
        let connector = NeverResolvingQueryParser()
        let harness = SubmitHarness(
            connectorParser: connector,
            connectorAvailability: { true },
            connectorDeadlineSeconds: 0.05
        )
        armPool(harness)

        let proposal = await harness.viewModel.submit(text: "upbeat 90s rock", profileId: 1)

        #expect(harness.viewModel.lastTierDiagnostic == .connectorTimedOut)
        #expect(proposal != nil)
        #expect(!harness.viewModel.isBusy)
        #expect(resolvedGenres(harness) == ["Rock"])
    }

    /// An uninjected connector is the shipped default. It must stay diagnostic-free,
    /// or every default install would show a "your provider went quiet" notice.
    @Test("no connector at all leaves no diagnostic")
    func anUninjectedConnectorLeavesNoDiagnostic() async {
        let model = FakeAssistantQueryParser(spec: Self.modelSpec)
        let harness = SubmitHarness(modelParser: model)
        armPool(harness)

        _ = await harness.viewModel.submit(text: "some jazz", profileId: 1)

        #expect(harness.viewModel.lastTierDiagnostic == nil)
        #expect(resolvedGenres(harness) == ["Blues"])
    }

    @Test("a connector that answers leaves no diagnostic")
    func anAnsweringConnectorLeavesNoDiagnostic() async {
        let connector = FakeAssistantQueryParser(spec: Self.connectorSpec)
        let harness = SubmitHarness(connectorParser: connector, connectorAvailability: { true })
        armPool(harness)

        _ = await harness.viewModel.submit(text: "some jazz", profileId: 1)

        #expect(harness.viewModel.lastTierDiagnostic == nil)
        #expect(resolvedGenres(harness) == ["Jazz"])
    }

    // MARK: Model tier

    @Test("a throwing FoundationModels tier is recorded, and the heuristic tier answers")
    func aThrowingModelTierIsRecorded() async {
        let model = FakeAssistantQueryParser()
        model.setFailure()
        let harness = SubmitHarness(modelParser: model)
        armPool(harness)

        let proposal = await harness.viewModel.submit(text: "upbeat 90s rock", profileId: 1)

        #expect(harness.viewModel.lastTierDiagnostic?.isConnectorTier == false)
        if case .modelFailed = harness.viewModel.lastTierDiagnostic {} else {
            Issue.record("a throwing model tier must record .modelFailed")
        }
        #expect(proposal != nil)
        #expect(resolvedGenres(harness) == ["Rock"])
    }

    /// A Mac that cannot run Apple Intelligence is not a failure — the FM tier is
    /// SKIPPED, and skipping must leave nothing to report.
    @Test("an unavailable model reading skips the tier without a diagnostic")
    func anUnavailableModelReadingIsNotADiagnostic() async {
        let model = FakeAssistantQueryParser(spec: Self.modelSpec)
        let harness = SubmitHarness(
            modelParser: model,
            availability: { .unavailable(reason: .deviceNotEligible) }
        )
        armPool(harness)

        _ = await harness.viewModel.submit(text: "upbeat 90s rock", profileId: 1)

        #expect(harness.viewModel.lastTierDiagnostic == nil)
        #expect(model.recording.requests.isEmpty)
        #expect(resolvedGenres(harness) == ["Rock"])
    }

    // MARK: Lifetime

    @Test("the diagnostic is cleared by the next submit")
    func theDiagnosticIsClearedByTheNextSubmit() async {
        let connector = FakeAssistantQueryParser()
        connector.setFailure()
        let harness = SubmitHarness(connectorParser: connector, connectorAvailability: { true })
        armPool(harness)

        _ = await harness.viewModel.submit(text: "upbeat 90s rock", profileId: 1)
        #expect(harness.viewModel.lastTierDiagnostic != nil)

        connector.setFailure(nil)
        connector.setSpec(Self.connectorSpec)
        _ = await harness.viewModel.submit(text: "some jazz", profileId: 1)

        #expect(harness.viewModel.lastTierDiagnostic == nil)
    }

    /// Both signals at once: a provider that failed AND a request that matched
    /// nothing. The UI needs to be able to say both, so neither may clobber the other.
    @Test("a failing tier and an empty result are reported together")
    func aFailingTierAndAnEmptyResultCoexist() async {
        let connector = FakeAssistantQueryParser()
        connector.setFailure()
        let harness = SubmitHarness(connectorParser: connector, connectorAvailability: { true })
        harness.fallback.setSpec(Self.heuristicSpec)
        harness.smartPlaylists.configure { $0.previewTrackIds = [] }

        let proposal = await harness.viewModel.submit(text: "upbeat 90s rock", profileId: 1)

        #expect(proposal == nil)
        #expect(harness.viewModel.lastError == .noMatchingTracks)
        #expect(harness.viewModel.lastTierDiagnostic?.isConnectorTier == true)
    }

    /// The listener's own switch stops everything BEFORE the ladder, so there is no
    /// tier to blame — the pane must show the "Intelligence is off" reason alone.
    @Test("the intelligence-off refusal records lastError and no diagnostic")
    func theIntelligenceOffRefusalRecordsNoDiagnostic() async {
        let connector = FakeAssistantQueryParser(spec: Self.connectorSpec)
        let harness = SubmitHarness(
            connectorParser: connector,
            connectorAvailability: { true },
            availability: { .unavailable(reason: .intelligenceDisabled) }
        )
        armPool(harness)

        let proposal = await harness.viewModel.submit(text: "some jazz", profileId: 1)

        #expect(proposal == nil)
        #expect(harness.viewModel.lastError == .assistantUnavailable(reason: .intelligenceDisabled))
        #expect(harness.viewModel.lastTierDiagnostic == nil)
    }
}
