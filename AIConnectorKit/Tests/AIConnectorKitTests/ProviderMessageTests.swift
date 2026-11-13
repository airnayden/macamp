// ProviderMessageTests — the one payload of a failure a listener is allowed to read.
//
// `ConnectorFailure.httpStatus`'s `providerMessage` is the exception to that type's
// "nothing here is user-facing" rule, so its extraction is pinned twice over: once
// end-to-end through a real connector and a scripted transport, which is what
// actually reaches a failure banner, and once directly against the shared helper for
// the shapes a connector cannot conveniently be driven into.
//
// The measured case behind all of this: Claude answered a chat turn with an HTTP 400
// whose `error.message` said exactly what was wrong with the request, and the shell
// rendered "This provider answered with an error (400)." and dropped the sentence.
import AIConnectorKit
import Foundation
import Testing

@Suite("ProviderMessageTests")
struct ProviderMessageTests {
    private static func connector(_ status: Int, body: String) -> AnthropicConnector {
        AnthropicConnector(
            auth: .apiKey(provider: { "sk-ant-api03-test-key" }),
            transport: FakeHTTPTransport(scripts: [
                .success(HTTPResponse(statusCode: status, body: Data(body.utf8))),
            ])
        )
    }

    /// Drives a real connector to a real thrown failure and hands back the one field.
    private static func thrownProviderMessage(status: Int = 400, body: String) async throws -> String? {
        do {
            _ = try await connector(status, body: body).listModels()
            Issue.record("a \(status) must throw")
            return nil
        } catch let failure as ConnectorFailure {
            guard case let .httpStatus(_, _, providerMessage) = failure else {
                Issue.record("expected .httpStatus, got \(failure)")
                return nil
            }
            return providerMessage
        }
    }

    // MARK: - End to end, through a connector

    @Test("A provider's own error.message reaches the thrown failure")
    func aProviderErrorMessageReachesTheThrownFailure() async throws {
        let body = "{\"error\":{\"type\":\"invalid_request_error\",\"message\":\"Error\"}}"
        let message = try await Self.thrownProviderMessage(body: body)
        #expect(message == "Error")
    }

    @Test("An overlong provider sentence is capped rather than dropped")
    func anOverlongProviderSentenceIsCapped() async throws {
        let overlong = String(repeating: "e", count: 300)
        let message = try await Self.thrownProviderMessage(body: "{\"error\":{\"message\":\"\(overlong)\"}}")
        #expect(message?.count == 200)
        #expect(message == String(repeating: "e", count: 200))
        #expect(message?.count == ConnectorFailure.maxProviderMessageCharacters)
    }

    @Test("The ChatGPT backend's top-level detail sentence reaches the thrown failure")
    func aDetailSentenceReachesTheThrownFailure() async throws {
        // The codex backend's FastAPI dialect, measured 2026-09-09. Before this
        // fallback its "Unsupported parameter: max_output_tokens" reached a
        // listener as a bare "(400)" — the exact sentence that would have named
        // the bug was extracted to nil.
        let message = try await Self.thrownProviderMessage(
            body: "{\"detail\":\"Unsupported parameter: max_output_tokens\"}"
        )
        #expect(message == "Unsupported parameter: max_output_tokens")
    }

    @Test("A body with no error.message and no detail leaves the failure with nothing to show")
    func aBodyWithoutAnErrorMessageShowsNothing() async throws {
        // Every shape that is NOT a displayable sentence: a string-valued `error`,
        // a top-level message, a non-string `detail`, and a body that is not JSON.
        for body in [
            "{\"error\":\"upstream\"}",
            "{\"message\":\"upstream\"}",
            "{\"detail\":{\"reason\":\"nested\"}}",
            "{\"detail\":42}",
            "<html>502 Bad Gateway</html>",
        ] {
            let message = try await Self.thrownProviderMessage(status: 502, body: body)
            #expect(message == nil, "\(body) has no displayable sentence")
        }
    }

    // MARK: - The shared helper, directly

    @Test("The sentence is trimmed, and a blank one reads as absent")
    func theSentenceIsTrimmedAndBlankReadsAsAbsent() {
        let padded = ConnectorFailure.sanitizedProviderMessage(
            in: Data("{\"error\":{\"message\":\"  max_tokens: 8192 > 4096  \\n\"}}".utf8)
        )
        #expect(padded == "max_tokens: 8192 > 4096")

        for blank in ["\"\"", "\"   \"", "\"\\n\\t\""] {
            let message = ConnectorFailure.sanitizedProviderMessage(
                in: Data("{\"error\":{\"message\":\(blank)}}".utf8)
            )
            #expect(message == nil, "a blank message is not a sentence")
        }
    }

    @Test("A non-string error.message is not coerced into one")
    func aNonStringErrorMessageIsNotCoerced() {
        // A provider that answers with a structured `message` gets nothing rendered
        // rather than a `String(describing:)` of its JSON.
        for shape in ["42", "null", "{\"text\":\"nested\"}", "[\"a\",\"b\"]"] {
            let message = ConnectorFailure.sanitizedProviderMessage(
                in: Data("{\"error\":{\"message\":\(shape)}}".utf8)
            )
            #expect(message == nil, "\(shape) is not a sentence")
        }
    }

    @Test("Empty bytes are answered with nothing, not with a crash")
    func emptyBytesAreAnsweredWithNothing() {
        #expect(ConnectorFailure.sanitizedProviderMessage(in: Data()) == nil)
    }
}
