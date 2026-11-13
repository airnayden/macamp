// FakeHTTPTransport — the scripted stand-in every connector suite drives.
//
// Lives in the TEST target, not in Sources: it is test scaffolding, and shipping
// it in the product would put a "pretend the provider said this" switch inside the
// binary. Every connector test in this target (Ollama, Anthropic, OpenAI, the
// registry probe) scripts this type instead of touching the network — the kit's
// suites make ZERO live requests.
//
// An `actor` rather than a lock-guarded class so `recordedRequests` is race-free
// under Swift 6 strict concurrency without any `@unchecked` escape hatch. The
// never-respond mode parks in `Task.sleep`, which suspends and RELEASES the actor,
// so a test can still read the recorded requests while a call is hanging.
import AIConnectorKit
import Foundation

actor FakeHTTPTransport: HTTPTransport {
    /// What the fake does for one request.
    enum Script {
        /// Answer immediately.
        case success(HTTPResponse)
        /// Throw a taxonomy failure immediately — how connector suites exercise
        /// 401 / 429 / refused-connection mapping without a socket.
        case failure(ConnectorFailure)
        /// Answer after a delay. Cancellation-aware, so a deadline race around it
        /// really does stop the work.
        case delayed(HTTPResponse, seconds: TimeInterval)
        /// Never answer.
        ///
        /// With ``simulatedRequestTimeout`` set this throws
        /// ``ConnectorFailure/timeout`` after that interval — a transport whose own
        /// per-request deadline fired. With it `nil` the call parks until cancelled
        /// and then throws ``ConnectorFailure/cancelled``, which is what proves an
        /// outer `withDeadline` cancels its loser rather than abandoning it.
        case neverRespond
    }

    /// How long a parked call waits before giving up when nothing cancels it.
    /// Long enough that a passing test never reaches it; short enough that a
    /// regression fails the suite instead of wedging CI.
    private static let parkSeconds: TimeInterval = 30

    private var pendingScripts: [Script]
    private let fallback: Script
    private let simulatedRequestTimeout: TimeInterval?

    /// Every request the fake was handed, in order. Connector suites assert on
    /// headers, method, URL and body here.
    private(set) var recordedRequests: [URLRequest] = []

    /// - Parameters:
    ///   - scripts: Consumed front-first, one per request.
    ///   - fallback: Used once `scripts` runs out. Defaults to a failure rather
    ///     than a canned 200 so an unscripted call is loud, not silently green.
    ///   - simulatedRequestTimeout: Makes ``Script/neverRespond`` behave like a
    ///     transport whose per-request deadline fired.
    init(
        scripts: [Script] = [],
        fallback: Script = .failure(.unreachable(underlying: "fake-unscripted-request")),
        simulatedRequestTimeout: TimeInterval? = nil
    ) {
        pendingScripts = scripts
        self.fallback = fallback
        self.simulatedRequestTimeout = simulatedRequestTimeout
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        recordedRequests.append(request)
        switch nextScript() {
        case let .success(response):
            return response
        case let .failure(failure):
            throw failure
        case let .delayed(response, seconds):
            try await sleep(seconds)
            return response
        case .neverRespond:
            try await sleep(simulatedRequestTimeout ?? Self.parkSeconds)
            throw ConnectorFailure.timeout
        }
    }

    private func nextScript() -> Script {
        pendingScripts.isEmpty ? fallback : pendingScripts.removeFirst()
    }

    /// Sleeps, translating cooperative cancellation into the taxonomy so the fake
    /// keeps the "conformers throw `ConnectorFailure` and nothing else" contract
    /// that ``AIProviderConnector`` places on real connectors.
    private func sleep(_ seconds: TimeInterval) async throws {
        do {
            try await Task.sleep(for: .seconds(seconds))
        } catch {
            throw ConnectorFailure.cancelled
        }
    }
}
