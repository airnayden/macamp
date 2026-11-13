// SubscriptionSignInFixtures — the scaffolding `SubscriptionSignInTests` drives.
//
// Split out for the usual mechanical reason: `file_length` is capped at 400 under
// `swiftlint --strict`. These are `internal` rather than `private` so the suite
// file can see them.
//
// The RAW CLIENT SOCKET here is deliberate. `LoopbackCallbackListener` exists to
// receive one HTTP GET off a real socket, and a mocked transport would assert
// nothing about that. Sixteen lines of `connect`/`write` prove the real thing —
// on a high, dynamically-chosen port, never the production 1455/1457, so a test
// run can never collide with a developer's live sign-in.
import AIConnectorKit
import AIConnectorKitOAuth
import Darwin
import Foundation
@testable import MacAMP
import Services
import Testing

/// Records the URL a sign-in model asked to open, instead of launching a browser.
@MainActor
final class OpenedURLRecorder {
    var captured: URL?
}

enum SignInFixture {
    static let cliAccessToken = "test-token-shell-cli-access"
    static let cliRefreshToken = "test-token-shell-cli-refresh"

    static let ownCredentials = OAuthCredentials(
        accessToken: "test-token-shell-own-access",
        refreshToken: "test-token-shell-own-refresh",
        expiresAt: Date(timeIntervalSince1970: 4_000_000_000),
        subscriptionType: "pro",
        scopes: ["user:profile"]
    )

    /// A stand-in for a Claude Code CLI login already on this Mac.
    static func cliSource() -> BorrowedCredentialSource {
        BorrowedCredentialSource(
            reading: ExternalCredentialReading(
                credentials: OAuthCredentials(
                    accessToken: cliAccessToken,
                    refreshToken: cliRefreshToken,
                    expiresAt: Date(timeIntervalSince1970: 4_000_000_000),
                    subscriptionType: "max",
                    scopes: ["user:profile", "user:inference"]
                ),
                origin: ExternalCredentialOrigin(
                    kind: .keychain,
                    locator: ClaudeCLICredentialStore.primaryKeychainService,
                    account: "listener@example.invalid",
                    isWrapped: true
                )
            )
        )
    }

    // MARK: ChatGPT

    /// A token-endpoint answer carrying an `id_token` whose claims name a plan.
    static var chatGPTTokenResponse: HTTPResponse {
        let header = base64URL(Data("{\"alg\":\"none\"}".utf8))
        let claims = Data("""
        {"https://api.openai.com/auth":{"chatgpt_account_id":"acct-shell-fixture",\
        "chatgpt_plan_type":"pro"},"exp":4000000000}
        """.utf8)
        let identity = "\(header).\(base64URL(claims)).test-token-shell-signature"
        let body = """
        {"access_token":"test-token-shell-access","refresh_token":"test-token-shell-refresh",\
        "id_token":"\(identity)"}
        """
        return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: Data(body.utf8))
    }

    static func chatGPTStack(store: InMemorySecretStore) -> ExternalOAuthComposition.ChatGPTStack {
        ExternalOAuthComposition.makeChatGPTStack(
            store: store,
            transport: ScriptedTransport(response: chatGPTTokenResponse)
        )
    }

    @MainActor
    static func chatGPTModel(ports: [Int], opened: OpenedURLRecorder) -> ChatGPTSignInModel {
        let stack = chatGPTStack(store: InMemorySecretStore())
        return ChatGPTSignInModel(
            flow: stack.flow,
            engine: stack.engine,
            ports: ports,
            openURL: { opened.captured = $0 }
        )
    }

    // MARK: Sockets

    /// A high port nothing is using, and one this process has not handed out yet.
    ///
    /// Bind-probed rather than a fixed number, because a developer's machine is not
    /// serialized with the suite. NEVER repeated, because a probe releases the port
    /// it tested: two consecutive calls would otherwise return the SAME number, and
    /// a fallback test would be asking a listener to fall back to the port it just
    /// bound.
    static func freePort() -> Int {
        portAllocator.next()
    }

    private static let portAllocator = PortAllocator()

    private final class PortAllocator: @unchecked Sendable {
        private let lock = NSLock()
        private var cursor = 45500

        func next() -> Int {
            lock.lock()
            defer { lock.unlock() }
            while cursor < 45700 {
                let candidate = cursor
                cursor += 1
                if SignInFixture.canBind(candidate) { return candidate }
            }
            return cursor
        }
    }

    /// Whether `port` can be bound on loopback right now — the test's way of
    /// asking "is the listener still holding it?".
    static func canBind(_ port: Int) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var address = loopbackAddress(port: port)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return bound == 0
    }

    /// Connects to the listener and sends one HTTP GET, exactly as a browser
    /// following the redirect would.
    static func deliverCallback(port: Int, query: String) {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        var address = loopbackAddress(port: port)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return }
        let request = "GET /auth/callback?\(query) HTTP/1.1\r\nHost: localhost\r\n\r\n"
        _ = Data(request.utf8).withUnsafeBytes { raw in
            raw.baseAddress.map { Darwin.write(descriptor, $0, raw.count) }
        }
    }

    private static func loopbackAddress(port: Int) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = in_addr_t(INADDR_LOOPBACK).bigEndian
        return address
    }

    // MARK: Helpers

    /// Polls `condition` on the main actor until it holds, or gives up.
    ///
    /// The login finishes on an unstructured `Task` that the model owns, so there
    /// is nothing to `await`. Polling with a bounded budget keeps a regression a
    /// FAILURE rather than a wedged CI job.
    @MainActor
    static func settle(
        attempts: Int = 400,
        condition: @MainActor () -> Bool
    ) async throws {
        for _ in 0 ..< attempts {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(condition(), "the sign-in never reached the expected phase")
    }

    static func queryItems(_ url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
    }

    static func text(_ resource: LocalizedStringResource) -> String {
        resource.resolved(in: Locale(identifier: "en"))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// A borrowed credential that reports one fixed reading and survives sign-out.
actor BorrowedCredentialSource: ExternalCredentialSource {
    private var reading: ExternalCredentialReading?

    init(reading: ExternalCredentialReading?) {
        self.reading = reading
    }

    func load() async -> ExternalCredentialReading? {
        reading
    }

    @discardableResult
    func writeBack(_ credentials: OAuthCredentials, to _: ExternalCredentialOrigin) async -> Bool {
        reading?.credentials = credentials
        return true
    }
}
