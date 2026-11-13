// NetworkFetching — the narrow seam between the artwork resolver and the network.
//
// ``ArtworkService`` never touches `URLSession` directly: it talks to this
// protocol so tests can inject a recording fake (proving request ORDER and that
// `allowsNetwork == false` performs ZERO I/O) while production uses
// ``URLSessionNetworkFetcher``. Returning the HTTP status alongside the bytes
// lets the resolver cascade past a 404 (Cover Art Archive miss) to the next
// source without exceptions on the happy path.
//
// Foundation only — PlayerCore MUST NOT import AppKit or UIKit.
import Foundation

/// A `Sendable` byte fetcher that surfaces the HTTP status alongside the payload.
public protocol NetworkFetching: Sendable {
    /// Fetches the bytes at `url`, returning the payload and the HTTP status code.
    ///
    /// The status is `0` when the response was not an `HTTPURLResponse`. The
    /// method throws only on transport failure (DNS, connection, cancellation),
    /// never for a non-2xx status — callers decide how to treat each code.
    func data(from url: URL) async throws -> (Data, Int)
}

/// The production ``NetworkFetching`` backed by `URLSession`.
public struct URLSessionNetworkFetcher: NetworkFetching {
    private let session: URLSession

    /// - Parameter session: The session to issue requests on (defaults to
    ///   `URLSession.shared`).
    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(from url: URL) async throws -> (Data, Int) {
        let (data, response) = try await session.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (data, status)
    }
}
