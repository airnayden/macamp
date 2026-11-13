// HTTPTransport — the single seam through which the kit reaches the network.
//
// `URLSession` appears in exactly ONE file in this repository, and this is it.
// `scripts/check-ai-network-boundary.sh` fails the build if the symbol shows up
// in PlayerCore's assistant/insight code, in the shells' Intelligence panes, or
// in `AIConnectorBridge` — so every byte MacAMP sends to a provider provably
// passes through here, where the deadlines and the failure mapping live.
//
// The seam takes a `URLRequest` rather than a kit-native request type: connectors
// need full control of method, headers and body, tests assert on the recorded
// request, and inventing a parallel request struct would buy nothing but a
// translation layer.
import Foundation

/// What a transport returns. Deliberately not `HTTPURLResponse` — a value type
/// keeps the fake honest and keeps `Foundation`'s class graph out of the
/// connectors.
public struct HTTPResponse: Sendable, Equatable {
    public var statusCode: Int
    public var headers: [String: String]
    public var body: Data

    public init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    public var isSuccess: Bool {
        (200 ..< 300).contains(statusCode)
    }

    /// Case-insensitive header lookup.
    ///
    /// HTTP field names are case-insensitive and providers are inconsistent
    /// (`Retry-After` vs `retry-after`), so a plain dictionary subscript is a bug
    /// waiting for a 429.
    public func headerValue(_ field: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(field) == .orderedSame }?.value
    }
}

/// Performs one HTTP round-trip.
///
/// Conformers throw ``ConnectorFailure`` and nothing else, so a connector can
/// forward transport errors without re-mapping them.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse
}

/// The production transport.
///
/// Every request carries a deadline. This is the SECONDARY defense: it bounds the
/// HTTP round-trip only, and cannot see an async credential provider, a Keychain
/// read, or a token refresh. Callers wrap the whole connector call in
/// ``withDeadline(seconds:operation:)`` for that.
public struct URLSessionTransport: HTTPTransport {
    /// Seconds a request may stall with no data before it fails.
    ///
    /// MUST exceed ``ToolLoopEngine/defaultRoundDeadlineSeconds`` (60): Anthropic
    /// answers non-streaming, so a long generation legitimately delivers ZERO
    /// bytes until it finishes, and a stall timer below the round deadline kills
    /// the turn the loop would have waited for. Measured 2026-09-09: a 43-track
    /// playlist ask died here as "did not answer in time" while the provider was
    /// still generating. Callers' `withDeadline` wrappers remain the PRIMARY
    /// bound; these are the runaway backstop only.
    public static let requestTimeout: TimeInterval = 75
    /// Seconds a whole resource transfer may take. Above the stall timeout for
    /// the same reason — the buffered ChatGPT SSE stream is one transfer that
    /// must FINISH inside this budget, not a download that trickles.
    public static let resourceTimeout: TimeInterval = 90

    /// The shipped configuration.
    ///
    /// `waitsForConnectivity = false` is load-bearing: the default `true` parks a
    /// request until the network returns — indefinitely, ignoring
    /// `timeoutIntervalForRequest` — which turns "you are offline" into a hang.
    /// The assistant must degrade to its local tier promptly instead.
    ///
    /// `.ephemeral` plus the cache/cookie clearing keeps provider responses off
    /// disk; nothing here is worth persisting and some of it is prompt text.
    public static func defaultConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return configuration
    }

    private let session: URLSession

    /// - Parameter configuration: Injectable so a test can shorten the deadlines
    ///   and install a stub `URLProtocol` — which is how the timeout path is
    ///   proven without a live network.
    public init(configuration: URLSessionConfiguration = URLSessionTransport.defaultConfiguration()) {
        session = URLSession(configuration: configuration)
    }

    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ConnectorFailure.unreachable(underlying: ConnectorFailure.DiagnosticToken.invalidResponse)
            }
            return HTTPResponse(statusCode: http.statusCode, headers: Self.headers(from: http), body: data)
        } catch let failure as ConnectorFailure {
            throw failure
        } catch let error as URLError {
            throw Self.connectorFailure(for: error)
        } catch is CancellationError {
            throw ConnectorFailure.cancelled
        } catch {
            throw ConnectorFailure.unreachable(underlying: ConnectorFailure.DiagnosticToken.transportFailure)
        }
    }

    /// Maps a `URLError` onto the taxonomy.
    ///
    /// A TABLE rather than a long switch: the mapping is data, and SwiftLint's
    /// cyclomatic-complexity ceiling is a real one at `--strict`.
    public static func connectorFailure(for error: URLError) -> ConnectorFailure {
        switch error.code {
        case .timedOut:
            .timeout
        case .cancelled:
            .cancelled
        default:
            .unreachable(underlying: unreachableTokens[error.code] ?? ConnectorFailure.DiagnosticToken.transportFailure)
        }
    }

    private static let unreachableTokens: [URLError.Code: String] = [
        .cannotConnectToHost: ConnectorFailure.DiagnosticToken.connectionRefused,
        .cannotFindHost: ConnectorFailure.DiagnosticToken.hostNotFound,
        .dnsLookupFailed: ConnectorFailure.DiagnosticToken.hostNotFound,
        .notConnectedToInternet: ConnectorFailure.DiagnosticToken.networkUnavailable,
        .networkConnectionLost: ConnectorFailure.DiagnosticToken.networkUnavailable,
        .secureConnectionFailed: ConnectorFailure.DiagnosticToken.secureConnectionFailed,
    ]

    private static func headers(from response: HTTPURLResponse) -> [String: String] {
        var result: [String: String] = [:]
        for (field, value) in response.allHeaderFields {
            guard let name = field as? String, let text = value as? String else { continue }
            result[name] = text
        }
        return result
    }
}
