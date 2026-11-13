// Hermetic proof of the ChatGPT subscription connector. ZERO live network — every
// suite drives `FakeTokenTransport` against checked-in response bodies.
//
// The connector ships DISABLED (see `ChatGPTConnector`'s header), and these tests
// are why that is a REGISTRY decision rather than an excuse: the wire shape is
// implemented, asserted, and degrades correctly on every failure the researched
// endpoint is known to produce.
import AIConnectorKit
@testable import AIConnectorKitOAuth
import Foundation
import Testing

enum ChatGPTConnectorFixture {
    static func connector(
        transport: FakeTokenTransport,
        token: String = ChatGPTFixture.accessToken,
        accountID: @escaping @Sendable () async throws -> String? = { nil }
    ) -> ChatGPTConnector {
        ChatGPTConnector(
            bearerToken: { token },
            accountID: accountID,
            transport: transport
        )
    }

    static func json(_ text: String, statusCode: Int = 200, headers: [String: String] = [:]) -> HTTPResponse {
        HTTPResponse(
            statusCode: statusCode,
            headers: headers.isEmpty ? ["Content-Type": "application/json"] : headers,
            body: Data(text.utf8)
        )
    }

    static func reply(_ text: String) -> HTTPResponse {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return json(
            "{\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"\(escaped)\"}]}]}"
        )
    }

    static var schema: JSONSchemaObject {
        JSONSchemaObject(properties: [
            JSONSchemaObject.Property(name: "genres", schema: .array(of: .string())),
        ])
    }
}

@Suite("ChatGPTConnectorIdentityTests")
struct ChatGPTConnectorIdentityTests {
    @Test("The connector declares the subscription auth descriptor and a stable id")
    func connectorIdentityIsStable() {
        let connector = ChatGPTConnectorFixture.connector(transport: FakeTokenTransport())
        #expect(connector.id == "chatgpt")
        #expect(connector.displayName == "ChatGPT")
        #expect(connector.authDescriptor == .subscription)
        #expect(connector.authDescriptor.requiresStoredSecret)
    }

    @Test("The shipped determination is LIVE, and the two facts agree")
    func shippedDeterminationIsLive() {
        // These two constants must move together: whoever changes the
        // determination flips both, and this test fails if they flip only one.
        #expect(ChatGPTConnector.isUpstreamFlowVerified)
        #expect(ChatGPTConnector.registrationStatus == .unconfigured)
        // `.unconfigured` is "not signed in yet", NOT "ready": the registry must
        // still refuse to route through it until a credential exists.
        #expect(ChatGPTConnector.registrationStatus.isReady == false)
    }

    @Test("The disabled machinery survives the flip, ready for the next breakage")
    func disabledMachineryIsRetained() {
        // Deleting this because the connector is currently live would mean
        // re-deriving it under pressure the next time upstream moves — which is
        // exactly the 2026-08-21 situation this connector was already in once.
        // The token is the canonical constant, not a matching literal, so the two
        // cannot drift apart and strand the shell's localized mapping.
        #expect(ChatGPTConnector.disabledReason == ConnectorStatus.DisabledReason.upstreamFlowUnavailable)
        // A machine token, never user-facing copy — the kit ships no localized
        // strings, so the shell maps this to catalog copy.
        #expect(ChatGPTConnector.disabledReason.contains(" ") == false)
    }

    @Test("An unconfigured connector answers the signed-in gate without a request")
    func signedInGateCostsNothing() async {
        let transport = FakeTokenTransport()
        let absent = ChatGPTConnectorFixture.connector(transport: transport, token: "   ")
        #expect(await absent.isSignedIn() == false)

        let present = ChatGPTConnectorFixture.connector(transport: transport)
        #expect(await present.isSignedIn())

        // An injected gate wins over the token provider — that is the shell's
        // cheap `engine.hasStoredCredentials()` path.
        let gated = ChatGPTConnector(
            bearerToken: { ChatGPTFixture.accessToken },
            signedIn: { false },
            transport: transport
        )
        #expect(await gated.isSignedIn() == false)
        #expect(await transport.recordedRequests.isEmpty)
    }

    @Test("The base URL is the ChatGPT backend, never the platform API host")
    func baseURLIsTheSubscriptionBackend() {
        #expect(ChatGPTConnector.baseURLString == "https://chatgpt.com/backend-api/codex")
        // api.openai.com serves platform API keys; a subscription token is not
        // accepted there, which is why this is a separate connector.
        #expect(ChatGPTConnector.baseURLString.contains("api.openai.com") == false)
    }
}

@Suite("ChatGPTConnectorConfigurationTests")
struct ChatGPTConnectorConfigurationTests {
    @Test("An unconfigured connector performs zero transport calls")
    func unconfiguredConnectorNeverTouchesTheNetwork() async throws {
        let transport = FakeTokenTransport()
        let connector = ChatGPTConnectorFixture.connector(transport: transport, token: "   ")

        await #expect(throws: ConnectorFailure.unconfigured) { try await connector.listModels() }
        await #expect(throws: ConnectorFailure.unconfigured) {
            try await connector.completion(instructions: "i", prompt: "p", model: "m")
        }
        #expect(await transport.recordedRequests.isEmpty)
    }

    @Test("A throwing token provider reads as unconfigured, and a ConnectorFailure passes through")
    func tokenProviderFailuresMapOntoTheTaxonomy() async throws {
        struct Unset: Error {}
        let unset = ChatGPTConnector(bearerToken: { throw Unset() }, transport: FakeTokenTransport())
        await #expect(throws: ConnectorFailure.unconfigured) { try await unset.listModels() }

        let expired = ChatGPTConnector(
            bearerToken: { throw ConnectorFailure.authExpired },
            transport: FakeTokenTransport()
        )
        await #expect(throws: ConnectorFailure.authExpired) { try await expired.listModels() }
    }

    @Test("The account header is derived from the token's own claims")
    func accountHeaderIsDerivedFromTheToken() async throws {
        let transport = FakeTokenTransport([.success(ChatGPTConnectorFixture.reply("ok"))])
        let connector = ChatGPTConnectorFixture.connector(
            transport: transport,
            token: ChatGPTFixture.identityToken()
        )
        _ = try await connector.completion(instructions: "i", prompt: "p", model: "gpt-fixture")

        #expect(await transport.recordedHeader("ChatGPT-Account-Id", at: 0) == ChatGPTFixture.accountID)
    }

    @Test("An explicit account override wins, and an opaque token simply omits the header")
    func accountHeaderOverrideAndOmission() async throws {
        let overridden = FakeTokenTransport([.success(ChatGPTConnectorFixture.reply("ok"))])
        let connector = ChatGPTConnectorFixture.connector(
            transport: overridden,
            token: ChatGPTFixture.identityToken(),
            accountID: { "acct-override-beta" }
        )
        _ = try await connector.completion(instructions: "i", prompt: "p", model: "gpt-fixture")
        #expect(await overridden.recordedHeader("ChatGPT-Account-Id", at: 0) == "acct-override-beta")

        // An opaque credential omits the header and lets the backend decide,
        // which beats refusing to call at all.
        let opaque = FakeTokenTransport([.success(ChatGPTConnectorFixture.reply("ok"))])
        let fallback = ChatGPTConnectorFixture.connector(transport: opaque)
        _ = try await fallback.completion(instructions: "i", prompt: "p", model: "gpt-fixture")
        #expect(await opaque.recordedHeader("ChatGPT-Account-Id", at: 0) == nil)
    }
}

@Suite("ChatGPTConnectorModelListTests")
struct ChatGPTConnectorModelListTests {
    @Test("Models are parsed from the data/id shape")
    func modelsParseFromTheDataShape() async throws {
        let transport = FakeTokenTransport([
            .success(ChatGPTConnectorFixture.json(
                "{\"data\":[{\"id\":\"gpt-fixture-max\"},{\"id\":\"gpt-fixture-mini\"}]}"
            )),
        ])
        let models = try await ChatGPTConnectorFixture.connector(transport: transport).listModels()

        #expect(models.map(\.id) == ["gpt-fixture-max", "gpt-fixture-mini"])
        // `client_version` is REQUIRED and gates the catalog — see
        // `ChatGPTStreamingTests`, which owns that measurement.
        #expect(await transport.recordedRequests.first?.url?.absoluteString
            == "https://chatgpt.com/backend-api/codex/models?client_version="
            + ChatGPTConnector.catalogClientVersion)
        #expect(await transport.recordedHeader("Authorization", at: 0) == "Bearer \(ChatGPTFixture.accessToken)")
    }

    @Test("Models are parsed from the models/slug shape too")
    func modelsParseFromTheSlugShape() async throws {
        let transport = FakeTokenTransport([
            .success(ChatGPTConnectorFixture.json("{\"models\":[{\"slug\":\"gpt-fixture-sol\"},{\"slug\":\"\"}]}")),
        ])
        let models = try await ChatGPTConnectorFixture.connector(transport: transport).listModels()
        #expect(models.map(\.id) == ["gpt-fixture-sol"])
    }

    @Test("An endpoint-shape drift is a malformedResponse, never an empty catalog and never a crash")
    func endpointShapeDriftMapsToMalformedResponse() async throws {
        // Each of these is a plausible way the undocumented catalog endpoint
        // could drift. Reporting zero models instead would be indistinguishable,
        // in the selector, from an account that genuinely has none.
        let drifted = [
            "{\"object\":\"list\",\"items\":[{\"id\":\"gpt-fixture\"}]}",
            "{\"data\":{\"id\":\"gpt-fixture\"}}",
            "[{\"id\":\"gpt-fixture\"}]",
            "<!DOCTYPE html><html>Attention Required! | Cloudflare</html>",
            "",
        ]
        for body in drifted {
            let transport = FakeTokenTransport([.success(ChatGPTConnectorFixture.json(body))])
            await #expect(throws: ConnectorFailure.malformedResponse) {
                try await ChatGPTConnectorFixture.connector(transport: transport).listModels()
            }
        }
    }

    @Test("A recognised shape with no entries is an empty list, not a failure")
    func recognisedEmptyCatalogIsNotAFailure() async throws {
        let transport = FakeTokenTransport([.success(ChatGPTConnectorFixture.json("{\"data\":[]}"))])
        #expect(try await ChatGPTConnectorFixture.connector(transport: transport).listModels().isEmpty)
    }
}

@Suite("ChatGPTConnectorCompletionTests")
struct ChatGPTConnectorCompletionTests {
    @Test("A structured call sends the Responses-API text.format json_schema envelope")
    func structuredCallSendsTheTextFormatEnvelope() async throws {
        let transport = FakeTokenTransport([.success(ChatGPTConnectorFixture.reply("{\"genres\":[\"jazz\"]}"))])
        _ = try await ChatGPTConnectorFixture.connector(transport: transport).structuredCompletion(
            schema: ChatGPTConnectorFixture.schema,
            instructions: "emit json",
            prompt: "late night",
            model: "gpt-fixture-max"
        )

        let body = try #require(await transport.recordedBody(0))
        // The constraint rides `text.format`, NOT `response_format` — that is
        // the Chat Completions dialect and a 400 here.
        #expect(body.contains("\"text\":{\"format\":{"))
        #expect(body.contains("\"response_format\"") == false)
        #expect(body.contains("\"type\":\"json_schema\""))
        #expect(body.contains("\"name\":\"playlist_query\""))
        #expect(body.contains("\"strict\":true"))
        #expect(body.contains("\"additionalProperties\":false"))
        #expect(body.contains("\"store\":false"))
        // `stream: true` is MANDATORY on this backend since 2026-09-06 — a
        // non-streaming request is `{"detail":"Stream must be set to true"}`.
        #expect(body.contains("\"stream\":true"))
        #expect(await transport.recordedRequests.first?.url?.absoluteString
            == "https://chatgpt.com/backend-api/codex/responses")
    }

    @Test("A plain completion omits the format envelope and trims the answer")
    func plainCompletionOmitsTheEnvelope() async throws {
        let transport = FakeTokenTransport([.success(ChatGPTConnectorFixture.reply("\n  Midnight Drive  \n"))])
        let text = try await ChatGPTConnectorFixture.connector(transport: transport).completion(
            instructions: "name it",
            prompt: "late night",
            model: "gpt-fixture-max"
        )

        #expect(text == "Midnight Drive")
        let body = try #require(await transport.recordedBody(0))
        // The `text` KEY still appears inside every input content item, so the
        // absence assertion has to name the format envelope specifically.
        #expect(body.contains("\"text\":{\"format\"") == false)
        #expect(body.contains("json_schema") == false)
        #expect(body.contains("\"input\":[{\"content\":[{\"text\":\"late night\",\"type\":\"input_text\"}]"))
    }

    @Test("The output_text convenience field is read when present")
    func outputTextConvenienceFieldIsRead() async throws {
        let transport = FakeTokenTransport([
            .success(ChatGPTConnectorFixture.json("{\"output_text\":\"Midnight Drive\",\"output\":[]}")),
        ])
        let text = try await ChatGPTConnectorFixture.connector(transport: transport).completion(
            instructions: "i", prompt: "p", model: "m"
        )
        #expect(text == "Midnight Drive")
    }

    @Test("Prose-wrapped JSON is recovered by brace counting, nested objects included")
    func proseWrappedJSONIsRecovered() async throws {
        // `strict` has never fully closed the "model adds a preamble" failure
        // mode, and recovering costs nothing. The nested object and the brace
        // inside a string literal are both here on purpose: a first-closing-brace
        // scan would truncate the first and a naive one would end early on the
        // second.
        let wrapped = "Sure! Here you go:\n{\"genres\":[\"{jazz\"],\"range\":{\"low\":1}}\nHope that helps."
        let transport = FakeTokenTransport([.success(ChatGPTConnectorFixture.reply(wrapped))])
        let data = try await ChatGPTConnectorFixture.connector(transport: transport).structuredCompletion(
            schema: ChatGPTConnectorFixture.schema,
            instructions: "i",
            prompt: "p",
            model: "m"
        )

        let decoded = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(decoded["genres"] as? [String] == ["{jazz"])
        #expect((decoded["range"] as? [String: Any])?["low"] as? Int == 1)
    }

    @Test("A response with no JSON object at all is a malformedResponse")
    func structuredCallWithoutJSONIsMalformed() async throws {
        let transport = FakeTokenTransport([.success(ChatGPTConnectorFixture.reply("I cannot help with that."))])
        await #expect(throws: ConnectorFailure.malformedResponse) {
            try await ChatGPTConnectorFixture.connector(transport: transport).structuredCompletion(
                schema: ChatGPTConnectorFixture.schema,
                instructions: "i",
                prompt: "p",
                model: "m"
            )
        }
    }

    @Test("A reply whose shape drifted is a malformedResponse, never a crash")
    func replyShapeDriftMapsToMalformedResponse() async throws {
        let drifted = [
            "{\"choices\":[{\"message\":{\"content\":\"hi\"}}]}",
            "{\"output\":[{\"type\":\"message\",\"content\":[]}]}",
            "{\"output\":[]}",
            "event: response.completed\ndata: {\"type\":\"response.completed\"}\n\n",
        ]
        for body in drifted {
            let transport = FakeTokenTransport([.success(ChatGPTConnectorFixture.json(body))])
            await #expect(throws: ConnectorFailure.malformedResponse) {
                try await ChatGPTConnectorFixture.connector(transport: transport).completion(
                    instructions: "i", prompt: "p", model: "m"
                )
            }
        }
    }
}
