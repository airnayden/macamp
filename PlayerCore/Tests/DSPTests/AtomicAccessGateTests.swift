@testable import DSP
import Foundation
import Testing

struct AtomicAccessGateTests {
    @Test("Real-time acquisition returns immediately while ownership is held")
    func contentionDoesNotWait() {
        let gate = AtomicAccessGate()
        #expect(gate.tryAcquire())
        let started = ContinuousClock.now
        for _ in 0 ..< 10000 {
            #expect(!gate.tryAcquire())
        }
        #expect(started.duration(to: .now) < .seconds(1))
        gate.release()
        #expect(gate.tryAcquire())
        gate.release()
    }

    @Test("A waiting publisher acquires only after the current owner releases")
    func waitingOwnershipIsExclusive() {
        let gate = AtomicAccessGate()
        let started = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let acquired = AtomicCounter()
        gate.acquire()
        DispatchQueue.global().async {
            started.signal()
            gate.acquire()
            acquired.add(1)
            gate.release()
            finished.signal()
        }
        #expect(started.wait(timeout: .now() + 1) == .success)
        #expect(acquired.load() == 0)
        gate.release()
        #expect(finished.wait(timeout: .now() + 1) == .success)
        #expect(acquired.load() == 1)
    }
}
