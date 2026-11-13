// EnrichmentViewModel — the observable projection of ``EnrichmentService``.
//
// ``EnrichmentService`` owns the background enrichment pass but is deliberately
// NOT `@Observable` (it is a plain `@MainActor` engine, like ``ReplayGainService``).
// This view model is the `@Observable` surface the UI binds to: it mirrors the
// service's state through the service's ``EnrichmentService/onChange`` callback
// and forwards the start/pause/resume/stop controls.
//
// It also owns the library's real enrichment COVERAGE, read through an optional
// injected ``EnrichmentCoverageReading``. That read is a database aggregate, so it
// runs OFF the main actor (`Task.detached`, the ``FolderSidebarViewModel`` precedent)
// and only its result is published — a view reads the published counts, never the
// database. The seam defaults to `nil` (dormant), so a shell that has not wired a
// reader pays for nothing.
//
// This file imports only Foundation + Observation + Lyrics + Persistence + Services;
// it MUST NOT import AppKit or UIKit (PlayerCore portability invariant).
import Foundation
import Lyrics
import Observation
import Persistence
import Services

/// Drives the enrichment progress UI over an injected ``EnrichmentService``.
@MainActor
@Observable
public final class EnrichmentViewModel {
    /// `true` while a pass is running.
    public private(set) var isRunning = false
    /// `true` while a running pass is suspended.
    public private(set) var isPaused = false
    /// Completion in `0...1` (0 when nothing to process).
    public private(set) var progressFraction: Double = 0
    /// "completed / total" counter for display.
    public private(set) var progressText: String = ""
    /// Title/filename of the track currently being processed, if any.
    public private(set) var currentTrack: String?

    /// The library's measured enrichment coverage, or `nil` until a read lands —
    /// and forever when no reader was injected. Published from the main actor by
    /// ``refreshCoverage()``; a view reads this, never the database.
    public private(set) var coverage: EnrichmentCoverageCounts?

    @ObservationIgnored private let service: EnrichmentService
    @ObservationIgnored private let reader: (any EnrichmentCoverageReading)?
    @ObservationIgnored private let activeProfileId: @MainActor () -> Int64

    /// Wires this projection to `service`, mirroring its state on every change.
    ///
    /// - Parameters:
    ///   - reader: the bounded coverage aggregate. `nil` (the default) leaves
    ///     ``coverage`` permanently `nil` and makes ``refreshCoverage()`` a no-op.
    ///   - activeProfileId: read at refresh time rather than captured once, so a
    ///     profile switch needs no extra re-scoping wiring.
    public init(
        service: EnrichmentService,
        reader: (any EnrichmentCoverageReading)? = nil,
        activeProfileId: @escaping @MainActor () -> Int64 = { ProfileRecord.guestID }
    ) {
        self.service = service
        self.reader = reader
        self.activeProfileId = activeProfileId
        service.onChange = { [weak self] in self?.sync() }
        sync()
    }

    /// Re-reads the profile-scoped coverage aggregate OFF the main actor and
    /// publishes it.
    ///
    /// A no-op without a reader; a failed read leaves the previous counts in place
    /// rather than blanking the surface back to its "nothing measured" fallback.
    public func refreshCoverage() async {
        guard let reader else { return }
        let profileId = activeProfileId()
        let counts = await Task.detached {
            try? reader.counts(profileId: profileId)
        }.value
        guard let counts else { return }
        coverage = counts
    }

    /// Which idle summary the settings surface should render, given how many tracks
    /// the last pass completed.
    ///
    /// Pure and cheap — a view may call it from `body`. Precedence is deliberate: a
    /// pass that just finished keeps reporting its own tally, and only a library that
    /// has enriched nothing falls through to the measured coverage. ``upToDate`` is
    /// reached ONLY when nothing has been measured at all, so a library with zero
    /// enriched tracks can never claim to be up to date.
    public func idleSummary(completed: Int) -> IdleSummary {
        if completed > 0 { return .enriched(count: completed) }
        guard let coverage else { return .upToDate }
        return .coverage(coverage)
    }

    /// Starts a background enrichment pass.
    public func start() {
        service.start()
    }

    /// Suspends the running pass.
    public func pause() {
        service.pause()
    }

    /// Resumes a suspended pass.
    public func resume() {
        service.resume()
    }

    /// Cancels the pass (already-enriched rows stay committed).
    public func stop() {
        service.stop()
    }
}

public extension EnrichmentViewModel {
    /// The three mutually-exclusive things the idle enrichment status can say.
    ///
    /// A closed enum rather than pre-resolved copy so the decision stays in
    /// PlayerCore (and unit-testable) while each shell owns its own catalog keys.
    enum IdleSummary: Equatable, Sendable {
        /// A pass enriched `count` tracks — the last-pass tally.
        case enriched(count: Int)
        /// Nothing was enriched, but the library's real coverage is known.
        case coverage(EnrichmentCoverageCounts)
        /// Nothing has been measured: no pass has run and no coverage read landed.
        case upToDate
    }
}

private extension EnrichmentViewModel {
    func sync() {
        let wasRunning = isRunning
        isRunning = service.isRunning
        isPaused = service.isPaused
        currentTrack = service.currentTrack
        let (completed, total) = service.progress
        progressFraction = total > 0 ? Double(completed) / Double(total) : 0
        progressText = "\(completed) / \(total)"
        guard wasRunning, !isRunning else { return }
        Task { [weak self] in await self?.refreshCoverage() }
    }
}
