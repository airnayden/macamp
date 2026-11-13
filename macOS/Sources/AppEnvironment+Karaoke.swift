// AppEnvironment+Karaoke — karaoke (stem-separation) composition wiring.
//
// Split out of `AppEnvironment.swift` to keep that composition-root file under the
// SwiftLint `file_length` budget. Everything the karaoke feature needs to come
// alive is assembled here: the leaf services (`CoreMLSeparator` → `InstrumentalCache`
// → `SeparationPipeline` → `KaraokeRenderService`) and the runtime handoffs into the
// shared `AppSettings` gate (Task 15), the `PlaybackCoordinator` (Task 12) and the
// `PlayerViewModel` button seams (Task 14).
//
// Model-less by default: the stem-separation model is git-ignored and converted on
// demand, so on a CI or fresh-clone build `resolveModelSpec()` returns nil and
// `makeKaraokeStack()` yields an inert stack — the whole feature resolves
// `.unavailable` and the button stays disabled, never crashing. A released build
// always carries it (`scripts/release.sh` stage [7] refuses to ship without it).
import AudioEngine
import Decoding
import Foundation
import Models
import Observation
import os
import Persistence
import Separation
import Services
import ViewModels

extension AppEnvironment {
    /// The karaoke (stem-separation) leaf services, or an inert stack when no model
    /// is bundled. Threaded through ``Dependencies`` so all three factories build it.
    struct KaraokeStack {
        /// The production stem separator (`SeparationPipeline`), or `nil` when inert.
        var separator: (any StemSeparating)?
        /// The instrumental cache shared by the coordinator + settings pane, or `nil`.
        var cache: (any InstrumentalCaching)?
        /// The active model's source-package SHA — the SAME value keys the coordinator,
        /// the pre-warm service and the pipeline cache so their lookups match.
        var modelSHA: String
        /// The synchronous capability proxy handed to the coordinator at construction:
        /// `true` iff a model spec resolved AND the cache built. (The coordinator's own
        /// `karaokeSeparatorAvailable` flag is module-internal and cannot be set from the
        /// shell post-construction; the player's button uses the TRUE async availability.)
        var separatorAvailable: Bool

        /// The model-less stack: karaoke stays inert (button `.disabled`).
        static let inert = KaraokeStack(separator: nil, cache: nil, modelSHA: "", separatorAvailable: false)
    }

    /// Builds the production karaoke stack rooted at `cacheDirectory`, or an inert
    /// stack.
    ///
    /// Construction never throws out: a nil manifest spec (the common model-less case),
    /// a nil `cacheDirectory`, or an `InstrumentalCache` init failure all collapse onto
    /// ``KaraokeStack/inert`` so karaoke simply resolves unavailable.
    ///
    /// - Parameters:
    ///   - cacheDirectory: where instrumentals are cached (the user's chosen directory
    ///     or `InstrumentalCacheLocation.defaultDirectory()`, resolved on the main actor).
    ///   - qualityBox: the render-quality lock box the pipeline reads off-main at encode
    ///     time — so `AppSettings` (`@MainActor`) is never touched from the render task.
    static func makeKaraokeStack(
        cacheDirectory: URL?,
        qualityBox: OSAllocatedUnfairLock<InstrumentalRenderQuality>
    ) -> KaraokeStack {
        guard
            let spec = SeparationPipeline.resolveModelSpec(),
            let directory = cacheDirectory,
            let cache = try? InstrumentalCache(directory: directory, modelSHA: spec.modelSHA)
        else {
            return .inert
        }
        let separator = CoreMLSeparator()
        let pipeline = SeparationPipeline(
            decoderProvider: SFBDecoderProvider(),
            separator: separator,
            cache: cache,
            spec: spec,
            qualityProvider: { qualityBox.withLock { $0 } }
        )
        return KaraokeStack(separator: pipeline, cache: cache, modelSHA: spec.modelSHA, separatorAvailable: true)
    }

    /// The on-demand background render service, or `nil` when the stack is inert.
    static func makeKaraokeRender(_ stack: KaraokeStack) -> KaraokeRenderService? {
        guard let separator = stack.separator, let cache = stack.cache else { return nil }
        return KaraokeRenderService(separator: separator, cache: cache, modelSHA: stack.modelSHA)
    }

    /// Builds the playback coordinator wired with the karaoke source-resolution params
    /// (the SAME instrumental cache + model SHA the pipeline and pre-warm service use).
    static func makeCoordinator(_ dependencies: Dependencies) -> PlaybackCoordinator {
        PlaybackCoordinator(
            engine: dependencies.engine,
            randomNumberGenerator: dependencies.randomNumberGenerator,
            instrumentalCache: dependencies.karaoke.cache,
            karaokeModelSHA: dependencies.karaoke.modelSHA,
            karaokeSeparatorAvailable: dependencies.karaoke.separatorAvailable
        )
    }

    /// Connects the karaoke services to the shared `AppSettings` gate, the player, the
    /// coordinator and the ready store. Safe to call with an inert (model-less) stack:
    /// every closure degrades to a no-op and the button resolves `.disabled(.modelNotBundled)`.
    ///
    /// - Parameters:
    ///   - cacheDirectoryBox: the CURRENT cache directory — written on the main actor here
    ///     and by ``applyKaraokeCacheDirectoryChange(_:cache:settings:cacheDirectoryBox:)``,
    ///     read OFF-main by the scanner exclusion provider + the folder-access guard.
    ///   - qualityBox: the render-quality lock box the pipeline reads off-main at encode time.
    func connectKaraoke(
        stack: KaraokeStack,
        settings: AppSettings,
        cacheDirectoryBox: OSAllocatedUnfairLock<URL?>,
        qualityBox: OSAllocatedUnfairLock<InstrumentalRenderQuality>
    ) {
        wireKaraokeAvailability(stack)
        wireKaraokeSettings(
            stack: stack, settings: settings,
            cacheDirectoryBox: cacheDirectoryBox, qualityBox: qualityBox
        )
        wireKaraokeRuntimeCallbacks(stack)
        wireKaraokeQueue()
        observeKaraokeReadiness()
        startKaraokeCacheObservation(stack: stack, settings: settings)
    }

    /// Mirrors the render service's queue into ``karaokeQueueStore`` (main-hop, since
    /// `onQueueChanged` is `@Sendable`) and drives the queue's two toasts: an
    /// "added to karaoke queue" toast when a new track enters the queue, and the
    /// "all versions finished" toast when the queue drains after ≥1 success.
    private func wireKaraokeQueue() {
        karaokeRender?.onQueueChanged = { [weak self] snapshot in
            Task { @MainActor [weak self] in
                self?.ingestKaraokeQueue(snapshot)
            }
        }
    }

    /// Ingests a queue snapshot and fires at most one toast: the enqueue toast when a
    /// new canonical path appears, else the completion toast on a non-empty→empty drain
    /// that produced ≥1 successful render. Detecting the enqueue centrally here covers
    /// every source (row icon, context menu, player-bar mic) in one place and skips
    /// dedup no-ops (an already-queued request changes no membership, so `after ==
    /// before`), without touching the per-view render helpers or the player wiring.
    private func ingestKaraokeQueue(_ snapshot: KaraokeQueueSnapshot) {
        let before = queuedKaraokePaths()
        karaokeQueueStore.ingest(snapshot: snapshot)
        let after = queuedKaraokePaths()

        if !after.subtracting(before).isEmpty {
            toast.show(
                text: String(localized: MacAMPStrings.karaokeEnqueuedToast),
                icon: "text.badge.plus"
            )
            return
        }

        guard !before.isEmpty, after.isEmpty else { return }
        if karaokeQueueHadSuccessfulRender {
            toast.show(
                text: String(localized: MacAMPStrings.karaokeQueueFinishedToast),
                icon: "checkmark.circle.fill"
            )
        }
        karaokeQueueHadSuccessfulRender = false
    }

    /// The render queue's current membership (in-flight + pending) as canonical source
    /// paths, read from ``karaokeQueueStore`` so the before/after reads share the
    /// store's canonicalization and compare apples-to-apples.
    private func queuedKaraokePaths() -> Set<String> {
        var paths = Set(karaokeQueueStore.pendingPaths)
        if let current = karaokeQueueStore.currentPath { paths.insert(current) }
        return paths
    }

    private func showKaraokeFinishedToast(success: Bool) {
        toast.show(
            text: String(localized: success
                ? MacAMPStrings.karaokeVersionReadyToast
                : MacAMPStrings.karaokeVersionFailedToast),
            icon: success ? "music.mic" : "exclamationmark.triangle.fill"
        )
    }

    /// The finished track's display title IFF it is the current track — a cheap,
    /// no-database lookup used as the completion notification's body; `nil` (⇒ a
    /// generic body) when the finished render isn't the currently-playing track.
    private func karaokeTitle(forFinished url: URL) -> String? {
        guard let current = player.currentTrack else { return nil }
        let currentURL = URL(fileURLWithPath: current.filePath).resolvingSymlinksInPath().standardizedFileURL
        guard currentURL == url.resolvingSymlinksInPath().standardizedFileURL else { return nil }
        return current.title
    }

    /// Resolves the separator's TRUE availability off the launch path (a real model load
    /// must never block splash) and pushes it to the player's button state.
    private func wireKaraokeAvailability(_ stack: KaraokeStack) {
        guard let separator = stack.separator else {
            player.setKaraokeAvailability(.unavailable(reason: .modelNotBundled))
            return
        }
        Task { @MainActor [weak self] in
            let availability = await separator.availability
            self?.player.setKaraokeAvailability(availability)
        }
    }

    /// The `AppSettings` gate: enable toggle, cache-size/clear readouts, render quality,
    /// byte-cap limits and cache-directory relocation. Quality changes write the lock box
    /// (`AppSettings` is `@MainActor` and MUST NOT be read off-main); launch values were
    /// seeded into the boxes in `live()`, so only subsequent changes flow through here.
    private func wireKaraokeSettings(
        stack: KaraokeStack,
        settings: AppSettings,
        cacheDirectoryBox: OSAllocatedUnfairLock<URL?>,
        qualityBox: OSAllocatedUnfairLock<InstrumentalRenderQuality>
    ) {
        settings.onKaraokeEnabledChanged = { [weak self] enabled in
            self?.karaokeRender?.setEnabled(enabled)
            self?.player.setKaraokeSettingEnabled(enabled)
        }
        settings.karaokeCacheByteSize = { [cache = stack.cache] in await cache?.totalBytes ?? 0 }
        settings.clearKaraokeCache = { [cache = stack.cache] in try await cache?.clearAll() }
        settings.onKaraokeQualityChanged = { quality in qualityBox.withLock { $0 = quality } }
        settings.onKaraokeCacheLimitsChanged = { [cache = stack.cache] pruneEnabled, capBytes in
            guard let cache else { return }
            Task { await cache.setMaxByteSize(pruneEnabled ? capBytes : 0) }
        }
        settings.changeKaraokeCacheDirectory = { [weak self, weak settings, cache = stack.cache] requestedURL in
            guard let self, let settings else { return .failed }
            return await applyKaraokeCacheDirectoryChange(
                requestedURL, cache: cache, settings: settings, cacheDirectoryBox: cacheDirectoryBox
            )
        }
        player.setKaraokeSettingEnabled(settings.karaokeEnabled)
        karaokeRender?.setEnabled(settings.karaokeEnabled)
    }

    /// Render-service + coordinator callbacks (all fire on the main actor): per-track
    /// progress to the player ring and the row rings, completion re-syncing the ready
    /// store, disk-full + auto-deactivation toasts, and the on-demand render seam. The
    /// row-render entry point for Todo 12 is `karaokeRender?.requestRender(_:)`.
    private func wireKaraokeRuntimeCallbacks(_ stack: KaraokeStack) {
        karaokeRender?.onProgress = { [weak self] progress in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.player.ingestKaraokePrewarmProgress(progress)
                self.karaokeReadyStore.ingestProgress(url: progress.url, fraction: progress.fraction)
                self.karaokeQueueStore.ingestProgress(url: progress.url, fraction: progress.fraction)
            }
        }
        karaokeRender?.onFinished = { [weak self, cache = stack.cache] url, result in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch result {
                case .rendered:
                    self.karaokeReadyStore.finishRender(url: url, success: true)
                    self.showKaraokeFinishedToast(success: true)
                    self.karaokeQueueHadSuccessfulRender = true
                    self.karaokeNotifications.notifyRenderReady(trackTitle: self.karaokeTitle(forFinished: url))
                case .alreadyCached:
                    self.karaokeReadyStore.finishRender(url: url, success: true)
                    self.toast.show(
                        text: String(localized: MacAMPStrings.karaokeAlreadyAvailableToast),
                        icon: "checkmark.circle"
                    )
                case .failed:
                    self.karaokeReadyStore.finishRender(url: url, success: false)
                    self.showKaraokeFinishedToast(success: false)
                    return
                }
                guard let cache else { return }
                Task { @MainActor [weak self] in await self?.resyncKaraokeReadyStore(from: cache) }
            }
        }
        karaokeRender?.onNotice = { [weak self] notice in
            MainActor.assumeIsolated {
                self?.toast.show(text: String(localized: notice.message), icon: "exclamationmark.triangle.fill")
            }
        }
        player.onRenderRequested = { [weak self] track in
            self?.karaokeRender?.requestRender(track.url)
        }
        coordinator.onKaraokeAutoDeactivated = { [weak self] in
            self?.toast.show(
                text: String(localized: MacAMPStrings.karaokeAutoDeactivatedToast),
                icon: "microphone.slash.fill"
            )
        }
    }

    /// Re-feeds ``PlayerViewModel/setCurrentTrackKaraokeReady(_:)`` whenever the current
    /// track OR the ready set changes, re-arming the observation each time — the tracked
    /// reads always settle to the latest state even if intermediate changes coalesce.
    private func observeKaraokeReadiness() {
        withObservationTracking {
            _ = player.currentTrack?.filePath
            _ = karaokeReadyStore.version
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.feedCurrentTrackKaraokeReady()
                self.observeKaraokeReadiness()
            }
        }
    }

    private func feedCurrentTrackKaraokeReady() {
        let ready = player.currentTrack.map { karaokeReadyStore.isReady(filePath: $0.filePath) } ?? false
        player.setCurrentTrackKaraokeReady(ready)
    }

    /// Subscribes the ready store to the cache change-seam and seeds it: the seam handler
    /// stat-validates freshness OFF the main actor (never touching `AppSettings`) then hops
    /// back to ingest, the byte cap is applied once, and the initial snapshot is ingested.
    private func startKaraokeCacheObservation(stack: KaraokeStack, settings: AppSettings) {
        guard let cache = stack.cache else { return }
        let pruneEnabled = settings.karaokePruneEnabled
        let capBytes = settings.karaokeCacheCapBytes
        Task { @MainActor [weak self] in
            guard let self else { return }
            await cache.setOnEntriesChanged { [weak self] sequence, records in
                let fresh = records.filter(KaraokeReadyStore.isFreshOnDisk)
                Task { @MainActor in
                    self?.karaokeReadyStore.ingest(sequence: sequence, records: fresh, isFresh: { _ in true })
                }
            }
            await cache.setMaxByteSize(pruneEnabled ? capBytes : 0)
            await resyncKaraokeReadyStore(from: cache)
        }
    }

    /// Re-ingests the cache's atomic `(sequence, records)` snapshot after stat-validating
    /// freshness off-main — NEVER a records-only read, so the reorder guard stays honest.
    func resyncKaraokeReadyStore(from cache: any InstrumentalCaching) async {
        let snapshot = await cache.readySnapshot()
        let records = snapshot.records
        let fresh = await Task.detached { records.filter(KaraokeReadyStore.isFreshOnDisk) }.value
        karaokeReadyStore.ingest(sequence: snapshot.sequence, records: fresh, isFresh: { _ in true })
        feedCurrentTrackKaraokeReady()
    }

    /// Relocates the instrumental cache to `requestedURL` (nil ⇒ the default directory),
    /// rejecting any target overlapping ANY profile's roots (the cache is global, roots
    /// are per-profile, so an inactive profile's root must still be protected). A move
    /// persists the plain path + updates the box; a failed relocate keeps the old
    /// directory live and unpersisted.
    private func applyKaraokeCacheDirectoryChange(
        _ requestedURL: URL?,
        cache: (any InstrumentalCaching)?,
        settings: AppSettings,
        cacheDirectoryBox: OSAllocatedUnfairLock<URL?>
    ) async -> KaraokeCacheDirectoryChangeResult {
        guard let cache, let target = requestedURL ?? InstrumentalCacheLocation.defaultDirectory() else {
            return .failed
        }
        let roots = await allProfileLibraryRoots()
        if let overlap = CacheDirectoryOverlapPolicy.overlap(cacheDirectory: target, roots: roots) {
            return .rejected(reason: Self.karaokeCacheRejectionMessage(for: overlap))
        }
        let oldDirectory = cacheDirectoryBox.withLock { $0 }
        let oldExisted = oldDirectory.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        guard await (try? cache.relocate(to: target)) == true else { return .failed }
        settings.karaokeCacheDirectoryPath = requestedURL?.path
        cacheDirectoryBox.withLock { $0 = target }
        return oldExisted ? .moved : .freshStart
    }

    private static func karaokeCacheRejectionMessage(for overlap: CacheDirectoryOverlap) -> String {
        switch overlap {
        case .insideRoot:
            String(localized: MacAMPStrings.karaokeCacheInsideRoot)
        case .containsRoot:
            String(localized: MacAMPStrings.karaokeCacheContainsRoot)
        }
    }

    /// Every profile's library roots (Guest + all others), read off-main. The overlap
    /// check spans ALL profiles because the cache directory is global.
    private func allProfileLibraryRoots() async -> [URL] {
        let profileRepository = ProfileRepository(database)
        let rootRepository = LibraryRootRepository(database)
        return await Task.detached {
            let profiles = (try? profileRepository.allProfiles()) ?? []
            return profiles.compactMap(\.id).flatMap { profileId in
                ((try? rootRepository.rootsForProfile(profileId)) ?? []).map { URL(fileURLWithPath: $0.path) }
            }
        }.value
    }
}
