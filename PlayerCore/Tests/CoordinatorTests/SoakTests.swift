// SoakTests — a stress pass that hammers the coordinator with a long stream of
// rapid, randomly-chosen transport/queue operations and asserts the core
// invariants hold after EVERY step: the play order stays a permutation of the
// queue, and `current` (when set) is always a real queue entry. No crash, no
// drift, no orphaned ids.
import AudioEngine
import Foundation
import Persistence
@testable import Services
import Testing

@MainActor
@Suite(.serialized)
struct SoakTests {
    @Test("1000 rapid play/pause/seek/next/prev ops keep state consistent")
    func soak() {
        let engine = FakePlaybackEngine()
        let coordinator = PlaybackCoordinator(
            engine: engine,
            randomNumberGenerator: SeededRandomNumberGenerator(seed: 99)
        )
        let tracks = (0 ..< 8).map { index in
            TrackRef.fixture("t\(index)", availability: index % 5 == 0 ? .missing : .present)
        }
        coordinator.setQueue(tracks, startingAt: 0)
        let validIDs = Set(tracks.map(\.id))

        var generator = SeededRandomNumberGenerator(seed: 12345)
        for _ in 0 ..< 1000 {
            let choice = Int(generator.next(upperBound: UInt(7)))
            switch choice {
            case 0:
                coordinator.play()
            case 1:
                coordinator.pause()
            case 2:
                coordinator.seek(to: Double(generator.next(upperBound: UInt(120))) / 10.0)
            case 3:
                coordinator.next()
            case 4:
                coordinator.previous()
            case 5:
                coordinator.togglePlayPause()
            default:
                coordinator.prescheduleNextIfNeeded()
            }
            #expect(Set(coordinator.order) == validIDs)
            #expect(coordinator.order.count == tracks.count)
            if let current = coordinator.current {
                #expect(validIDs.contains(current.id))
                #expect(current.isPlayable)
            }
        }
        #expect(coordinator.order.count == tracks.count)
    }

    @Test("soak with live queue edits never orphans the play order")
    func soakWithEdits() {
        let engine = FakePlaybackEngine()
        let coordinator = PlaybackCoordinator(
            engine: engine,
            randomNumberGenerator: SeededRandomNumberGenerator(seed: 5)
        )
        var pool = (0 ..< 6).map { TrackRef.fixture("p\($0)") }
        coordinator.setQueue(pool, startingAt: 0)
        coordinator.shuffle = true

        var generator = SeededRandomNumberGenerator(seed: 2024)
        for step in 0 ..< 500 {
            let choice = Int(generator.next(upperBound: UInt(6)))
            switch choice {
            case 0 where !coordinator.queue.isEmpty:
                coordinator.remove(at: Int(generator.next(upperBound: UInt(coordinator.queue.count))))
            case 1:
                let fresh = TrackRef.fixture("x\(step)")
                pool.append(fresh)
                coordinator.append(fresh)
            case 2:
                coordinator.next()
            case 3:
                coordinator.previous()
            default:
                coordinator.prescheduleNextIfNeeded()
            }
            let queueIDs = Set(coordinator.queue.map(\.id))
            #expect(Set(coordinator.order) == queueIDs)
            #expect(coordinator.order.count == coordinator.queue.count)
            if let current = coordinator.current {
                #expect(queueIDs.contains(current.id))
            }
        }
    }
}
