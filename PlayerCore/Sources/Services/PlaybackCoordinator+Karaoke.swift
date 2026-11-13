// PlaybackCoordinator karaoke source resolution + gapless scheduling + restore.
//
// The load-bearing constraint: `InstrumentalCaching.cachedInstrumental(for:)` is
// `async` (the production cache is an actor), but the coordinator resolves a track's
// playback source SYNCHRONOUSLY on the hot path (activate / preschedule / restore).
// So this file keeps a pre-resolved `[TrackRecord.Identity: instrumentalURL]` map
// that is populated asynchronously whenever the karaoke set changes (toggle /
// advance), and the sync `playbackSource(for:)` seam only ever READS that map — it
// never awaits the cache.
//
// The map is keyed by the v20 row identity, NOT by `filePath`: a `.cue` sheet makes
// one audio file back N rows, so a path-keyed map would hand every segment of a disc
// image whichever entry was written last.
//
// CUE SEGMENTS ARE NEVER SEPARATED. `SeparationCacheKey` is derived from the audio
// FILE's identity, so all N segments of a disc image collide on one cache entry —
// the whole file's — and a rendered instrumental could not be attributed to the
// segment that asked for it. `resolveInstrumentals(for:)` therefore skips cue
// segments outright, which is what makes the shell's typed
// `SeparationUnavailableReason.cueSegment` button state the truth rather than a hint.
//
// Persistence stays honest: only the `karaokeActive` boolean is snapshotted; queue
// entries keep their ORIGINAL file paths so no instrumental cache path is ever
// written to disk.
//
// This file imports only AudioEngine + Foundation + Persistence + Separation; it
// MUST NOT import AppKit or UIKit (PlayerCore portability invariant).
import AudioEngine
import Foundation
import Persistence
import Separation

// MARK: - Gapless scheduling + restoration

public extension PlaybackCoordinator {
    /// Pre-buffers the successor so the switch is gapless.
    ///
    /// Two consecutive segments of ONE disc image are URL-equal and differ only in
    /// their frame range, which is exactly why this enqueues a ``DecoderSource``
    /// rather than a URL: the engine resolves each source to its own decoder OBJECT,
    /// so same-file gapless works with no special case. The double-enqueue guard is
    /// `TrackRef.id` (a fresh `UUID` per ref), so it separates two segments of one
    /// file where a path comparison could not.
    func prescheduleNextIfNeeded() {
        guard let track = nextTrackToSchedule(), track.id != lastScheduledNextID else { return }
        lastScheduledNextID = track.id
        try? engine.enqueue(source: playbackSource(for: track))
    }

    func handleTrackDidFinish() {
        emitOutgoingPlayEvent(reason: .natural)
        if let trackID = current?.trackID {
            onTrackPlayed?(trackID)
        }
        advance(.forward, automatic: true)
    }

    func snapshot() -> CoordinatorSnapshot {
        CoordinatorSnapshot(
            entries: plan.entries,
            order: plan.order,
            currentID: plan.currentID,
            shuffle: plan.shuffle,
            repeatMode: repeatModeValue,
            position: engine.currentTime,
            karaokeActive: karaokeActive
        )
    }

    func restore(from snapshot: CoordinatorSnapshot) {
        finishTerminalTeardown()
        currentTrackDuration = 0
        plan.restore(
            entries: snapshot.entries,
            order: snapshot.order,
            currentID: snapshot.currentID,
            shuffle: snapshot.shuffle
        )
        repeatModeValue = snapshot.repeatMode
        lastScheduledNextID = nil
        karaokeActive = snapshot.karaokeActive
        desiredKaraokeActive = snapshot.karaokeActive
        guard let currentID = plan.currentID, let track = plan.track(currentID) else {
            publish()
            return
        }
        guard karaokeActive, karaokeCapable else {
            karaokeActive = false
            desiredKaraokeActive = false
            loadRestored(track, position: snapshot.position)
            publish()
            return
        }
        karaokeRestoreTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            await resolveInstrumentals(for: karaokeResolutionTargets())
            if resolvedInstrumentals[track.identity] == nil {
                // Snapshot claimed active but the cache is empty/stale for the
                // restored track: correct state silently (no launch toast/seam).
                karaokeActive = false
                desiredKaraokeActive = false
                await clearResolvedInstrumentals()
            }
            loadRestored(track, position: snapshot.position)
            publish()
        }
    }
}

// MARK: - Karaoke source resolution

extension PlaybackCoordinator {
    /// What to hand the engine for `track`: the pre-resolved instrumental when
    /// karaoke is engaged, else the track's own file restricted to its cue-segment
    /// frame range. Synchronous by contract.
    ///
    /// An instrumental is a freshly rendered whole file, so it carries no frame
    /// range — and a cue segment never has one to begin with (see the file header).
    func playbackSource(for track: TrackRef) -> DecoderSource {
        if karaokeActive, let instrumental = resolvedInstrumentals[track.identity] {
            return DecoderSource(url: instrumental)
        }
        return DecoderSource(url: track.url, frameRange: track.segmentFrameRange)
    }

    var karaokeCapable: Bool {
        instrumentalCache != nil && karaokeSeparatorAvailable
    }

    /// Replaces the queue and optionally engages karaoke against that new queue
    /// as one cancellation-ordered operation.
    ///
    /// - Parameter source: The source identity to track for restoration, or `nil`
    ///   when the caller has no source to track. The value is published through
    ///   `playbackSourceDidChange` before the replacement queue publishes state.
    public func setQueue(
        _ refs: [TrackRef],
        startingAt index: Int,
        engagingKaraoke: Bool = false,
        source: PlaybackSource? = nil
    ) {
        playbackSourceDidChange?(source)
        guard engagingKaraoke else {
            replaceQueue(refs, startingAt: Optional(index), source: source)
            return
        }
        let pendingApply = karaokeDebounceTask
        pendingApply?.cancel()
        karaokeDebounceTask = nil
        desiredKaraokeActive = true
        replaceQueue(refs, startingAt: Optional(index), source: source)
        scheduleLeadingKaraokeApply(
            suppressAutoDeactivateCallback: true,
            waitingFor: pendingApply
        )
    }

    public func setKaraokeActive(_ active: Bool) {
        desiredKaraokeActive = active
        let hadPending = karaokeDebounceTask != nil
        karaokeDebounceTask?.cancel()
        if hadPending {
            scheduleTrailingKaraokeApply()
        } else {
            scheduleLeadingKaraokeApply()
        }
    }

    public func toggleKaraoke() {
        setKaraokeActive(!desiredKaraokeActive)
    }

    /// Recomputes the pre-resolved instrumental map + pins for the active karaoke set
    /// after an advance/queue edit. A no-op (no spawned task) while karaoke is off.
    func refreshKaraokeResolutionIfActive() {
        guard karaokeActive, karaokeCapable else { return }
        karaokeWarmTask?.cancel()
        karaokeWarmTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            await resolveInstrumentals(for: karaokeResolutionTargets())
            guard !Task.isCancelled, karaokeActive, let current, current.isPlayable else { return }
            if resolvedInstrumentals[current.identity] == nil {
                await autoDeactivateKaraoke()
            }
        }
    }

    func nextTrackToSchedule() -> TrackRef? {
        if repeatModeValue == .one {
            return current
        } else if let manual = manualQueueEntries.first(where: \.isPlayable) {
            return manual
        } else if let nextID = plan.nextPlayableID(
            from: plan.currentID, direction: .forward, repeatMode: repeatModeValue
        ) {
            return plan.track(nextID)
        }
        return nil
    }
}

// MARK: - Karaoke apply pipeline (private)

private extension PlaybackCoordinator {
    func scheduleLeadingKaraokeApply(
        suppressAutoDeactivateCallback: Bool = false,
        waitingFor pendingApply: Task<Void, Never>? = nil
    ) {
        karaokeDebounceTask = Task { @MainActor [weak self] in
            await pendingApply?.value
            guard let self, !Task.isCancelled else { return }
            await applyKaraoke(suppressAutoDeactivateCallback: suppressAutoDeactivateCallback)
            try? await Task.sleep(for: karaokeDebounceInterval)
            if !Task.isCancelled { karaokeDebounceTask = nil }
        }
    }

    func scheduleTrailingKaraokeApply() {
        karaokeDebounceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: karaokeDebounceInterval)
            guard !Task.isCancelled else { return }
            karaokeDebounceTask = nil
            await applyKaraoke()
        }
    }

    func applyKaraoke(suppressAutoDeactivateCallback: Bool = false) async {
        if desiredKaraokeActive {
            guard let current, current.isPlayable, karaokeCapable else {
                karaokeActive = false
                desiredKaraokeActive = false
                publish()
                return
            }
            await resolveInstrumentals(for: karaokeResolutionTargets())
            guard !Task.isCancelled else { return }
            guard resolvedInstrumentals[current.identity] != nil else {
                await autoDeactivateKaraoke(
                    suppressAutoDeactivateCallback: suppressAutoDeactivateCallback
                )
                return
            }
            karaokeActive = true
        } else {
            karaokeActive = false
        }
        reloadCurrentForKaraokeChange()
        if !karaokeActive { await clearResolvedInstrumentals() }
        lastScheduledNextID = nil
        prescheduleNextIfNeeded()
        publish()
    }

    func autoDeactivateKaraoke(suppressAutoDeactivateCallback: Bool = false) async {
        karaokeActive = false
        desiredKaraokeActive = false
        await clearResolvedInstrumentals()
        guard !Task.isCancelled else { return }
        reloadCurrentForKaraokeChange()
        lastScheduledNextID = nil
        prescheduleNextIfNeeded()
        publish()
        if !suppressAutoDeactivateCallback {
            onKaraokeAutoDeactivated?()
        }
    }

    func reloadCurrentForKaraokeChange() {
        guard let track = current, track.isPlayable else { return }
        let newSource = playbackSource(for: track)
        guard newSource != activePlaybackSource else { return }
        let wasPlaying = engine.state == .playing
        let position = engine.currentTime
        try? engine.reload(source: newSource, at: position, resumePlaying: wasPlaying)
        activePlaybackSource = newSource
    }

    func loadRestored(_ track: TrackRef, position: TimeInterval) {
        let source = playbackSource(for: track)
        try? engine.load(source: source)
        activePlaybackSource = source
        engine.seek(to: position)
        currentTrackDuration = engine.duration
    }

    func karaokeResolutionTargets() -> [TrackRef] {
        var targets: [TrackRef] = []
        if let current { targets.append(current) }
        if let successor = nextTrackToSchedule(), successor.id != current?.id {
            targets.append(successor)
        }
        return targets
    }

    func resolveInstrumentals(for tracks: [TrackRef]) async {
        guard let cache = instrumentalCache else { return }
        var resolved: [TrackRecord.Identity: URL] = [:]
        var pins: Set<SeparationCacheKey> = []
        for track in tracks where track.isPlayable && !track.isCueSegment {
            guard let key = try? SeparationCacheKey(url: track.url, modelSHA: karaokeModelSHA) else { continue }
            if let url = await cache.cachedInstrumental(for: key) {
                resolved[track.identity] = url
                pins.insert(key)
            }
        }
        for key in pins where !pinnedInstrumentalKeys.contains(key) {
            await cache.pin(key)
        }
        for key in pinnedInstrumentalKeys where !pins.contains(key) {
            await cache.unpin(key)
        }
        pinnedInstrumentalKeys = pins
        resolvedInstrumentals = resolved
    }

    func clearResolvedInstrumentals() async {
        if let cache = instrumentalCache {
            for key in pinnedInstrumentalKeys {
                await cache.unpin(key)
            }
        }
        pinnedInstrumentalKeys = []
        resolvedInstrumentals = [:]
    }
}
