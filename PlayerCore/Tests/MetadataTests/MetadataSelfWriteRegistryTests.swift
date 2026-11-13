import Foundation
import Metadata
import Testing

@Suite("MetadataSelfWriteRegistryTests")
struct MetadataSelfWriteRegistryTests {
    private let fileURL = URL(fileURLWithPath: "/music/song.flac")
    private let otherURL = URL(fileURLWithPath: "/music/other.flac")

    @Test("a marked path reads back as a self-write")
    func markThenIsSelfWrite() {
        let registry = MetadataSelfWriteRegistry()
        #expect(!registry.isSelfWrite(fileURL))
        registry.markSelfWrite(fileURL)
        #expect(registry.isSelfWrite(fileURL))
    }

    @Test("an unmarked path is never a self-write")
    func unknownPathIsNotSelfWrite() {
        let registry = MetadataSelfWriteRegistry()
        registry.markSelfWrite(fileURL)
        #expect(!registry.isSelfWrite(otherURL))
    }

    @Test("a self-write marker expires once the grace window elapses")
    func markerExpiresAfterGrace() {
        final class Clock: @unchecked Sendable { var value: TimeInterval = 1000 }
        let clock = Clock()
        let registry = MetadataSelfWriteRegistry(graceInterval: 5, now: { clock.value })
        registry.markSelfWrite(fileURL)
        #expect(registry.isSelfWrite(fileURL))

        clock.value += 4.9
        #expect(registry.isSelfWrite(fileURL), "marker expired before its grace window")

        clock.value += 0.2 // now 5.1s after the mark — past the 5s window
        #expect(!registry.isSelfWrite(fileURL), "marker outlived its grace window")
    }

    @Test("consumeSelfWrite is one-shot: true once, then false")
    func consumeIsOneShot() {
        let registry = MetadataSelfWriteRegistry()
        registry.markSelfWrite(fileURL)
        #expect(registry.consumeSelfWrite(fileURL))
        #expect(!registry.consumeSelfWrite(fileURL))
        #expect(!registry.isSelfWrite(fileURL))
    }

    @Test("paths are matched after symlink + standardisation normalisation")
    func normalisesPaths() {
        let registry = MetadataSelfWriteRegistry()
        // Trailing-slash + dot segments must resolve to the same key.
        let marked = URL(fileURLWithPath: "/music/./song.flac")
        let queried = URL(fileURLWithPath: "/music/song.flac")
        registry.markSelfWrite(marked)
        #expect(registry.isSelfWrite(queried))
    }
}
