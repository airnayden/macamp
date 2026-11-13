// ChatGPTResponseMapping.swift — the connector's JSON coding and its non-2xx
// failure taxonomy, split out of `ChatGPTConnector.swift`.
//
// Split for one mechanical reason: `.swiftlint.yml` does not override
// `file_length`, so SwiftLint's 400-line ceiling applies and CI runs `--strict`.
// The 2026-08-24 determination rewrite pushed `ChatGPTConnector.swift` past it,
// and this is the block with no dependencies on the rest of the type. Same
// precedent as `ChatGPTWireTypes.swift` and `AnthropicWireTypes.swift`.
//
// The mapping here is where the connector's ONE non-obvious response rule lives:
// a Cloudflare managed challenge and an expired session are both HTTP 403, and
// only one of them is fixed by signing in again.
import AIConnectorKit
import Foundation

// MARK: - Coding

extension ChatGPTConnector {
    /// `.sortedKeys` makes the body BYTE-STABLE, which is what lets the
    /// recorded-request assertions compare exact strings.
    static func encode(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            return try encoder.encode(value)
        } catch {
            throw ConnectorFailure.malformedResponse
        }
    }

    static func decode<Value: Decodable>(_ data: Data) throws -> Value {
        do {
            return try JSONDecoder().decode(Value.self, from: data)
        } catch {
            throw ConnectorFailure.malformedResponse
        }
    }
}

// MARK: - Failure mapping

extension ChatGPTConnector {
    /// Maps a non-2xx answer onto the taxonomy.
    ///
    /// The bot-mitigation check runs FIRST and wins over the 403 → `.authExpired`
    /// rule, because the two are indistinguishable by status alone and only one
    /// of them is fixed by signing in again.
    static func validate(_ response: HTTPResponse) throws {
        guard response.isSuccess == false else { return }
        if isBotMitigated(response) {
            throw ConnectorFailure.unreachable(underlying: botMitigationToken)
        }
        switch response.statusCode {
        case 401, 403:
            throw ConnectorFailure.authExpired
        case 429:
            throw ConnectorFailure.rateLimited(retryAfter: retryAfter(in: response))
        default:
            throw ConnectorFailure.httpStatus(
                response.statusCode,
                body: diagnosticBody(response.body),
                providerMessage: ConnectorFailure.sanitizedProviderMessage(in: response.body)
            )
        }
    }

    /// Cloudflare labels a managed challenge with `cf-mitigated: challenge`, and
    /// serves HTML where JSON was asked for. Either signal is enough.
    static func isBotMitigated(_ response: HTTPResponse) -> Bool {
        if response.headerValue("cf-mitigated")?.isEmpty == false {
            return true
        }
        guard response.statusCode == 403 else { return false }
        return response.headerValue("Content-Type")?.contains("text/html") == true
    }

    /// How long until the quota resets, from the header if the provider sent one
    /// and from the body if it did not.
    ///
    /// An HTTP-date `Retry-After` reads as absent: the taxonomy wants a duration,
    /// and deriving one from a possibly skewed clock is worse than `nil`.
    ///
    /// THE BODY FALLBACK IS NOT DEFENSIVE — MEASURED 2026-09-06. This backend
    /// answers a spent subscription quota with a 429 that carries NO
    /// `Retry-After` at all and puts the duration in the payload instead:
    /// `{"error":{"type":"usage_limit_reached","plan_type":"plus",
    /// "resets_at":…,"resets_in_seconds":52532}}`. ``streamFailure(in:)`` already
    /// reads that same field for the MID-stream form of the same condition,
    /// under a comment requiring both paths to produce the same
    /// ``ConnectorFailure``; reading only the header here broke that invariant
    /// and reported one quota as two different failures.
    ///
    /// The header still wins when present — a provider that states a duration
    /// explicitly outranks one inferred from an error payload.
    static func retryAfter(in response: HTTPResponse) -> TimeInterval? {
        if let header = response.headerValue("Retry-After").flatMap(TimeInterval.init) {
            return header
        }
        guard let payload = AIJSONValue.decoded(from: response.body) else { return nil }
        return streamError(in: payload)?[StreamKey.resetsInSeconds]?.numberValue
    }

    /// A truncated copy of a FAILING response body, for diagnosis only. Response
    /// side ONLY — the request, and therefore the bearer token, never reaches a
    /// ``ConnectorFailure`` payload.
    static func diagnosticBody(_ body: Data) -> String? {
        guard let text = String(bytes: body, encoding: .utf8), text.isEmpty == false else { return nil }
        guard text.count > maxDiagnosticBodyLength else { return text }
        return String(text.prefix(maxDiagnosticBodyLength))
    }
}
