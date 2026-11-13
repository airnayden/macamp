import Foundation
import Metadata
import PlayerCoreTestSupport
import Testing

@Suite("FakeMetadataWriterTests")
struct FakeMetadataWriterTests {
    private let fileURL = URL(fileURLWithPath: "/music/song.flac")

    @Test("a successful write is recorded with its metadata + url")
    func recordsCalls() throws {
        let writer = FakeMetadataWriter()
        try writer.writeMetadata(WritableMetadata(title: "A", genre: "Jazz"), to: fileURL)
        #expect(writer.calls.count == 1)
        let call = try #require(writer.calls.first)
        #expect(call.url == fileURL)
        #expect(call.metadata == WritableMetadata(title: "A", genre: "Jazz"))
    }

    @Test("a configured error is thrown and the call is NOT recorded")
    func throwsConfiguredError() {
        let writer = FakeMetadataWriter(errorToThrow: .permissionDenied(url: fileURL))
        let error = #expect(throws: MetadataWriteError.self) {
            try writer.writeMetadata(WritableMetadata(title: "A"), to: fileURL)
        }
        guard case .permissionDenied = error else {
            Issue.record("expected .permissionDenied, got \(String(describing: error))")
            return
        }
        #expect(writer.calls.isEmpty)
    }

    @Test("an unsupported extension throws .unsupportedFormat")
    func unsupportedExtensionThrows() {
        let writer = FakeMetadataWriter(unsupportedExtensions: ["shn"])
        let target = URL(fileURLWithPath: "/music/song.shn")
        let error = #expect(throws: MetadataWriteError.self) {
            try writer.writeMetadata(WritableMetadata(title: "A"), to: target)
        }
        guard case .unsupportedFormat = error else {
            Issue.record("expected .unsupportedFormat, got \(String(describing: error))")
            return
        }
    }

    @Test("the onWrite observer fires for a recorded write")
    func onWriteObserverFires() throws {
        final class Box: @unchecked Sendable { var seen: URL? }
        let box = Box()
        let writer = FakeMetadataWriter(onWrite: { _, url in box.seen = url })
        try writer.writeMetadata(WritableMetadata(title: "A"), to: fileURL)
        #expect(box.seen == fileURL)
    }
}
