// ConnectorRegistryProbeTests — the four status mappings, against REAL connectors.
//
// These drive the shipped `OllamaConnector` / `OpenAIConnector` rather than a stub
// because the claim under test is only half about `probe()`. The other half —
// "an unconfigured connector performs ZERO transport calls" — is a property of the
// connectors' credential step, and a stub asserting it would prove nothing about
// the code that actually runs. `FakeHTTPTransport.recordedRequests` is the witness.
//
// Every byte comes from a committed fixture and no socket is opened, so a machine
// with no Ollama and no API key runs exactly these assertions.
import AIConnectorKit
import Foundation
import Testing

@Suite("ConnectorRegistryProbeTests")
struct ConnectorRegistryProbeTests {
    /// How long a probe-deadline test is allowed to take. Far below the shipped
    /// 20 s budget so the suite stays fast, far above scheduling noise so it does
    /// not flake.
    private static let shortDeadline: TimeInterval = 0.2

    // MARK: - The four mappings the acceptance criteria name

    @Test("A ready connector reports the models the provider listed")
    func aReadyConnectorReportsItsModels() async throws {
        let transport = try RegistryFixture.transport(RegistryFixture.openAIModels)
        let connector = RegistryFixture.openAI(transport: transport)

        let status = await connector.probe()

        // The blank-id entry in the fixture is dropped by the connector, so this
        // also pins that `.ready` carries the connector's list verbatim rather
        // than a re-derived one.
        #expect(status == .ready(models: [
            ModelInfo(id: "gpt-4o"),
            ModelInfo(id: "gpt-4o-mini"),
            ModelInfo(id: "text-embedding-3-small"),
        ]))
        #expect(status.isReady)
        #expect(status.reportedModels?.count == 3)
        #expect(await transport.recordedRequests.count == 1)
    }

    @Test("A rejected credential reports authExpired, not unreachable")
    func aRejectedCredentialReportsAuthExpired() async throws {
        let transport = try RegistryFixture.transport(RegistryFixture.openAIUnauthorized, statusCode: 401)
        let connector = RegistryFixture.openAI(transport: transport)

        let status = await connector.probe()

        // The distinction is the whole point: `.authExpired` is the one status the
        // listener can act on, so it must not be flattened into `.unreachable`.
        #expect(status == .authExpired)
        #expect(status.isReady == false)
        #expect(status.reportedModels == nil)
        #expect(await transport.recordedRequests.count == 1)
    }

    @Test("A transport that times out reports unreachable, carrying .timeout")
    func aTimedOutTransportReportsUnreachableTimeout() async {
        let transport = FakeHTTPTransport(scripts: [.neverRespond], simulatedRequestTimeout: 0.05)
        let connector = RegistryFixture.openAI(transport: transport)

        let status = await connector.probe()

        #expect(status == .unreachable(.timeout))
    }

    @Test("An unconfigured connector is reported without a single transport call")
    func anUnconfiguredConnectorNeverReachesTheTransport() async throws {
        // A blank key and a throwing key provider are the two shapes "not set up
        // yet" arrives in — an empty settings field, and a Keychain read that
        // found nothing. Both must cost zero requests: the pane probes on
        // appearance and the ladder probes before every attempt, so a round-trip
        // here would be a timeout on every interaction for a listener who never
        // configured anything — and it would read as "authentication failed" for
        // a key they never entered.
        struct NoStoredSecret: Error {}
        let blankKeyTransport = try RegistryFixture.transport(RegistryFixture.openAIModels)
        let throwingKeyTransport = try RegistryFixture.transport(RegistryFixture.openAIModels)

        let blank = OpenAIConnector(apiKey: { "   " }, transport: blankKeyTransport)
        let throwing = OpenAIConnector(apiKey: { throw NoStoredSecret() }, transport: throwingKeyTransport)

        #expect(await blank.probe() == .unconfigured)
        #expect(await throwing.probe() == .unconfigured)
        #expect(await blankKeyTransport.recordedRequests.isEmpty)
        #expect(await throwingKeyTransport.recordedRequests.isEmpty)
    }

    // MARK: - The deadline, and the payloads that must survive it

    @Test("The probe's own deadline bounds a call the transport never answers")
    func theProbesOwnDeadlineBoundsACallThatNeverAnswers() async {
        // `simulatedRequestTimeout` is deliberately absent: this transport parks
        // for 30 s, so only the `withDeadline` race around the whole call can end
        // it. That is the layer a transport timeout cannot cover — an async
        // credential provider or a token refresh stalling before the socket
        // exists — and this proves the probe really is wrapped in it.
        let transport = FakeHTTPTransport(scripts: [.neverRespond])
        let connector = RegistryFixture.openAI(transport: transport)

        let started = Date()
        let status = await connector.probe(deadlineSeconds: Self.shortDeadline)

        #expect(status == .unreachable(.timeout))
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test("An unreachable failure keeps its diagnostic token verbatim")
    func anUnreachableFailureKeepsItsDiagnosticToken() async {
        let refused = ConnectorFailure.unreachable(underlying: ConnectorFailure.DiagnosticToken.connectionRefused)
        let transport = FakeHTTPTransport(scripts: [.failure(refused)])
        let connector = RegistryFixture.ollama(transport: transport)

        let status = await connector.probe()

        // `.unreachable` carries the WHOLE failure, not a flattened token, so the
        // shell can still tell "Ollama isn't running" from "the host is wrong".
        #expect(status == .unreachable(.unreachable(underlying: "connection-refused")))
    }

    @Test("Ollama has no unconfigured state and probes straight through")
    func ollamaIsConfiguredByConstruction() async throws {
        let transport = try RegistryFixture.transport(RegistryFixture.ollamaTags)
        let connector = RegistryFixture.ollama(transport: transport)

        // `init` takes a non-optional host, so there is nothing to leave unset —
        // which is why its descriptor reports `requiresStoredSecret == false` and
        // the registry probes it directly instead of gating on a secret.
        #expect(connector.authDescriptor.requiresStoredSecret == false)

        let status = await connector.probe()

        #expect(status.reportedModels?.map(\.id) == [
            "llama3.2:latest",
            "qwen2.5:7b",
            "mistral-small:24b",
        ])
    }

    // MARK: - Totality

    @Test("Every failure in the taxonomy maps onto exactly one status")
    func everyFailureMapsOntoExactlyOneStatus() {
        // The mapping is written as an exhaustive switch with no `default:`, so a
        // tenth `ConnectorFailure` case breaks the build rather than silently
        // becoming `.unreachable`. This table is the runtime half of that claim.
        #expect(ConnectorStatus(.unconfigured) == .unconfigured)
        #expect(ConnectorStatus(.authExpired) == .authExpired)

        let passthrough: [ConnectorFailure] = [
            .unreachable(underlying: ConnectorFailure.DiagnosticToken.hostNotFound),
            .timeout,
            .httpStatus(500, body: "boom", providerMessage: nil),
            .rateLimited(retryAfter: 12),
            .malformedResponse,
            .cancelled,
        ]
        for failure in passthrough {
            #expect(ConnectorStatus(failure) == .unreachable(failure))
        }
    }

    @Test("ready(models:) tells nil apart from an empty list")
    func readyDistinguishesUnaskedFromEmpty() {
        // `nil` means "reachable, not enumerated" — a cheap credential gate.
        // `[]` means "the provider listed nothing", which is a real state: an
        // Ollama server with no models pulled. Collapsing them would make an
        // empty picker indistinguishable from an unfetched one.
        #expect(ConnectorStatus.ready(models: nil).reportedModels == nil)
        #expect(ConnectorStatus.ready(models: []).reportedModels == [])
        #expect(ConnectorStatus.ready(models: nil) != .ready(models: []))
        #expect(ConnectorStatus.ready(models: nil).isReady)
        #expect(ConnectorStatus.ready(models: []).isReady)
    }
}
