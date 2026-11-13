// OllamaFailureMappingTests — every way a local server can let the app down.
//
// This is the half of the connector that decides whether the assistant degrades
// SILENTLY to its local tier or surfaces a diagnosable state. `ConnectorFailure`
// carries no `default:` at any consumer, so each case below is a distinct branch
// in the shell's status copy — mapping a refused connection to `.malformedResponse`
// would tell the listener their model misbehaved when the truth is that Ollama is
// simply not running.
//
// "Ollama is not running" is by far the most common real failure, which is why
// `.unreachable(underlying: .connectionRefused)` gets its own test rather than
// riding along in a table.
import AIConnectorKit
import Foundation
import Testing

/// A transport that breaks ``HTTPTransport``'s "throws `ConnectorFailure` and
/// nothing else" promise, standing in for a decorator or a double written in
/// another app that lifted this target.
private struct RogueTransport: HTTPTransport {
    struct Boom: Error {}

    func send(_: URLRequest) async throws -> HTTPResponse {
        throw Boom()
    }
}

@Suite("OllamaFailureMappingTests")
struct OllamaFailureMappingTests {
    private static let model = "llama3.2:latest"
    private static let framing = "You classify listening requests."
    private static let ask = "seventies rock"

    /// Generous next to the 0.05 s simulated deadline, tight enough that a genuine
    /// hang fails the suite instead of wedging the run.
    private static let hangCeilingSeconds: TimeInterval = 10

    private static func connector(_ scripts: [FakeHTTPTransport.Script]) -> OllamaConnector {
        OllamaConnector(transport: FakeHTTPTransport(scripts: scripts))
    }

    @Test("A refused connection is forwarded unchanged — the 'Ollama isn't running' case")
    func refusedConnectionIsForwardedAsUnreachable() async throws {
        let refused = ConnectorFailure.unreachable(underlying: ConnectorFailure.DiagnosticToken.connectionRefused)

        await #expect(throws: refused) {
            _ = try await Self.connector([.failure(refused)]).listModels()
        }
        await #expect(throws: refused) {
            _ = try await Self.connector([.failure(refused)]).completion(
                instructions: Self.framing,
                prompt: Self.ask,
                model: Self.model
            )
        }
    }

    @Test("A server that never answers fails with .timeout rather than hanging")
    func neverRespondingServerFailsWithTimeout() async throws {
        let startedAt = Date()

        await #expect(throws: ConnectorFailure.timeout) {
            let transport = FakeHTTPTransport(scripts: [.neverRespond], simulatedRequestTimeout: 0.05)
            _ = try await OllamaConnector(transport: transport).listModels()
        }
        await #expect(throws: ConnectorFailure.timeout) {
            let transport = FakeHTTPTransport(scripts: [.neverRespond], simulatedRequestTimeout: 0.05)
            _ = try await OllamaConnector(transport: transport).structuredCompletion(
                schema: OllamaFixture.querySchema,
                instructions: Self.framing,
                prompt: Self.ask,
                model: Self.model
            )
        }

        #expect(Date().timeIntervalSince(startedAt) < Self.hangCeilingSeconds)
    }

    @Test("A 200 whose body is not JSON is .malformedResponse, not a crash")
    func nonJSONEnvelopeIsMalformed() async throws {
        // What a streaming answer looks like to a single `decode` call, and what a
        // captive-portal or proxy interstitial returns with a 200.
        let notJSON = HTTPResponse(statusCode: 200, body: Data("<html>hello</html>".utf8))

        await #expect(throws: ConnectorFailure.malformedResponse) {
            _ = try await Self.connector([.success(notJSON)]).listModels()
        }
        await #expect(throws: ConnectorFailure.malformedResponse) {
            _ = try await Self.connector([.success(notJSON)]).completion(
                instructions: Self.framing,
                prompt: Self.ask,
                model: Self.model
            )
        }
    }

    @Test("Schema-constrained content that is not a JSON document is .malformedResponse")
    func structuredContentThatIsNotJSONIsMalformed() async throws {
        // `format` constrains decoding, it does not guarantee it: a model that runs
        // out of tokens mid-object still answers 200. The connector, not the bridge,
        // is where that becomes a taxonomy failure.
        let prose = #"{"message":{"role":"assistant","content":"I'm afraid I can't do that."}}"#
        let response = HTTPResponse(statusCode: 200, body: Data(prose.utf8))

        await #expect(throws: ConnectorFailure.malformedResponse) {
            _ = try await Self.connector([.success(response)]).structuredCompletion(
                schema: OllamaFixture.querySchema,
                instructions: Self.framing,
                prompt: Self.ask,
                model: Self.model
            )
        }
    }

    @Test("An empty assistant turn is .malformedResponse, not an empty answer")
    func emptyAssistantContentIsMalformed() async throws {
        // Ollama answers this shape for a warm-up request (`done_reason: "load"`).
        // A caller that asked for prose and got nothing has a contract violation.
        let warmUp = #"{"message":{"role":"assistant","content":""},"done_reason":"load","done":true}"#
        let response = HTTPResponse(statusCode: 200, body: Data(warmUp.utf8))

        await #expect(throws: ConnectorFailure.malformedResponse) {
            _ = try await Self.connector([.success(response)]).completion(
                instructions: Self.framing,
                prompt: Self.ask,
                model: Self.model
            )
        }
    }

    @Test("The provider's own error message survives into .httpStatus")
    func providerErrorMessageSurvivesIntoHttpStatus() async throws {
        let response = try OllamaFixture.response(OllamaFixture.chatError, statusCode: 404)
        let expected = #"model "llama9000" not found, try pulling it first"#

        await #expect(throws: ConnectorFailure.httpStatus(404, body: expected, providerMessage: nil)) {
            _ = try await Self.connector([.success(response)]).completion(
                instructions: Self.framing,
                prompt: Self.ask,
                model: Self.model
            )
        }
    }

    @Test("A non-JSON error body is surfaced as truncated text")
    func nonJSONErrorBodyIsSurfacedAsTruncatedText() async throws {
        let gateway = "<html><head><title>502 Bad Gateway</title></head></html>"
        let response = HTTPResponse(statusCode: 502, body: Data(gateway.utf8))

        await #expect(throws: ConnectorFailure.httpStatus(502, body: gateway, providerMessage: nil)) {
            _ = try await Self.connector([.success(response)]).listModels()
        }
    }

    @Test("A very long error body is capped before it reaches a diagnostic surface")
    func aVeryLongErrorBodyIsCapped() async throws {
        let response = HTTPResponse(statusCode: 500, body: Data(String(repeating: "x", count: 900).utf8))

        let thrown = await #expect(throws: ConnectorFailure.self) {
            _ = try await Self.connector([.success(response)]).listModels()
        }

        let failure = try #require(thrown)
        #expect(failure == .httpStatus(500, body: String(repeating: "x", count: 512), providerMessage: nil))
    }

    @Test("401 and 403 mean re-authenticate, not retry — a proxy in front of Ollama")
    func unauthorizedStatusesMapToAuthExpired() async throws {
        // A stock `ollama serve` has no auth, so these can only come from something
        // in front of it. Mapping them makes "Ollama behind nginx" diagnosable.
        for status in [401, 403] {
            let response = HTTPResponse(statusCode: status, body: Data("nope".utf8))
            await #expect(throws: ConnectorFailure.authExpired) {
                _ = try await Self.connector([.success(response)]).listModels()
            }
        }
    }

    @Test("429 carries a parsed Retry-After, and tolerates a missing one")
    func throttledStatusCarriesRetryAfter() async throws {
        let withHeader = HTTPResponse(statusCode: 429, headers: ["retry-after": "30"])
        await #expect(throws: ConnectorFailure.rateLimited(retryAfter: 30)) {
            _ = try await Self.connector([.success(withHeader)]).listModels()
        }

        // An unparseable or absent value must not become a fabricated delay.
        let withoutHeader = HTTPResponse(statusCode: 429, headers: ["Retry-After": "soon"])
        await #expect(throws: ConnectorFailure.rateLimited(retryAfter: nil)) {
            _ = try await Self.connector([.success(withoutHeader)]).listModels()
        }
    }

    @Test("A transport that breaks the taxonomy still cannot leak a foreign error")
    func aForeignTransportErrorIsMappedIntoTheTaxonomy() async throws {
        let connector = OllamaConnector(transport: RogueTransport())
        let expected = ConnectorFailure.unreachable(underlying: ConnectorFailure.DiagnosticToken.transportFailure)

        await #expect(throws: expected) {
            _ = try await connector.listModels()
        }
    }
}
