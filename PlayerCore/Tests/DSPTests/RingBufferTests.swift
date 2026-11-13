import Darwin
@testable import DSP
import Foundation
import Testing

private func writeSamples(_ ring: SPSCRingBuffer, _ samples: [Float]) {
    guard !samples.isEmpty else { return }
    samples.withUnsafeBufferPointer { buffer in
        guard let base = buffer.baseAddress else { return }
        ring.write(base, count: samples.count)
    }
}

private func readSamples(_ ring: SPSCRingBuffer, count: Int) -> [Float] {
    var out = [Float](repeating: 0, count: count)
    let read = out.withUnsafeMutableBufferPointer { buffer in
        ring.read(into: buffer, count: count)
    }
    return Array(out.prefix(read))
}

private func peekLatest(_ ring: SPSCRingBuffer, count: Int) -> [Float] {
    var out = [Float](repeating: -999, count: count)
    out.withUnsafeMutableBufferPointer { buffer in
        ring.readLatest(into: buffer, count: count)
    }
    return out
}

private func mallocBlocksInUse() -> Int {
    var stats = malloc_statistics_t()
    malloc_zone_statistics(malloc_default_zone(), &stats)
    return Int(stats.blocks_in_use)
}

struct RingBufferTests {
    @Test func fifoRoundTrip() {
        let ring = SPSCRingBuffer(capacity: 1024)
        let count = 500
        let input = (0 ..< count).map { Float($0) }
        writeSamples(ring, input)
        let output = readSamples(ring, count: count)
        #expect(output == input)
    }

    @Test func wraparoundContinuity() {
        let ring = SPSCRingBuffer(capacity: 8)
        writeSamples(ring, (0 ..< 6).map { Float($0) })
        let first = readSamples(ring, count: 4)
        #expect(first == [0, 1, 2, 3])
        writeSamples(ring, (6 ..< 12).map { Float($0) })
        let second = readSamples(ring, count: 8)
        #expect(second == [4, 5, 6, 7, 8, 9, 10, 11])
    }

    @Test func overrunDropsOldest() {
        let ring = SPSCRingBuffer(capacity: 8)
        for chunk in stride(from: 0, to: 20, by: 4) {
            let end = min(chunk + 4, 20)
            writeSamples(ring, (chunk ..< end).map { Float($0) })
        }
        let output = readSamples(ring, count: 8)
        #expect(output == [12, 13, 14, 15, 16, 17, 18, 19])
    }

    @Test func underrunReturnsAvailable() {
        let ring = SPSCRingBuffer(capacity: 64)
        writeSamples(ring, (0 ..< 4).map { Float($0) })
        var out = [Float](repeating: -1, count: 8)
        let read = out.withUnsafeMutableBufferPointer { buffer in
            ring.read(into: buffer, count: 8)
        }
        #expect(read == 4)
        #expect(Array(out.prefix(4)) == [0, 1, 2, 3])
    }

    @Test func readLatestPeeksWithoutConsuming() {
        let ring = SPSCRingBuffer(capacity: 16384)
        writeSamples(ring, (0 ..< 100).map { Float($0) })
        let readBefore = ring.readCount
        let latest = peekLatest(ring, count: 10)
        #expect(latest == (90 ..< 100).map { Float($0) })
        #expect(ring.readCount == readBefore)
        #expect(ring.readCount == 0)
    }

    @Test func randomizedInterleavedMatchesReference() {
        let ring = SPSCRingBuffer(capacity: 65536)
        var reference: [Float] = []
        var nextValue: Float = 0
        var rng = SystemRandomNumberGenerator()
        for _ in 0 ..< 2000 {
            let writeCount = Int.random(in: 0 ... 32, using: &rng)
            if writeCount > 0, ring.available + writeCount <= ring.capacityCount {
                var batch = [Float](repeating: 0, count: writeCount)
                for index in 0 ..< writeCount {
                    batch[index] = nextValue
                    nextValue += 1
                }
                writeSamples(ring, batch)
                reference.append(contentsOf: batch)
            }
            let wantRead = Int.random(in: 0 ... 40, using: &rng)
            if wantRead > 0 {
                let got = readSamples(ring, count: wantRead)
                let expected = Array(reference.prefix(got.count))
                #expect(got == expected)
                reference.removeFirst(got.count)
            }
        }
    }

    @Test("Concurrent snapshots contain one complete published block", arguments: [false, true])
    func concurrentSnapshotsAreCoherent(fifo: Bool) {
        let capacity = 16384
        let ring = SPSCRingBuffer(capacity: capacity)
        let group = DispatchGroup()
        let start = DispatchSemaphore(value: 0)
        let torn = AtomicCounter()
        group.enter()
        DispatchQueue.global().async {
            var input = [Float](repeating: 0, count: capacity)
            start.wait()
            for generation in 1 ... 10000 {
                input.withUnsafeMutableBufferPointer { buffer in
                    buffer.update(repeating: Float(generation))
                    if let base = buffer.baseAddress { ring.write(base, count: capacity) }
                }
            }
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            var output = [Float](repeating: 0, count: capacity)
            start.signal()
            for _ in 0 ..< 2000 {
                output.withUnsafeMutableBufferPointer { buffer in
                    if fifo {
                        guard ring.read(into: buffer, count: capacity) > 0 else { return }
                    } else {
                        ring.readLatest(into: buffer, count: capacity)
                    }
                    if buffer.contains(where: { $0 != buffer[0] }) { torn.add(1) }
                }
            }
            group.leave()
        }
        #expect(group.wait(timeout: .now() + 30) == .success)
        #expect(torn.load() == 0, "A snapshot must not mix generations during overwrite")
        #expect(ring.writeCount > 0)
        #expect(ring.writeCount <= 10000 * UInt64(capacity))
        #expect(ring.writeCount.isMultiple(of: UInt64(capacity)))
    }

    @Test func writesKeepLiveHeapBoundedAndStorageStable() {
        let ring = SPSCRingBuffer(capacity: 16384)
        let baseBefore = ring.storageBaseAddress
        let iterations = 1_000_000
        let batch = [Float](repeating: 1, count: 64)

        let (ambient, writeDelta) = batch.withUnsafeBufferPointer { buffer -> (Int, Int) in
            guard let ptr = buffer.baseAddress else { return (0, iterations) }
            for _ in 0 ..< 1000 {
                ring.write(ptr, count: 64)
            }

            // The default malloc zone counter is process-global, so under
            // `--parallel` it also counts other tests' allocations. The control
            // window (no ring writes) measures that ambient noise to subtract it.
            var sink = 0
            let controlStart = mallocBlocksInUse()
            for index in 0 ..< iterations {
                sink = sink &+ (index & 1)
            }
            let ambientDelta = mallocBlocksInUse() - controlStart
            _ = sink

            let writeStart = mallocBlocksInUse()
            for _ in 0 ..< iterations {
                ring.write(ptr, count: 64)
            }
            return (ambientDelta, mallocBlocksInUse() - writeStart)
        }

        // This live-block heuristic detects retained allocations, not transient
        // malloc/free pairs. Stable backing storage is checked separately below.
        // The real-time no-allocation contract also requires source review; this
        // snapshot is not evidence that no allocation events occurred.
        #expect(writeDelta <= max(ambient, 0) + 4096)
        #expect(ring.storageBaseAddress == baseBefore)
    }
}
