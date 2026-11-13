// QueueViewModel — the play-queue editor over a ``PlaybackCoordinating``.
//
// Every edit (add / insert / remove / move / shuffle / repeat) forwards to the
// coordinator — the single source of truth for the ordered queue, stable shuffle
// order and history — then `refresh()` re-reads the snapshot into `@Observable`
// properties. It deliberately does NOT use the coordinator's single
// `stateDidChange` callback (``PlayerViewModel`` owns that slot), so the two view
// models never fight over the one callback. The app calls `refresh()` after any
// transport change it drives elsewhere.
//
// This file imports only Foundation + Observation + Services; it MUST NOT import
// AppKit or UIKit (PlayerCore portability invariant).
import Foundation
import Observation
import Services

/// Presents + edits the play queue, history, shuffle and repeat policy.
@MainActor
@Observable
public final class QueueViewModel {
    /// The user-ordered (context) queue.
    public private(set) var entries: [TrackRef] = []
    /// The user's manually-enqueued tracks (what the Queue panel shows).
    public private(set) var manualEntries: [TrackRef] = []
    /// Tracks already played earlier in the current cycle.
    public private(set) var history: [TrackRef] = []
    /// The current (or last-selected) track.
    public private(set) var current: TrackRef?
    /// Whether shuffle is engaged.
    public private(set) var shuffle = false
    /// The repeat policy.
    public private(set) var repeatMode: RepeatMode = .off

    @ObservationIgnored private let coordinator: any PlaybackCoordinating

    /// Creates a queue view model bound to `coordinator`.
    public init(coordinator: any PlaybackCoordinating) {
        self.coordinator = coordinator
        refresh()
    }

    /// Re-reads the queue snapshot from the coordinator (the source of truth).
    public func refresh() {
        entries = coordinator.queue
        manualEntries = coordinator.manualQueue
        history = coordinator.history
        current = coordinator.current
        shuffle = coordinator.shuffle
        repeatMode = coordinator.repeatMode
    }
}

// MARK: - Manual queue editing

public extension QueueViewModel {
    func enqueueManual(_ track: TrackRef) {
        coordinator.enqueueManual(track)
        refresh()
    }

    func enqueueManual(contentsOf tracks: [TrackRef]) {
        coordinator.enqueueManual(contentsOf: tracks)
        refresh()
    }

    func playNextManual(contentsOf tracks: [TrackRef]) {
        coordinator.playNextManual(contentsOf: tracks)
        refresh()
    }

    func removeManual(at index: Int) {
        coordinator.removeManual(at: index)
        refresh()
    }

    func moveManual(from source: Int, to destination: Int) {
        coordinator.moveManual(from: source, to: destination)
        refresh()
    }

    func playManual(at index: Int) {
        coordinator.playManual(at: index)
        refresh()
    }

    func clearManual() {
        coordinator.clearManualQueue()
        refresh()
    }
}

// MARK: - Editing

public extension QueueViewModel {
    func setQueue(_ tracks: [TrackRef], startingAt index: Int? = nil) {
        coordinator.setQueue(tracks, startingAt: index)
        refresh()
    }

    func append(_ track: TrackRef) {
        coordinator.append(track)
        refresh()
    }

    func append(contentsOf tracks: [TrackRef]) {
        coordinator.append(contentsOf: tracks)
        refresh()
    }

    func insert(_ track: TrackRef, at index: Int) {
        coordinator.insert(track, at: index)
        refresh()
    }

    func remove(at index: Int) {
        coordinator.remove(at: index)
        refresh()
    }

    func move(from source: Int, to destination: Int) {
        coordinator.move(from: source, to: destination)
        refresh()
    }

    func removeAll() {
        coordinator.removeAll()
        refresh()
    }

    /// Removes every track after the current one, leaving the current track
    /// playing. With nothing playing, clears the whole queue (and stops).
    func clearUpcoming() {
        let entries = coordinator.queue
        guard let current = coordinator.current,
              let currentIndex = entries.firstIndex(where: { $0.id == current.id })
        else {
            coordinator.removeAll()
            refresh()
            return
        }
        var index = entries.count - 1
        while index > currentIndex {
            coordinator.remove(at: index)
            index -= 1
        }
        refresh()
    }

    func play(at index: Int) {
        coordinator.play(at: index)
        refresh()
    }

    func setShuffle(_ enabled: Bool) {
        coordinator.shuffle = enabled
        refresh()
    }

    func setRepeatMode(_ mode: RepeatMode) {
        coordinator.repeatMode = mode
        refresh()
    }
}
