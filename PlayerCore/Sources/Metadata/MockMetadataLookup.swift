// MockMetadataLookup — a network-free ``OnlineMetadataFetching`` for tests/previews.
//
// The test/preview double for ``MusicBrainzClient``: it returns a canned
// ``MetadataLookupResult`` (or throws a configured error) and records the queries
// it was asked, so **no live network request is ever made off the production
// path**. Mirrors ``MockOnlineLyricsFetcher`` on the lyrics side. Shipped (not
// test-only) so the macOS/iOS preview composition roots can inject it without
// linking the test-support library.
//
// This file imports only Foundation; it MUST NOT import AppKit or UIKit
// (PlayerCore portability invariant).
import Foundation

/// A canned ``OnlineMetadataFetching`` that records its queries and never hits the
/// network. Thread-safe (an `NSLock` guards the recorded queries), hence
/// `@unchecked Sendable`.
public final class MockMetadataFetcher: OnlineMetadataFetching, @unchecked Sendable {
    /// One recorded lookup query, captured verbatim.
    public struct Query: Sendable, Equatable {
        public let artist: String?
        public let title: String?
        public let album: String?
        public let duration: TimeInterval?

        public init(artist: String?, title: String?, album: String?, duration: TimeInterval?) {
            self.artist = artist
            self.title = title
            self.album = album
            self.duration = duration
        }
    }

    private let lock = NSLock()
    private let result: MetadataLookupResult?
    private let errorToThrow: (any Error)?
    private var recorded: [Query] = []

    /// Creates a mock.
    ///
    /// - Parameters:
    ///   - result: the value every lookup returns (defaults to `nil` = no match).
    ///   - errorToThrow: when non-`nil`, every lookup throws this instead of returning.
    public init(returning result: MetadataLookupResult? = nil, throwing errorToThrow: (any Error)? = nil) {
        self.result = result
        self.errorToThrow = errorToThrow
    }

    /// Every query this mock was asked to resolve, in call order.
    public var queries: [Query] {
        lock.withLock { recorded }
    }

    /// The number of times ``lookup(artist:title:album:duration:)`` was invoked.
    public var lookupCount: Int {
        lock.withLock { recorded.count }
    }

    public func lookup(
        artist: String?,
        title: String?,
        album: String?,
        duration: TimeInterval?
    ) async throws -> MetadataLookupResult? {
        lock.withLock {
            recorded.append(Query(artist: artist, title: title, album: album, duration: duration))
        }
        if let errorToThrow {
            throw errorToThrow
        }
        return result
    }
}
