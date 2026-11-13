// Shared scaffolding for the OAuth suites. ZERO live network, ZERO real entropy,
// ZERO real clock — every one of those is injected, which is the only reason the
// PKCE and rotation behaviour can be asserted exactly rather than approximately.
//
// EVERY fake secret in this target is prefixed `test-token-`. The secret-leak
// suite greps error output for that exact prefix, so a placeholder that looked
// like a plausible credential would both weaken the leak proof and put a
// realistic-looking string in the repository.
import AIConnectorKit
@testable import AIConnectorKitOAuth
import Foundation

enum OAuthFixture {
    static let accessToken = "test-token-access-alpha"
    static let refreshToken = "test-token-refresh-alpha"
    static let rotatedAccessToken = "test-token-access-beta"
    static let rotatedRefreshToken = "test-token-refresh-beta"
    static let authorizationCode = "test-token-authcode-gamma"

    /// Fixed instant every suite measures expiry against.
    static let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    /// Verifier entropy. A constant byte pattern, distinct from ``stateEntropy``,
    /// so a flow that derived one from the other fails loudly.
    static let verifierEntropy = Data(repeating: 0x01, count: 32)
    static let stateEntropy = Data(repeating: 0x02, count: 32)

    static func credentials(
        accessToken: String = OAuthFixture.accessToken,
        refreshToken: String = OAuthFixture.refreshToken,
        expiresAt: Date = OAuthFixture.epoch.addingTimeInterval(3600),
        subscriptionType: String? = "max",
        scopes: [String] = ["user:profile", "user:inference"]
    ) -> OAuthCredentials {
        OAuthCredentials(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt,
            subscriptionType: subscriptionType,
            scopes: scopes
        )
    }

    static func tokenResponse(
        accessToken: String,
        refreshToken: String?,
        expiresIn: Int = 28800,
        subscriptionType: String? = nil
    ) -> HTTPResponse {
        var fields = ["\"access_token\": \"\(accessToken)\"", "\"expires_in\": \(expiresIn)"]
        if let refreshToken {
            fields.append("\"refresh_token\": \"\(refreshToken)\"")
        }
        if let subscriptionType {
            fields.append("\"account\": {\"subscription_type\": \"\(subscriptionType)\"}")
        }
        return HTTPResponse(
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            body: Data("{\(fields.joined(separator: ","))}".utf8)
        )
    }

    /// A configuration pointed at an unroutable fixture host with a short
    /// deadline, so a suite can never accidentally reach the real provider and a
    /// deadline test finishes in well under a second.
    static func testConfiguration(
        bodyEncoding: OAuthEndpointConfiguration.BodyEncoding = .json,
        deadline: TimeInterval = 15
    ) -> OAuthEndpointConfiguration {
        var configuration = OAuthEndpointConfiguration.claudeSubscription
        configuration.authorizeURL = URL(fileURLWithPath: "/fixture-authorize")
        configuration.tokenURL = URL(fileURLWithPath: "/fixture-token")
        configuration.tokenBodyEncoding = bodyEncoding
        configuration.tokenRequestDeadline = deadline
        return configuration
    }
}

/// Scripted stand-in for the network. Records every request so a suite can assert
/// on the exact body and headers the flow produced.
actor FakeTokenTransport: HTTPTransport {
    enum Script {
        case success(HTTPResponse)
        case failure(ConnectorFailure)
        /// Parks until cancelled — how the exchange deadline is proven without
        /// waiting for a real timeout.
        case neverRespond
    }

    private var pending: [Script]
    private(set) var recordedRequests: [URLRequest] = []

    init(_ pending: [Script] = []) {
        self.pending = pending
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        recordedRequests.append(request)
        switch pending.isEmpty ? .failure(.unreachable(underlying: "fake-unscripted-request")) : pending.removeFirst() {
        case let .success(response):
            return response
        case let .failure(failure):
            throw failure
        case .neverRespond:
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                throw ConnectorFailure.cancelled
            }
            throw ConnectorFailure.timeout
        }
    }

    /// The decoded UTF-8 body of request `index`, for body-shape assertions.
    func recordedBody(_ index: Int) -> String? {
        guard recordedRequests.indices.contains(index), let body = recordedRequests[index].httpBody else {
            return nil
        }
        return String(bytes: body, encoding: .utf8)
    }

    func recordedHeader(_ field: String, at index: Int) -> String? {
        guard recordedRequests.indices.contains(index) else { return nil }
        return recordedRequests[index].value(forHTTPHeaderField: field)
    }
}

/// Hands out pre-decided "random" values, in order, and remembers how many bytes
/// each call asked for.
///
/// `@unchecked Sendable` with an explicit lock because the entropy seam is a
/// synchronous `@Sendable` closure — an actor cannot witness one.
final class ScriptedRandomBytes: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [Data]
    private var counts: [Int] = []

    init(_ pending: [Data]) {
        self.pending = pending
    }

    var provider: @Sendable (Int) -> Data {
        { [self] count in
            lock.lock()
            defer { lock.unlock() }
            counts.append(count)
            return pending.isEmpty ? Data(repeating: 0xFF, count: count) : pending.removeFirst()
        }
    }

    /// Byte counts requested, in call order. Proves the RFC 7636 entropy budget.
    var requestedCounts: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return counts
    }
}

/// A clock the test moves by hand, so expiry-driven behaviour never depends on
/// elapsed wall time.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ current: Date = OAuthFixture.epoch) {
        self.current = current
    }

    var now: @Sendable () -> Date {
        { [self] in
            lock.lock()
            defer { lock.unlock() }
            return current
        }
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        current = current.addingTimeInterval(interval)
    }
}

/// Independent base64url oracle — deliberately NOT the shipping implementation,
/// so a bug in the encoder cannot pass by agreeing with itself.
func expectedBase64URL(_ data: Data) -> String {
    var text = ""
    let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
    var index = data.startIndex
    while index < data.endIndex {
        let remaining = data.distance(from: index, to: data.endIndex)
        let byte0 = Int(data[index])
        let byte1 = remaining > 1 ? Int(data[data.index(index, offsetBy: 1)]) : 0
        let byte2 = remaining > 2 ? Int(data[data.index(index, offsetBy: 2)]) : 0
        let triple = byte0 << 16 | byte1 << 8 | byte2
        text.append(alphabet[triple >> 18 & 0x3F])
        text.append(alphabet[triple >> 12 & 0x3F])
        if remaining > 1 { text.append(alphabet[triple >> 6 & 0x3F]) }
        if remaining > 2 { text.append(alphabet[triple & 0x3F]) }
        index = data.index(index, offsetBy: min(3, remaining))
    }
    return text
}
