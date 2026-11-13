// KaraokeRenderService — on-demand background pre-separation of requested tracks.
//
// Invariants (see `.opencode/skills/macamp/SKILL.md`): concurrency exactly 1 through
// one serial driver; deduplicated FIFO requests; strictly increasing progress; cache,
// presence, and support preflight; disk-full requeue/stop/notice; cancellation on disable.
import Foundation
import Separation

/// Production ``KaraokeRendering`` for serial, cancellable, cache-aware FIFO separation of requested tracks.
@MainActor
public final class KaraokeRenderService: KaraokeRendering {
    public var onProgress: (@Sendable (KaraokePrewarmProgress) -> Void)?

    /// Fires on the main actor after each render request finishes with its distinct
    /// rendered, already-cached, or failed outcome. Not fired for a request cancelled
    /// via ``setEnabled(_:)`` / ``cancelAll()`` or requeued after disk-full.
    public var onFinished: (@Sendable (URL, KaraokeRenderResult) -> Void)?

    /// Fires a debounced non-fatal advisory (currently only
    /// ``KaraokePrewarmNotice/diskFull``). Not part of the ``KaraokeRendering``
    /// protocol — the composition root wires it to a user-facing banner.
    public var onNotice: (@Sendable (KaraokePrewarmNotice) -> Void)?

    public var onQueueChanged: (@Sendable (KaraokeQueueSnapshot) -> Void)?

    private let separator: any StemSeparating
    private let preflightChecker: KaraokeRenderPreflight
    private let clock = ContinuousClock()

    private var enabled = false
    private var stopped = false
    private var isPaused = false
    private var awaitingPreflight: [URL] = []
    private var pending: [URL] = []
    private var prepared: [URL: KaraokeRenderPreparedWork] = [:]
    private var lastFraction: [URL: Double] = [:]
    private var preflightURL: URL?
    private var inFlightURL: URL?
    private var preflightDriver: Task<Void, Never>?
    private var preflightWork: Task<KaraokeRenderPreflightOutcome, Never>?
    private var driver: Task<Void, Never>?
    private var inFlightWork: Task<KaraokeRenderResult, Error>?
    private var preemptTarget: URL?
    private var priorityPreflightTarget: URL?
    private var requeueInFlightOnCancel = false
    private var lastDiskFullNoticeAt: ContinuousClock.Instant?

    /// - Parameters:
    ///   - separator: The stem separator (production `SeparationPipeline`; a
    ///     `FakeStemSeparator` in tests). Only its ``StemSeparating`` surface is used.
    ///   - cache: The instrumental cache, consulted to skip already-warm tracks.
    ///   - modelSHA: The active model's source-package SHA — mixed into every
    ///     ``SeparationCacheKey`` so cache lookups match what the pipeline stored. The
    ///     composition root passes `SeparationModelSpec.modelSHA`.
    public init(
        separator: any StemSeparating,
        cache: any InstrumentalCaching,
        modelSHA: String
    ) {
        self.separator = separator
        preflightChecker = KaraokeRenderPreflight(cache: cache, modelSHA: modelSHA)
    }
}

// MARK: - Control surface (KaraokeRendering)

public extension KaraokeRenderService {
    func setEnabled(_ enabled: Bool) {
        guard enabled != self.enabled else { return }
        self.enabled = enabled
        if enabled {
            stopped = false
            startPreflightIfNeeded()
            startDriverIfNeeded()
        } else {
            cancelAndClear()
        }
    }

    func requestRender(_ url: URL) {
        guard enabled, !stopped else { return }
        guard !containsRequest(url) else { return }
        awaitingPreflight.append(url)
        startPreflightIfNeeded()
    }

    func cancelAll() {
        cancelAndClear()
    }

    func pause() {
        isPaused = true
        if inFlightURL != nil {
            requeueInFlightOnCancel = true
            inFlightWork?.cancel()
        }
        emitQueueChanged()
    }

    func resume() {
        isPaused = false
        stopped = false
        emitQueueChanged()
        startPreflightIfNeeded()
        startDriverIfNeeded()
    }

    func removePending(_ url: URL) {
        if let index = awaitingPreflight.firstIndex(of: url) {
            awaitingPreflight.remove(at: index)
            return
        }
        guard let index = pending.firstIndex(of: url) else { return }
        pending.remove(at: index)
        prepared[url] = nil
        emitQueueChanged()
    }

    func movePending(_ url: URL, to index: Int) {
        guard let from = pending.firstIndex(of: url) else { return }
        let target = min(max(index, 0), pending.count - 1)
        guard target != from else { return }
        pending.remove(at: from)
        pending.insert(url, at: target)
        emitQueueChanged()
    }

    func startNow(_ url: URL) {
        guard enabled, !stopped else { return }
        let wasPaused = isPaused
        isPaused = false
        if priorityPreflightTarget != url { priorityPreflightTarget = nil }
        if inFlightURL == url {
            if wasPaused {
                emitQueueChanged()
                startDriverIfNeeded()
            }
            return
        }
        pending.removeAll { $0 == url }
        if preflightURL == url {
            priorityPreflightTarget = url
            guard inFlightURL != nil else { return }
            setPreemptTarget(url)
            return
        }
        guard prepared[url] != nil else {
            awaitingPreflight.removeAll { $0 == url }
            awaitingPreflight.insert(url, at: 0)
            startPreflightIfNeeded()
            return
        }
        guard inFlightURL != nil else {
            pending.insert(url, at: 0)
            emitQueueChanged()
            startDriverIfNeeded()
            return
        }
        setPreemptTarget(url)
    }

    private func setPreemptTarget(_ url: URL) {
        if let previous = preemptTarget, previous != url, prepared[previous] != nil {
            pending.insert(previous, at: 0)
        }
        preemptTarget = url
        requeueInFlightOnCancel = true
        inFlightWork?.cancel()
    }

    /// Alias for ``pause()`` retained for the per-track stop control.
    func stopCurrent() {
        pause()
    }
}

// MARK: - Serial driver

private extension KaraokeRenderService {
    func containsRequest(_ url: URL) -> Bool {
        preflightURL == url || awaitingPreflight.contains(url) || inFlightURL == url
            || pending.contains(url) || prepared[url] != nil || preemptTarget == url
    }

    func startPreflightIfNeeded() {
        guard enabled, preflightDriver == nil, !awaitingPreflight.isEmpty else { return }
        preflightDriver = Task { [weak self] in
            await self?.drivePreflight()
        }
    }

    func drivePreflight() async {
        while enabled, !Task.isCancelled, !awaitingPreflight.isEmpty {
            let url = awaitingPreflight.removeFirst()
            preflightURL = url
            let outcome = await preflight(url)
            preflightURL = nil
            guard enabled, !Task.isCancelled else { break }
            let isPriority = priorityPreflightTarget == url
            if isPriority { priorityPreflightTarget = nil }
            switch outcome {
            case let .render(preparedRender):
                prepared[url] = preparedRender
                if isPriority {
                    pending.removeAll { $0 == url }
                    pending.insert(url, at: 0)
                } else {
                    pending.append(url)
                }
                emitQueueChanged()
                startDriverIfNeeded()
            case .alreadyCached:
                emitQueueChanged()
                onFinished?(url, .alreadyCached)
            case .failed:
                emitQueueChanged()
                onFinished?(url, .failed)
            case .cancelled:
                break
            }
            if isPriority { startDriverIfNeeded() }
        }
        preflightDriver = nil
        startPreflightIfNeeded()
    }

    func startDriverIfNeeded() {
        guard enabled, !stopped, !isPaused, priorityPreflightTarget == nil,
              driver == nil, !pending.isEmpty else { return }
        driver = Task { [weak self] in
            await self?.drive()
        }
    }

    func drive() async {
        guard await separator.availability.isAvailable else {
            driver = nil
            return
        }
        driveLoop: while enabled, !stopped, !isPaused, priorityPreflightTarget == nil,
                         !Task.isCancelled, let url = dequeueNext()
        {
            inFlightURL = url
            // Keep progress bounded to the sole in-flight track.
            lastFraction.removeAll(keepingCapacity: true)
            emitQueueChanged()
            let outcome = await render(url)
            inFlightURL = nil
            guard finish(outcome, url: url) else { break driveLoop }
        }
        driver = nil
        startDriverIfNeeded()
    }

    func dequeueNext() -> URL? {
        pending.isEmpty ? nil : pending.removeFirst()
    }

    func cancelAndClear() {
        awaitingPreflight.removeAll()
        pending.removeAll()
        prepared.removeAll()
        lastFraction.removeAll()
        preflightURL = nil
        inFlightURL = nil
        preemptTarget = nil
        priorityPreflightTarget = nil
        requeueInFlightOnCancel = false
        preflightDriver?.cancel()
        preflightWork?.cancel()
        driver?.cancel()
        inFlightWork?.cancel()
        emitQueueChanged()
    }

    /// Applies a render outcome, requeuing preempted/paused work and promoting a
    /// ``startNow(_:)`` target that raced the render's completion.
    func finish(_ outcome: RenderOutcome, url: URL) -> Bool {
        switch outcome {
        case .succeeded:
            prepared[url] = nil
            lastDiskFullNoticeAt = nil
            promotePreemptTargetIfNeeded()
            emitQueueChanged()
            onFinished?(url, .rendered)
        case .failed:
            prepared[url] = nil
            promotePreemptTargetIfNeeded()
            emitQueueChanged()
            onFinished?(url, .failed)
        case .cancelled:
            return handleCancelled(url: url)
        case .diskFull:
            pending.insert(url, at: 0)
            stopped = true
            emitQueueChanged()
            emitDiskFullNoticeIfNeeded()
        }
        return true
    }

    /// Requeues a preempted/paused render at the front; a prepared start-now target
    /// jumps ahead, while an active-priority preflight temporarily holds the driver.
    func handleCancelled(url: URL) -> Bool {
        guard requeueInFlightOnCancel else { return false }
        requeueInFlightOnCancel = false
        pending.insert(url, at: 0)
        if let target = preemptTarget {
            preemptTarget = nil
            guard prepared[target] != nil else {
                emitQueueChanged()
                return priorityPreflightTarget == nil
            }
            pending.removeAll { $0 == target }
            pending.insert(target, at: 0)
            return true
        }
        emitQueueChanged()
        return true
    }

    func emitDiskFullNoticeIfNeeded() {
        let now = clock.now
        if let lastDiskFullNoticeAt,
           lastDiskFullNoticeAt.duration(to: now) < .seconds(30)
        {
            return
        }
        lastDiskFullNoticeAt = now
        onNotice?(.diskFull)
    }

    /// Promotes a prepared start-now target when cancellation loses to completion.
    func promotePreemptTargetIfNeeded() {
        guard let target = preemptTarget else { return }
        preemptTarget = nil
        requeueInFlightOnCancel = false
        guard prepared[target] != nil else { return }
        pending.removeAll { $0 == target }
        pending.insert(target, at: 0)
    }

    func emitQueueChanged() {
        onQueueChanged?(KaraokeQueueSnapshot(
            currentURL: inFlightURL,
            pendingURLs: pending,
            isPaused: isPaused
        ))
    }
}

// MARK: - Per-track separation (off-main)

private extension KaraokeRenderService {
    enum RenderOutcome { case succeeded, failed, cancelled, diskFull }

    func preflight(_ url: URL) async -> KaraokeRenderPreflightOutcome {
        let work = preflightChecker.makeWork(for: url)
        preflightWork = work
        defer { preflightWork = nil }
        return await work.value
    }

    func render(_ url: URL) async -> RenderOutcome {
        guard let preparedRender = prepared[url] else { return .failed }
        let work = makeWork(for: preparedRender)
        inFlightWork = work
        defer { inFlightWork = nil }
        do {
            _ = try await work.value
            return .succeeded
        } catch is CancellationError {
            return .cancelled
        } catch SeparationError.diskFull {
            return .diskFull
        } catch {
            return .failed
        }
    }

    func makeWork(for preparedRender: KaraokeRenderPreparedWork) -> Task<KaraokeRenderResult, Error> {
        let separator = separator
        let url = preparedRender.url
        let progress: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor in self?.publishProgress(url: url, fraction: fraction) }
        }
        return Task.detached(priority: .utility) {
            try Task.checkCancellation()
            _ = try await separator.separate(url: url, progress: progress)
            return .rendered
        }
    }

    func publishProgress(url: URL, fraction: Double) {
        let previous = lastFraction[url] ?? -1
        guard fraction > previous else { return }
        lastFraction[url] = fraction
        onProgress?(KaraokePrewarmProgress(url: url, fraction: fraction))
    }
}
