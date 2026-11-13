import Foundation
import Metadata
import os
import Persistence
import PlayerCoreTestSupport
import Services
@testable import ViewModels

/// An ``AssistantViewModel`` wired over recording fakes only, for the submit path.
///
/// Distinct from `ViewModelTests`' own harness because the two suites are separate
/// targets: `AssistantTests` owns the ladder and the read-only generation contract,
/// `ViewModelTests` owns the store and the apply routing.
@MainActor
struct SubmitHarness {
    let store = ProposalStore()
    let playlists = FakePlaylistRepository()
    let smartPlaylists = FakeSmartPlaylistRepository()
    let mixGenerator = FakeMixGeneratorService()
    let fallback = FakeAssistantQueryParser()
    let viewModel: AssistantViewModel

    init(
        modelParser: (any NaturalLanguageQueryParsing)? = nil,
        connectorParser: (any NaturalLanguageQueryParsing)? = nil,
        connectorAvailability: @escaping @Sendable () async -> Bool = { false },
        connectorDeadlineSeconds: Double = AssistantBackendStack.defaultConnectorDeadlineSeconds,
        fallback fallbackOverride: (any NaturalLanguageQueryParsing)? = nil,
        availability: @escaping @Sendable () -> AssistantAvailability = { .available }
    ) {
        viewModel = AssistantViewModel(
            proposals: store,
            backends: AssistantBackendStack(
                fallbackParser: fallbackOverride ?? fallback,
                modelParser: modelParser,
                connectorParser: connectorParser,
                connectorAvailability: connectorAvailability,
                connectorDeadlineSeconds: connectorDeadlineSeconds
            ),
            repositories: AssistantRepositoryStack(
                playlists: playlists,
                smartPlaylists: smartPlaylists,
                mixGenerator: mixGenerator
            ),
            availabilityProbe: availability,
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
    }

    nonisolated static func draft(_ trackIds: [Int64]) -> PlaylistDraft {
        PlaylistDraft(
            entries: trackIds.map { MixDraftEntry(trackId: $0, provenance: .rulesResult, score: 1) },
            nameHint: MixNameHint(sourceKind: .rulesResult, trackCount: trackIds.count)
        )
    }

    /// The genre names a compiled variant filters on, in predicate order.
    nonisolated static func genreNames(_ predicates: [SmartPlaylistPredicate]) -> [String] {
        predicates.compactMap { predicate in
            guard case let .metadata(metadata) = predicate,
                  case let .genre(equals: name) = metadata
            else {
                return nil
            }
            return name
        }
    }
}

/// A parser that parks inside `parse` until released, so "a second request while
/// one is in flight" is provable without a sleep.
///
/// The same shape as `FakeAssistantQueryResponder`'s hold/release gate: yield-based
/// polling cannot pass by waiting long enough — it only advances when the pool
/// actually runs the other task.
struct GatedQueryParser: NaturalLanguageQueryParsing {
    private struct GateState {
        var texts: [String] = []
        var isHeld = true
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let gate = OSAllocatedUnfairLock(initialState: GateState())

    /// Requests entered, in call order — recorded BEFORE parking, so a held call is
    /// already counted while it is still in flight.
    var requestedTexts: [String] {
        gate.withLock { $0.texts }
    }

    func parse(text: String, locale _: Locale) async throws -> PlaylistQuerySpec {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let shouldWait = gate.withLock { current -> Bool in
                current.texts.append(text)
                guard current.isHeld else { return false }
                current.waiters.append(continuation)
                return true
            }
            if !shouldWait {
                continuation.resume()
            }
        }
        return PlaylistQuerySpec()
    }

    /// Yields until `parse` has been entered, or gives up so a caller asserts
    /// rather than hangs.
    @discardableResult
    func waitUntilStarted(iterations: Int = 10000) async -> Bool {
        for _ in 0 ..< iterations {
            if !requestedTexts.isEmpty { return true }
            await Task.yield()
        }
        return !requestedTexts.isEmpty
    }

    func release() {
        let waiters = gate.withLock { current -> [CheckedContinuation<Void, Never>] in
            current.isHeld = false
            let pending = current.waiters
            current.waiters = []
            return pending
        }
        for waiter in waiters {
            waiter.resume()
        }
    }
}
