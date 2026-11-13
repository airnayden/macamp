import Darwin

/// A bounded metering ring buffer of `Float` with exclusive snapshot ownership.
///
/// The producer (`write`) makes one ownership attempt without waiting or heap
/// allocation. If a consumer owns the storage, the incoming block is dropped.
/// Non-real-time consumers wait for ownership before copying. A consumer can
/// either PEEK the most recent samples (`readLatest`, non-destructive) or
/// FIFO-consume (`read`). Capacity must be a power of two so index wrapping is a
/// cheap bitmask.
final class SPSCRingBuffer: @unchecked Sendable {
    private let storage: UnsafeMutableBufferPointer<Float>
    private let capacity: Int
    private let mask: Int
    private let access = AtomicAccessGate()
    private let writeIndex = AtomicCounter()
    private let readIndex = AtomicCounter()
    private var producerCursor: Int = 0

    init(capacity: Int) {
        precondition(
            capacity > 0 && (capacity & (capacity - 1)) == 0,
            "capacity must be a positive power of two"
        )
        self.capacity = capacity
        mask = capacity - 1
        let base = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        base.initialize(repeating: 0, count: capacity)
        storage = UnsafeMutableBufferPointer(start: base, count: capacity)
    }

    deinit {
        storage.baseAddress?.deinitialize(count: capacity)
        storage.deallocate()
    }

    // MARK: Producer

    /// Producer path. Copies `count` samples into the ring with wraparound.
    /// Zero heap allocation or waiting. Drops this block if a consumer owns the
    /// storage; only accepted samples advance `writeCount`. `count` must not
    /// exceed `capacity`.
    func write(_ ptr: UnsafePointer<Float>, count: Int) {
        precondition(count <= capacity, "write count exceeds capacity")
        guard let base = storage.baseAddress, count > 0 else { return }
        guard access.tryAcquire() else { return }
        defer { access.release() }
        let start = producerCursor & mask
        let firstChunk = min(count, capacity - start)
        memcpy(base + start, ptr, firstChunk * MemoryLayout<Float>.size)
        if count > firstChunk {
            memcpy(base, ptr + firstChunk, (count - firstChunk) * MemoryLayout<Float>.size)
        }
        producerCursor += count
        writeIndex.add(count)
    }

    // MARK: Consumer

    /// Non-destructive PEEK of the most recent `count` samples ending at the
    /// current write head. If fewer than `count` samples exist the front of
    /// `out` is zero-filled. Does not advance the read index. May wait for
    /// ownership; must not run on the audio thread.
    func readLatest(into out: UnsafeMutableBufferPointer<Float>, count: Int) {
        guard let dst = out.baseAddress, let base = storage.baseAddress, count > 0 else { return }
        access.acquire()
        defer { access.release() }
        let writeTotal = Int(writeIndex.load())
        let availableCount = min(count, min(writeTotal, capacity))
        let zeroFill = count - availableCount
        if zeroFill > 0 {
            memset(dst, 0, zeroFill * MemoryLayout<Float>.size)
        }
        guard availableCount > 0 else { return }
        let start = (writeTotal - availableCount) & mask
        let firstChunk = min(availableCount, capacity - start)
        memcpy(dst + zeroFill, base + start, firstChunk * MemoryLayout<Float>.size)
        if availableCount > firstChunk {
            memcpy(
                dst + zeroFill + firstChunk,
                base,
                (availableCount - firstChunk) * MemoryLayout<Float>.size
            )
        }
    }

    /// FIFO consume up to `count` samples. If the producer has lapped the
    /// consumer the read head fast-forwards to the oldest still-valid sample.
    /// Returns the number of samples actually read. May wait for ownership;
    /// must not run on the audio thread.
    @discardableResult
    func read(into out: UnsafeMutableBufferPointer<Float>, count: Int) -> Int {
        guard let dst = out.baseAddress, count > 0 else { return 0 }
        guard let base = storage.baseAddress else { return 0 }
        access.acquire()
        defer { access.release() }
        let writeTotal = Int(writeIndex.load())
        let oldRead = Int(readIndex.load())
        var readTotal = oldRead
        if writeTotal - readTotal > capacity {
            readTotal = writeTotal - capacity
        }
        let toRead = min(count, writeTotal - readTotal)
        guard toRead > 0 else {
            if readTotal > oldRead { readIndex.add(readTotal - oldRead) }
            return 0
        }
        let start = readTotal & mask
        let firstChunk = min(toRead, capacity - start)
        memcpy(dst, base + start, firstChunk * MemoryLayout<Float>.size)
        if toRead > firstChunk {
            memcpy(dst + firstChunk, base, (toRead - firstChunk) * MemoryLayout<Float>.size)
        }
        readIndex.add((readTotal + toRead) - oldRead)
        return toRead
    }

    // MARK: Introspection

    var writeCount: UInt64 {
        writeIndex.load()
    }

    var readCount: UInt64 {
        readIndex.load()
    }

    var available: Int {
        Int(writeIndex.load()) - Int(readIndex.load())
    }

    var capacityCount: Int {
        capacity
    }

    var storageBaseAddress: UnsafeMutableRawPointer? {
        UnsafeMutableRawPointer(storage.baseAddress)
    }
}
