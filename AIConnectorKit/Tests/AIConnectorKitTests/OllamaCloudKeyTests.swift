// OllamaCloudKeyTests — the OPTIONAL bearer, and the promise that it changes
// nothing else.
//
// Ollama Cloud speaks the same native API as a self-hosted server and differs by
// exactly one header. The claims worth pinning are therefore symmetrical:
//
//   * WITH a key, `Authorization: Bearer <key>` rides every request.
//   * WITHOUT one, the request is byte-identical to what this connector has always
//     sent — no header, no empty header, no `Bearer `.
//
// The second is the one that can regress silently: a stray `Bearer ` makes a
// perfectly good self-hosted server answer 401, and nothing in the UI would
// explain why.
import AIConnectorKit
import Foundation
import Testing

@Suite("OllamaCloudKeyTests")
struct OllamaCloudKeyTests {
    private static let key = "test-token-ollama-cloud-alpha"

    @Test("With no key, no Authorization header is sent on either endpoint")
    func selfHostedSendsNoAuthorization() async throws {
        let transport = try FakeHTTPTransport(scripts: [
            .success(OllamaFixture.response(OllamaFixture.tags)),
            .success(OllamaFixture.response(OllamaFixture.chatStructured)),
        ])
        let connector = OllamaConnector(transport: transport)

        _ = try await connector.listModels()
        _ = try await connector.completion(instructions: "i", prompt: "p", model: "m")

        let recorded = await transport.recordedRequests
        #expect(recorded.count == 2)
        #expect(recorded.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
    }

    @Test("With a key, every request carries the bearer")
    func cloudSendsTheBearerEverywhere() async throws {
        let transport = try FakeHTTPTransport(scripts: [
            .success(OllamaFixture.response(OllamaFixture.tags)),
            .success(OllamaFixture.response(OllamaFixture.chatStructured)),
        ])
        let connector = OllamaConnector(apiKey: { Self.key }, transport: transport)

        _ = try await connector.listModels()
        _ = try await connector.completion(instructions: "i", prompt: "p", model: "m")

        let recorded = await transport.recordedRequests
        #expect(recorded.count == 2)
        #expect(recorded.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.key)"
        })
    }

    @Test("A key changes ONLY the header — never the URL, method or body")
    func aKeyChangesNothingElseOnTheWire() async throws {
        let keyless = try FakeHTTPTransport(scripts: [.success(OllamaFixture.response(OllamaFixture.chatStructured))])
        let keyed = try FakeHTTPTransport(scripts: [.success(OllamaFixture.response(OllamaFixture.chatStructured))])

        _ = try await OllamaConnector(transport: keyless)
            .structuredCompletion(
                schema: OllamaFixture.querySchema,
                instructions: "classify",
                prompt: "seventies rock",
                model: "llama3.2:latest"
            )
        _ = try await OllamaConnector(apiKey: { Self.key }, transport: keyed)
            .structuredCompletion(
                schema: OllamaFixture.querySchema,
                instructions: "classify",
                prompt: "seventies rock",
                model: "llama3.2:latest"
            )

        let plain = try #require(await keyless.recordedRequests.first)
        let authorized = try #require(await keyed.recordedRequests.first)
        #expect(plain.url == authorized.url)
        #expect(plain.httpMethod == authorized.httpMethod)
        #expect(plain.httpBody == authorized.httpBody)
        #expect(plain.value(forHTTPHeaderField: "Content-Type")
            == authorized.value(forHTTPHeaderField: "Content-Type"))
    }

    @Test("A blank or whitespace key reads as absent, never as an empty bearer")
    func blankKeysAreAbsent() async throws {
        // `Bearer ` would make a self-hosted server that ignores auth answer 401 on
        // some proxies, with nothing in the UI to explain it. The config sheet
        // stores what was typed, so this case is reachable by clearing a field.
        for blank in ["", "   ", "\n\t"] {
            let transport = try FakeHTTPTransport(scripts: [.success(OllamaFixture.response(OllamaFixture.tags))])
            _ = try await OllamaConnector(apiKey: { blank }, transport: transport).listModels()
            let request = try #require(await transport.recordedRequests.first)
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        }
    }

    @Test("A throwing key provider is a keyless request, NOT an unconfigured failure")
    func aThrowingProviderDegradesToKeyless() async throws {
        // Unlike the API-key connectors, "no key stored" is the DEFAULT state of a
        // working Ollama connector — the Keychain read throws on every self-hosted
        // install, and raising `.unconfigured` there would break all of them.
        struct Missing: Error {}
        let transport = try FakeHTTPTransport(scripts: [.success(OllamaFixture.response(OllamaFixture.tags))])

        let models = try await OllamaConnector(apiKey: { throw Missing() }, transport: transport).listModels()

        #expect(models.isEmpty == false)
        let request = try #require(await transport.recordedRequests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("The key is resolved per request, so a change needs no rebuild")
    func theKeyIsResolvedPerRequest() async throws {
        let counter = CallCounter()
        let transport = try FakeHTTPTransport(scripts: [
            .success(OllamaFixture.response(OllamaFixture.tags)),
            .success(OllamaFixture.response(OllamaFixture.tags)),
        ])
        let connector = OllamaConnector(
            apiKey: { await counter.next() },
            transport: transport
        )

        _ = try await connector.listModels()
        _ = try await connector.listModels()

        let recorded = await transport.recordedRequests
        #expect(recorded.first?.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.key)-1")
        #expect(recorded.last?.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.key)-2")
    }

    /// Hands out a different key each call, so "resolved once at construction"
    /// fails loudly instead of passing by coincidence.
    private actor CallCounter {
        private var count = 0

        func next() -> String {
            count += 1
            return "\(OllamaCloudKeyTests.key)-\(count)"
        }
    }
}
