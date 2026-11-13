// FakeMetadataWriter — a file-free, recording ``MetadataWriting`` for tests.
//
// The test/double counterpart to ``SFBMetadataWriter``. It never touches the
// filesystem: it records every accepted write (so callers can assert what was
// requested) and can be configured to throw a chosen ``MetadataWriteError`` or to
// reject specific extensions — exercising a caller's error handling without
// binary fixtures or real I/O.
//
// This file imports only Foundation + Metadata; it MUST NOT import AppKit or
// UIKit (PlayerCore portability invariant).
import Foundation
import Metadata

/// A ``MetadataWriting`` that records calls instead of writing files. Thread-safe
/// (recording is `NSLock`-guarded), hence `@unchecked Sendable`.
public final class FakeMetadataWriter: MetadataWriting, @unchecked Sendable {
    /// One recorded, accepted write.
    public struct Call: Sendable, Equatable {
        public let metadata: WritableMetadata
        public let url: URL
    }

    /// When non-`nil`, every ``writeMetadata(_:to:)`` throws this and records nothing.
    public let errorToThrow: MetadataWriteError?
    /// Lower-cased extensions rejected as ``MetadataWriteError/unsupportedFormat``.
    public let unsupportedExtensions: Set<String>
    private let onWrite: (@Sendable (WritableMetadata, URL) -> Void)?

    private let lock = NSLock()
    private var recorded: [Call] = []

    public init(
        errorToThrow: MetadataWriteError? = nil,
        unsupportedExtensions: Set<String> = [],
        onWrite: (@Sendable (WritableMetadata, URL) -> Void)? = nil
    ) {
        self.errorToThrow = errorToThrow
        self.unsupportedExtensions = unsupportedExtensions
        self.onWrite = onWrite
    }

    /// Every accepted write, in call order.
    public var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    public func writeMetadata(_ metadata: WritableMetadata, to url: URL) throws {
        if let errorToThrow {
            throw errorToThrow
        }
        if unsupportedExtensions.contains(url.pathExtension.lowercased()) {
            throw MetadataWriteError.unsupportedFormat(url: url)
        }
        lock.lock()
        recorded.append(Call(metadata: metadata, url: url))
        lock.unlock()
        onWrite?(metadata, url)
    }
}
