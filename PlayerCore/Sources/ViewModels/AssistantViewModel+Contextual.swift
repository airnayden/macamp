// AssistantViewModel+Contextual — the proposals a MENU CLICK produces.
//
// ``AssistantViewModel/submit(text:profileId:locale:)`` answers a SENTENCE: it runs
// the parser ladder, lowers a ``PlaylistQuerySpec`` to rule variants, and only then
// reaches ``MixGenerating``. A contextual action ("More Like This" on a track,
// "Surprise Me" in the library toolbar, "Organize…" on a playlist) is not a sentence
// — the listener already said exactly what they want by clicking it. Routing one
// through the parser would mean inventing a request string, parsing it back, and
// hoping the round trip returned the source we started from.
//
// So every method here goes STRAIGHT to the seam the action names — a
// ``MixCandidateSource``, a membership rewrite, a ``PlaylistNaming`` call — and
// files the result in the SAME ``ProposalStore`` `submit` uses, so the same preview
// sheet reviews it and the same ``AssistantViewModel/apply(_:confirmedBatch:)``
// is still the only thing that writes.
//
// ── GATING LIVES AT THE CALL SITE, DELIBERATELY ────────────────────────────────
//
// Nothing here consults ``availabilityProbe``. That probe is bound to ONE bundle at
// composition time (`.nlCreation`, for the assistant pane), and these actions belong
// to three DIFFERENT bundles — `.nlCreation` for "More Like This", `.rediscovery`
// for "Surprise Me", `.organization` for "Organize…". Checking the assistant's probe
// here would silently refuse a rediscovery mix on a machine whose listener had only
// switched natural-language creation off. The shell hides each menu item behind its
// own `AISettingsProviding.isEnabled(_:)`, and the master toggle is enforced
// structurally one level up: with Intelligence off no AI graph — and therefore no
// view model — exists at all.
//
// NOTHING HERE WRITES. Every method reads, ranks, and files a value. Same rule as
// `submit`, same enforcement: no repository mutation is reachable from this file.
import Foundation
import Metadata
import Persistence
import Services

// MARK: - Mixes from a named source

public extension AssistantViewModel {
    /// Files a `createPlaylist` proposal for one candidate pool, bypassing every
    /// natural-language tier.
    ///
    /// - Parameters:
    ///   - source: The pool the mix is drawn from — `.similaritySeed` for "More
    ///     Like This", `.rediscovery` for "Surprise Me", `.rulesResult` for a
    ///     cluster the caller already assembled.
    ///   - name: The playlist name, ALREADY in the listener's language. The caller
    ///     supplies it rather than the naming ladder deriving one, because the
    ///     caller knows what was clicked ("More Like <this track>") while a
    ///     ``PlaylistNamingContext`` built from a draft knows only aggregates the
    ///     draft does not carry — it would name every contextual mix generically.
    ///   - profileId: The profile the pool and the proposal are scoped to.
    ///   - targetCount: Draft length, clamped by ``MixSpec`` to `1...100`.
    /// - Returns: The filed proposal, or `nil` when a request is already in flight
    ///   or the pool produced nothing. Never throws: failures land in ``lastError``,
    ///   non-failures in ``lastUnavailability``.
    @discardableResult
    func proposeMix(
        from source: MixCandidateSource,
        named name: String,
        profileId: Int64,
        targetCount: Int = MixSpec.defaultTargetCount
    ) async -> AIProposal? {
        setUnavailability(nil)
        guard !isBusy else {
            setUnavailability(.busy)
            return nil
        }
        setBusy(true)
        setLastError(nil)
        defer { setBusy(false) }
        guard let draft = await generatedMix(
            source: source,
            profileId: profileId,
            targetCount: targetCount,
            seedText: name
        ) else { return nil }
        let proposal = AIProposal(
            profileId: profileId,
            kind: .createPlaylist(CreatePlaylistRequest(draft: draft, name: name))
        )
        proposals.add(proposal)
        return proposal
    }
}

// MARK: - Organizing an existing playlist

public extension AssistantViewModel {
    /// Files an `organize` proposal that re-orders `orderedTrackIds` into
    /// ``MixRanking``'s rise → peak → fall energy arc.
    ///
    /// MEMBERSHIP IS PRESERVED BY CONSTRUCTION. The mix pipeline resolves metadata
    /// and drops what it cannot resolve (an unavailable file, a row the profile
    /// cannot see), so the arc it returns can be SHORTER than the playlist. Anything
    /// it dropped is appended in its original relative order rather than trusted to
    /// the draft, because an "organize" that quietly deleted a listener's tracks
    /// would be the worst possible reading of the word.
    ///
    /// - Returns: `nil` — with ``lastError`` untouched but ``lastUnavailability``
    ///   set — for each of the four non-failure outcomes: the selection is too
    ///   short (``AIProposalUnavailability/selectionTooShort(minimum:)``), longer
    ///   than ``MixSpec/maxTargetCount`` (``selectionTooLong(limit:)`` — the
    ///   generator would rank only a prefix, so the arc would describe part of the
    ///   list while claiming the whole), too little of it carries analysed energy
    ///   (``insufficientAnalysis(required:)``, ``MixRanking/energyArcCoverage``),
    ///   or the arc changed nothing (``nothingToChange``). None of those is a
    ///   failure; the caller reports each as its own unavailable action.
    @discardableResult
    func proposeEnergyReorder(
        playlistId: Int64,
        orderedTrackIds: [Int64],
        profileId: Int64
    ) async -> AIProposal? {
        setUnavailability(nil)
        guard !isBusy else {
            setUnavailability(.busy)
            return nil
        }
        let current = Self.firstOccurrences(of: orderedTrackIds)
        guard current.count >= MixRanking.minimumArcLength else {
            setUnavailability(.selectionTooShort(minimum: MixRanking.minimumArcLength))
            return nil
        }
        guard current.count <= MixSpec.maxTargetCount else {
            setUnavailability(.selectionTooLong(limit: MixSpec.maxTargetCount))
            return nil
        }
        setBusy(true)
        setLastError(nil)
        defer { setBusy(false) }
        guard let draft = await generatedMix(
            source: .rulesResult(trackIds: current),
            profileId: profileId,
            targetCount: current.count,
            // Spacing 1 disables de-clumping: this is a RE-ORDER of a list the
            // listener curated, so the only rule allowed to move a track is the arc.
            constraints: MixConstraints(artistSpacing: 1, energyArc: true),
            seedText: "energyArc"
        ) else { return nil }
        // The arc is the ONLY thing this method asked the pipeline for, so the
        // pipeline declining to apply it means exactly one thing: after metadata
        // resolution dropped what it could not resolve, the surviving selection
        // was below `energyArcCoverage`. `minimumArcLength` is already guarded
        // above, and `energyArc: true` was requested.
        guard draft.energyArcApplied else {
            setUnavailability(.insufficientAnalysis(required: MixRanking.energyArcCoverage))
            return nil
        }
        let arced = draft.trackIds
        let covered = Set(arced)
        let proposed = arced + current.filter { !covered.contains($0) }
        let diff = PlaylistOrganizeDiff(currentTrackIds: current, proposedTrackIds: proposed)
        guard !diff.isEmpty else {
            setUnavailability(.nothingToChange)
            return nil
        }
        let proposal = AIProposal(profileId: profileId, kind: .organize(playlistId: playlistId, diff: diff))
        proposals.add(proposal)
        return proposal
    }

    /// Files an `organize` proposal that drops every redundant entry from a
    /// playlist's membership, keeping the FIRST occurrence of each recording.
    ///
    /// Pure and synchronous — it reads `tracks` and nothing else, so a caller that
    /// already has the playlist's loaded rows needs no database round trip.
    ///
    /// - Returns: `nil` when the playlist lists nothing twice, AND when the only
    ///   redundancy is the SAME row listed twice. ``PlaylistOrganizeDiff`` collapses
    ///   repeated ids in both of its inputs by design — `playlistTrack` is positioned
    ///   and a repeat cannot be materialised — so such a proposal would preview as
    ///   "this would change nothing" while actually dropping an entry. Refusing it is
    ///   the only answer that keeps the preview equal to the write. Either way
    ///   ``lastUnavailability`` reads ``AIProposalUnavailability/nothingToChange``.
    @discardableResult
    func proposeMembershipCleanup(
        playlistId: Int64,
        tracks: [TrackRecord],
        profileId: Int64
    ) -> AIProposal? {
        setUnavailability(nil)
        let current = tracks.compactMap(\.id)
        let diff = PlaylistOrganizeDiff(
            currentTrackIds: current,
            proposedTrackIds: Self.deduplicatedMembership(tracks)
        )
        guard !diff.isEmpty else {
            setUnavailability(.nothingToChange)
            return nil
        }
        let proposal = AIProposal(profileId: profileId, kind: .organize(playlistId: playlistId, diff: diff))
        proposals.add(proposal)
        return proposal
    }

    /// Files a `rename` proposal carrying the name the naming ladder suggests.
    ///
    /// The ladder is ``FallbackPlaylistNaming`` in production, so this answers on
    /// every machine: a model-written name where one is reachable, an
    /// ``AssistantNamingTemplates`` name everywhere else.
    ///
    /// - Returns: `nil` when the view model was composed without a naming tier
    ///   (``AIProposalUnavailability/backendUnavailable``), or when the suggestion
    ///   was empty or matched `currentName` (``nothingToChange``) — renaming a
    ///   playlist to the name it already has is not a change worth reviewing.
    @discardableResult
    func proposeRename(
        playlistId: Int64,
        currentName: String,
        context: PlaylistNamingContext,
        profileId: Int64,
        locale: Locale = .current
    ) async -> AIProposal? {
        setUnavailability(nil)
        guard !isBusy else {
            setUnavailability(.busy)
            return nil
        }
        guard let naming = backends.naming else {
            setUnavailability(.backendUnavailable)
            return nil
        }
        setBusy(true)
        setLastError(nil)
        defer { setBusy(false) }
        guard let result = try? await naming.suggestName(for: context, locale: locale) else {
            setUnavailability(.backendUnavailable)
            return nil
        }
        let suggestion = result.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !suggestion.isEmpty, suggestion != currentName else {
            setUnavailability(.nothingToChange)
            return nil
        }
        let proposal = AIProposal(
            profileId: profileId,
            kind: .rename(playlistId: playlistId, name: suggestion)
        )
        proposals.add(proposal)
        return proposal
    }
}

// MARK: - Pure membership rules

public extension AssistantViewModel {
    /// The membership `tracks` would have with every redundant entry removed, in
    /// playing order.
    ///
    /// Two things count as redundant, and both really happen: the SAME library row
    /// listed twice (`playlistTrack` is keyed by position, so `addTrack` can append
    /// a row the playlist already holds), and two DIFFERENT rows that are the same
    /// recording — the case `LibraryHygieneService` finds library-wide.
    ///
    /// The recording test reuses ``SortKey`` for the title/artist fold, so this
    /// agrees with what the browse list already shows the listener, and
    /// ``LibraryHygieneService/durationTolerance`` for the runtime window, so it
    /// agrees with the library-wide analyzer rather than inventing a second rule.
    /// A track with no title, or with an unknown duration, is never merged with
    /// another: a false negative leaves a duplicate in place, while a false positive
    /// would propose deleting a listener's track.
    ///
    /// `nonisolated` so it is callable — and testable — off the main actor; a
    /// `static` member of a `@MainActor` type is otherwise isolated.
    nonisolated static func deduplicatedMembership(_ tracks: [TrackRecord]) -> [Int64] {
        var keptIds = Set<Int64>()
        var keptRecordings: [(key: String, duration: TimeInterval)] = []
        var kept: [Int64] = []
        for track in tracks {
            guard let trackId = track.id, !keptIds.contains(trackId) else { continue }
            if let recording = recordingSignature(of: track) {
                let isRepeat = keptRecordings.contains { held in
                    held.key == recording.key
                        && abs(held.duration - recording.duration) <= LibraryHygieneService.durationTolerance
                }
                if isRepeat { continue }
                keptRecordings.append(recording)
            }
            keptIds.insert(trackId)
            kept.append(trackId)
        }
        return kept
    }

    /// `ids` with every repeat after the first dropped, order preserved.
    ///
    /// ``PlaylistOrganizeDiff`` collapses repeats itself, but the arc has to be
    /// asked for a pool it can actually rank, so the collapse happens before the
    /// generator sees the list rather than after.
    nonisolated static func firstOccurrences(of ids: [Int64]) -> [Int64] {
        var seen = Set<Int64>()
        return ids.filter { seen.insert($0).inserted }
    }
}

// MARK: - Generation

private extension AssistantViewModel {
    /// One mix, or `nil` with ``lastError`` set. Shared by every method above so
    /// "generation failed" and "nothing matched" are reported identically no matter
    /// which menu item asked.
    func generatedMix(
        source: MixCandidateSource,
        profileId: Int64,
        targetCount: Int,
        constraints: MixConstraints = MixConstraints(),
        seedText: String
    ) async -> PlaylistDraft? {
        let draft: PlaylistDraft
        do {
            draft = try await repositories.mixGenerator.generate(
                MixSpec(
                    profileId: profileId,
                    source: source,
                    targetCount: targetCount,
                    constraints: constraints,
                    seed: Self.contextualSeed(for: "\(seedText)|\(profileId)|\(source.kind.rawValue)")
                )
            )
        } catch {
            setLastError(.generationFailed(reason: String(describing: error)))
            return nil
        }
        guard !draft.isEmpty else {
            setLastError(.noMatchingTracks)
            return nil
        }
        return draft
    }

    /// The title/artist fold and runtime a duplicate test compares, or `nil` when
    /// the row carries too little to compare safely.
    nonisolated static func recordingSignature(of track: TrackRecord) -> (key: String, duration: TimeInterval)? {
        guard let titleKey = SortKey.sortKeyOrNil(track.title),
              let duration = track.duration, duration > 0
        else { return nil }
        let artistKey = SortKey.sortKeyOrNil(track.artistName) ?? ""
        return (key: "\(titleKey)\u{1F}\(artistKey)", duration: duration)
    }

    /// FNV-1a 64 — the same derivation `submit` and `GeneratedPlaylistService` use,
    /// restated rather than shared because the assistant's own copy is fileprivate
    /// to its declaring file. Equal text reproduces an equal mix.
    nonisolated static func contextualSeed(for text: String) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }
}
