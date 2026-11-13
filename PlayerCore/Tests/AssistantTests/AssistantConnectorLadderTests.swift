// AssistantConnectorLadderTests — todo 11 acceptance: the ORDER of the four-tier
// ladder, and the deadline that stops a wedged connector wedging the view model.
//
// Order is asserted from the SEAMS rather than from the produced spec alone: a test
// that only checked the genre could pass while a lower tier was also consulted, and
// "the connector answered" and "only the connector ran" are different claims.
import Foundation
import os
import PlayerCoreTestSupport
import Services
import Testing
@testable import ViewModels

// MARK: - Stubs

/// A parser that ENTERS `parse` and never leaves, performing no transport call of
/// any kind — the hang the ladder's deadline exists for.
///
/// `withUnsafeContinuation` rather than `withCheckedContinuation` deliberately: the
/// checked variant reports a never-resumed continuation as misuse, and never
/// resuming is precisely this stub's job. The ladder abandons the task, which then
/// parks at zero CPU for the rest of the process.
struct NeverResolvingQueryParser: NaturalLanguageQueryParsing {
    private let entries = OSAllocatedUnfairLock(initialState: 0)

    /// How many times `parse` was entered. Recorded BEFORE parking, so a wedged
    /// call is already counted while it is still in flight.
    var enteredCount: Int {
        entries.withLock { $0 }
    }

    func parse(text _: String, locale _: Locale) async throws -> PlaylistQuerySpec {
        entries.withLock { $0 += 1 }
        await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in }
        return PlaylistQuerySpec()
    }
}

/// A connector readiness predicate that counts how often the ladder asked.
struct CountingConnectorPredicate {
    private let calls = OSAllocatedUnfairLock(initialState: 0)
    let answer: Bool

    init(answer: Bool = true) {
        self.answer = answer
    }

    var callCount: Int {
        calls.withLock { $0 }
    }

    var predicate: @Sendable () async -> Bool {
        let box = calls
        let result = answer
        return {
            box.withLock { $0 += 1 }
            return result
        }
    }
}

// MARK: - Tier order

@MainActor
struct AssistantConnectorLadderTests {
    // MARK: Fixtures

    private static let connectorSpec = PlaylistQuerySpec(genres: ["Jazz"])
    private static let modelSpec = PlaylistQuerySpec(genres: ["Blues"])
    private static let heuristicSpec = PlaylistQuerySpec(genres: ["Rock"])

    /// Arms the read-only preview and the mix so a resolved spec reaches a proposal.
    private func armPool(_ harness: SubmitHarness) {
        harness.fallback.setSpec(Self.heuristicSpec)
        harness.smartPlaylists.configure { $0.previewTrackIds = [1] }
        harness.mixGenerator.setDraft(SubmitHarness.draft([1]))
    }

    /// The genres the FIRST compiled rule variant filtered on — i.e. which tier's
    /// spec actually reached the query translation.
    private func resolvedGenres(_ harness: SubmitHarness) -> [String] {
        guard let first = harness.smartPlaylists.recording.previewRequests.first else { return [] }
        return SubmitHarness.genreNames(first.rules.predicates)
    }

    // MARK: The matrix

    @Test func theConnectorTierWinsWhenItsOwnPredicatePasses() async {
        let connector = FakeAssistantQueryParser(spec: Self.connectorSpec)
        let model = FakeAssistantQueryParser(spec: Self.modelSpec)
        let harness = SubmitHarness(
            modelParser: model,
            connectorParser: connector,
            connectorAvailability: { true }
        )
        armPool(harness)

        _ = await harness.viewModel.submit(text: "some jazz", profileId: 1)

        #expect(connector.recording.requests.map(\.text) == ["some jazz"])
        #expect(model.recording.requests.isEmpty)
        #expect(harness.fallback.recording.requests.isEmpty)
        #expect(resolvedGenres(harness) == ["Jazz"])
    }

    @Test func theModelTierAnswersWhenTheConnectorPredicateIsFalse() async {
        let connector = FakeAssistantQueryParser(spec: Self.connectorSpec)
        let model = FakeAssistantQueryParser(spec: Self.modelSpec)
        let harness = SubmitHarness(
            modelParser: model,
            connectorParser: connector,
            connectorAvailability: { false }
        )
        armPool(harness)

        _ = await harness.viewModel.submit(text: "some jazz", profileId: 1)

        #expect(connector.recording.requests.isEmpty)
        #expect(model.recording.requests.map(\.text) == ["some jazz"])
        #expect(harness.fallback.recording.requests.isEmpty)
        #expect(resolvedGenres(harness) == ["Blues"])
    }

    @Test func theHeuristicTierAnswersWhenTheConnectorAndModelBothFail() async {
        let connector = FakeAssistantQueryParser()
        connector.setFailure()
        let model = FakeAssistantQueryParser()
        model.setFailure()
        let harness = SubmitHarness(
            modelParser: model,
            connectorParser: connector,
            connectorAvailability: { true }
        )
        armPool(harness)

        let proposal = await harness.viewModel.submit(text: "upbeat 90s rock", profileId: 1)

        #expect(proposal != nil)
        #expect(connector.recording.requests.count == 1)
        #expect(model.recording.requests.count == 1)
        #expect(harness.fallback.recording.requests.map(\.text) == ["upbeat 90s rock"])
        #expect(resolvedGenres(harness) == ["Rock"])
    }

    /// The non-Apple-Intelligence Mac: the FM tier is vetoed by the system reading,
    /// and the connector — which owns a DIFFERENT predicate — still answers. This is
    /// the whole reason the connector tier must not read ``AssistantAvailability``.
    @Test func theConnectorTierAnswersOnAMacWithoutAppleIntelligence() async {
        let connector = FakeAssistantQueryParser(spec: Self.connectorSpec)
        let model = FakeAssistantQueryParser(spec: Self.modelSpec)
        let harness = SubmitHarness(
            modelParser: model,
            connectorParser: connector,
            connectorAvailability: { true },
            availability: { .unavailable(reason: .deviceNotEligible) }
        )
        armPool(harness)

        let proposal = await harness.viewModel.submit(text: "some jazz", profileId: 1)

        #expect(proposal != nil)
        #expect(connector.recording.requests.count == 1)
        #expect(model.recording.requests.isEmpty)
        #expect(harness.fallback.recording.requests.isEmpty)
        #expect(resolvedGenres(harness) == ["Jazz"])
        #expect(harness.viewModel.availability == .unavailable(reason: .deviceNotEligible))
    }

    // MARK: The hard gate the connector cannot bypass

    /// The master / `.nlCreation` gate is above the ladder, not inside it: a ready
    /// connector must not get a request, and must not even be asked whether it is
    /// ready, while the listener has the feature switched off.
    @Test func theListenersOwnSwitchStopsTheConnectorTierBeforeItIsEvenProbed() async {
        let connector = FakeAssistantQueryParser(spec: Self.connectorSpec)
        let readiness = CountingConnectorPredicate()
        let harness = SubmitHarness(
            connectorParser: connector,
            connectorAvailability: readiness.predicate,
            availability: { .unavailable(reason: .intelligenceDisabled) }
        )
        armPool(harness)

        let proposal = await harness.viewModel.submit(text: "some jazz", profileId: 1)

        #expect(proposal == nil)
        #expect(harness.viewModel.lastError == .assistantUnavailable(reason: .intelligenceDisabled))
        #expect(readiness.callCount == 0)
        #expect(connector.recording.requests.isEmpty)
        #expect(harness.store.isEmpty)
    }

    /// The unconfigured default must cost exactly what it cost before this tier
    /// existed — including not evaluating a predicate nobody wired a parser to.
    @Test func anUninjectedConnectorIsNeverProbed() async {
        let model = FakeAssistantQueryParser(spec: Self.modelSpec)
        let readiness = CountingConnectorPredicate()
        let harness = SubmitHarness(
            modelParser: model,
            connectorAvailability: readiness.predicate
        )
        armPool(harness)

        _ = await harness.viewModel.submit(text: "some jazz", profileId: 1)

        #expect(readiness.callCount == 0)
        #expect(model.recording.requests.count == 1)
        #expect(resolvedGenres(harness) == ["Blues"])
    }

    // MARK: The deadline

    /// A connector that never returns releases the busy latch anyway, and the
    /// heuristic tier answers — with NO transport call anywhere in the stub.
    @Test func aHangingConnectorReleasesTheBusyLatchAndTheHeuristicAnswers() async {
        let connector = NeverResolvingQueryParser()
        let harness = SubmitHarness(
            connectorParser: connector,
            connectorAvailability: { true },
            connectorDeadlineSeconds: 0.05
        )
        armPool(harness)

        let proposal = await harness.viewModel.submit(text: "upbeat 90s rock", profileId: 1)

        #expect(proposal != nil)
        #expect(!harness.viewModel.isBusy)
        #expect(harness.viewModel.lastError == nil)
        #expect(connector.enteredCount == 1)
        #expect(harness.fallback.recording.requests.map(\.text) == ["upbeat 90s rock"])
        #expect(resolvedGenres(harness) == ["Rock"])
    }

    // MARK: The stack's own defaults

    @Test func theStackCarriesANarrationSlotAndAnInertConnectorByDefault() async {
        let stack = AssistantBackendStack(
            fallbackParser: FakeAssistantQueryParser(),
            narrating: FakeAssistantNarrator()
        )

        #expect(stack.narrating != nil)
        #expect(stack.connectorParser == nil)
        #expect(stack.connectorDeadlineSeconds == AssistantBackendStack.defaultConnectorDeadlineSeconds)
        let isReady = await stack.connectorAvailability()
        #expect(isReady == false)
    }
}
