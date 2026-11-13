// AssistantViewModel+Ladder — the read-only generation path: four tiers of parsing,
// then a bounded rule preview, then a mix.
//
// Split out of ``AssistantViewModel`` so that file holds only the dependency stacks
// and the published state; the members are internal (not `private`) because they now
// live in a sibling file. Nothing here writes: every call below is a parse, a
// READ-ONLY id preview, or a pure aggregate.
//
// ── THE LADDER, AND WHY EVERY TIER STILL FALLS THROUGH ─────────────────────────
//
// Order is unchanged from the day it shipped:
//
//   connector parser, if injected AND its OWN predicate passes -> deadline-bounded
//   FM parser, if injected AND available  ->  on ANY throw, fall through
//   heuristic parser (never throws, per its own contract)
//   deterministic default (its shape mirrors `HeuristicQueryParser`'s tier 4)
//
// What changed is only that a fall-through is now RECORDED. The `try?`s that used to
// swallow a tier's throw are `do`/`catch` blocks which set
// ``AssistantViewModel/lastTierDiagnostic`` and then fall through exactly as before —
// same order, same outcome, same proposal. A diagnostic is a note about the route
// taken, never a veto: a connector that fails must still end in a playlist from the
// local tiers, because that degradation is the whole reason the lower tiers exist.
//
// The heuristic tier keeps its bare `try?`: `NaturalLanguageQueryParsing`'s
// contract for it is that parsing never throws, so a diagnostic case for it would
// describe a state its conformer cannot reach.
import Foundation
import Persistence
import Services

// MARK: - Connector outcome

/// What the connector tier did, so a fall-through can say WHY it fell through.
///
/// File-scoped rather than nested in ``AssistantViewModel``: the value is produced
/// inside a detached, non-isolated `Task` and must stay free of the view model's
/// main-actor isolation.
private enum ConnectorOutcome {
    case answered(PlaylistQuerySpec)
    case notReady
    case failed(String)
    case timedOut
}

// MARK: - Proposal generation (reads only)

extension AssistantViewModel {
    func proposal(
        for request: String,
        profileId: Int64,
        locale: Locale,
        reading: AssistantAvailability
    ) async -> AIProposal? {
        let spec = await resolvedSpec(for: request, locale: locale, reading: reading)
        let draft: PlaylistDraft
        do {
            draft = try await generatedDraft(for: spec, profileId: profileId)
        } catch {
            setLastError(.generationFailed(reason: String(describing: error)))
            return nil
        }
        guard !draft.isEmpty else {
            setLastError(.noMatchingTracks)
            return nil
        }
        let created = await createRequest(draft: draft, spec: spec, request: request, locale: locale)
        let proposal = AIProposal(profileId: profileId, kind: .createPlaylist(created))
        proposals.add(proposal)
        return proposal
    }

    /// Connector tier, then FM tier, then the heuristic tier, then tier 4. Every
    /// tier's throw falls through to the next, recording why on the way past.
    func resolvedSpec(
        for request: String,
        locale: Locale,
        reading: AssistantAvailability
    ) async -> PlaylistQuerySpec {
        if let spec = await connectorSpec(for: request, locale: locale) {
            return spec
        }
        if let spec = await modelSpec(for: request, locale: locale, reading: reading) {
            return spec
        }
        if let spec = try? await backends.fallbackParser.parse(text: request, locale: locale) {
            return spec
        }
        return Self.deterministicDefault
    }

    /// The FoundationModels tier. Gated exactly as before — an absent parser or an
    /// unavailable reading skips it WITHOUT a diagnostic, because neither is a
    /// failure: they are the ordinary state of a Mac that cannot run the model.
    func modelSpec(
        for request: String,
        locale: Locale,
        reading: AssistantAvailability
    ) async -> PlaylistQuerySpec? {
        guard let modelParser = backends.modelParser, reading.isAvailable else { return nil }
        do {
            return try await modelParser.parse(text: request, locale: locale)
        } catch {
            setTierDiagnostic(.modelFailed(reason: String(describing: error)))
            return nil
        }
    }

    /// The connector tier, bounded by its own deadline.
    ///
    /// The race is PlayerCore-LOCAL on purpose: a connector conformer lives in a
    /// separate package that ships its own deadline helper, but the dependency
    /// direction is kit -> PlayerCore and must stay that way.
    ///
    /// The parse runs in an UNSTRUCTURED task nothing awaits. A task group re-awaits
    /// every child on scope exit, so a conformer parked in a continuation it never
    /// resumes would hang the ladder despite the timer firing; cancelling and then
    /// ABANDONING is the only bound that holds against a non-cooperative tier.
    func connectorSpec(for request: String, locale: Locale) async -> PlaylistQuerySpec? {
        guard let parser = backends.connectorParser else { return nil }
        let isReady = backends.connectorAvailability
        let seconds = max(0, backends.connectorDeadlineSeconds)
        let (results, sink) = AsyncStream<ConnectorOutcome>.makeStream()
        let parse = Task {
            guard await isReady() else {
                sink.yield(.notReady)
                return
            }
            do {
                let spec = try await parser.parse(text: request, locale: locale)
                sink.yield(.answered(spec))
            } catch {
                sink.yield(.failed(String(describing: error)))
            }
        }
        let deadline = Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            sink.yield(.timedOut)
        }
        defer {
            parse.cancel()
            deadline.cancel()
            sink.finish()
        }
        for await outcome in results {
            return judged(outcome)
        }
        return nil
    }
}

// MARK: - Draft, naming, seed

private extension AssistantViewModel {
    /// Records the diagnostic for a non-answer and hands back the spec, or `nil` so
    /// the ladder falls through — the ONE place a connector outcome is judged.
    func judged(_ outcome: ConnectorOutcome) -> PlaylistQuerySpec? {
        switch outcome {
        case let .answered(spec):
            return spec
        case .notReady:
            setTierDiagnostic(.connectorUnavailable)
        case let .failed(reason):
            setTierDiagnostic(.connectorFailed(reason: reason))
        case .timedOut:
            setTierDiagnostic(.connectorTimedOut)
        }
        return nil
    }

    /// Rule variants -> READ-ONLY id preview per variant -> merged pool -> mix.
    ///
    /// `previewTrackIds` rather than `evaluate` is the load-bearing choice: an
    /// evaluation would rewrite `playlistTrack` rows for a playlist the listener
    /// has not agreed to yet.
    func generatedDraft(for spec: PlaylistQuerySpec, profileId: Int64) async throws -> PlaylistDraft {
        let variants = AssistantQueryTranslation.ruleVariants(
            for: spec,
            now: now(),
            limit: MixGeneratorService.maxPoolSize
        )
        var variantResults: [[Int64]] = []
        for rules in variants {
            let ids = try await repositories.smartPlaylists.previewTrackIds(
                matching: rules,
                profileId: profileId
            )
            variantResults.append(ids)
        }
        let trackIds = AssistantQueryTranslation.mergedTrackIds(variantResults)
        guard !trackIds.isEmpty else { return .empty(sourceKind: .rulesResult) }
        return try await repositories.mixGenerator.generate(
            MixSpec(
                profileId: profileId,
                source: .rulesResult(trackIds: trackIds),
                targetCount: spec.targetCount,
                seed: Self.seed(forRequest: spec.description(withRequest: trackIds))
            )
        )
    }

    /// Names the draft, falling back to the listener's own words.
    ///
    /// The naming context carries only what this layer HONESTLY knows: the draft
    /// holds track ids, provenance and energy — no artist or genre metadata — so
    /// the ranked aggregate lists are left empty rather than filled with invented
    /// counts. Enriching them needs a metadata resolver a later todo can inject.
    func createRequest(
        draft: PlaylistDraft,
        spec: PlaylistQuerySpec,
        request: String,
        locale: Locale
    ) async -> CreatePlaylistRequest {
        let context = PlaylistNamingContext(
            trackCount: draft.entries.count,
            dominantDecade: spec.yearRange?.lower.map { $0 - $0 % 10 },
            moodTags: spec.moodTags
        )
        let generated = try? await backends.naming?.suggestName(for: context, locale: locale)
        let name = generated?.name ?? PlaylistNamingResult(name: request).name
        return CreatePlaylistRequest(
            draft: draft,
            name: name.isEmpty ? request : name,
            summary: generated?.description,
            querySpec: spec
        )
    }

    /// FNV-1a 64 over the pooled ids — the same derivation
    /// `GeneratedPlaylistService` uses, so equal pools reproduce equal drafts and
    /// a changed library reshuffles.
    nonisolated static func seed(forRequest text: String) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }
}

private extension PlaylistQuerySpec {
    /// A stable, ordering-preserving string over everything that decides a mix, so
    /// the seed changes when the request or the matched pool changes and only then.
    func description(withRequest trackIds: [Int64]) -> String {
        let parts = genres + moodTags.map(\.rawValue) + [String(targetCount)]
        return (parts + trackIds.map(String.init)).joined(separator: "|")
    }
}
