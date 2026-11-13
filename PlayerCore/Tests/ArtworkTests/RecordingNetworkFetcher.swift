@testable import Artwork
import Foundation

/// A test-only ``NetworkFetching`` that records every requested URL (in call
/// order) and replies with canned `(bytes, status)` from an injected responder.
///
/// It performs NO real I/O, so suites can both assert resolution ORDER and prove
/// that a network-disabled request issues ZERO calls.
actor RecordingNetworkFetcher: NetworkFetching {
    /// Every URL passed to ``data(from:)``, in the order requested.
    private(set) var requestedURLs: [URL] = []
    private let responder: @Sendable (URL) -> (Data, Int)

    init(responder: @escaping @Sendable (URL) -> (Data, Int)) {
        self.responder = responder
    }

    func data(from url: URL) async throws -> (Data, Int) {
        requestedURLs.append(url)
        return responder(url)
    }
}
