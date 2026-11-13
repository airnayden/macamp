// PlaybackCoordinator manual-queue editing.
//
// Split out of `PlaybackCoordinator.swift` purely for the file-length budget —
// a straight move, no behaviour change. The manual queue is the user's explicit
// "play these next" list; it takes precedence over the context plan on forward
// advance (see ``PlaybackCoordinator+Orchestration.swift``) and is consumed
// front-first, so browsing a folder or playlist never pollutes it.
//
// This file imports only Foundation; it MUST NOT import AppKit or UIKit
// (PlayerCore portability invariant).
import Foundation

public extension PlaybackCoordinator {
    func enqueueManual(_ track: TrackRef) {
        manualQueueEntries.append(track)
        applyQueueEdit()
    }

    func enqueueManual(contentsOf tracks: [TrackRef]) {
        manualQueueEntries.append(contentsOf: tracks)
        applyQueueEdit()
    }

    func playNextManual(contentsOf tracks: [TrackRef]) {
        manualQueueEntries.insert(contentsOf: tracks, at: 0)
        applyQueueEdit()
    }

    func removeManual(at index: Int) {
        guard manualQueueEntries.indices.contains(index) else { return }
        manualQueueEntries.remove(at: index)
        applyQueueEdit()
    }

    func moveManual(from source: Int, to destination: Int) {
        guard manualQueueEntries.indices.contains(source) else { return }
        let clamped = min(max(destination, 0), manualQueueEntries.count - 1)
        let moved = manualQueueEntries.remove(at: source)
        manualQueueEntries.insert(moved, at: clamped)
        applyQueueEdit()
    }

    func playManual(at index: Int) {
        guard manualQueueEntries.indices.contains(index) else { return }
        let track = manualQueueEntries[index]
        manualQueueEntries.removeFirst(index + 1)
        activateManual(track, startPlaying: true)
    }

    func clearManualQueue() {
        manualQueueEntries.removeAll()
        applyQueueEdit()
    }
}
