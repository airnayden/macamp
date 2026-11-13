// WebSearchTool+Wire — the request this tool writes, the rows it renders back, and
// the sentence every failure becomes.
//
// A separate FILE rather than more of `WebSearchTool.swift`: SwiftLint's 400-line
// `file_length` ceiling is a real one at `--strict`, and this is the same split
// `AnthropicConnector` / `AnthropicConnector+ToolLoop` already uses. Everything
// here is a PURE FUNCTION of its inputs — no transport, no credential, no clock —
// so the whole render-and-failure contract is testable without a socket.
import Foundation

// MARK: - Request

extension WebSearchTool {
    static func urlRequest(for arguments: Arguments, apiKey: String?) throws -> URLRequest {
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        if let apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        } else {
            request.setValue(keylessHeaderValue, forHTTPHeaderField: keylessHeaderField)
        }
        do {
            request.httpBody = try payload(for: arguments).encodedData()
        } catch {
            // Unreachable with the shape below — `JSONEncoder` only throws on
            // non-finite numbers, which this body cannot contain. Mapped rather
            // than trapped so a future schema change degrades instead of crashing.
            throw ConnectorFailure.malformedResponse
        }
        return request
    }

    /// `include_domains` is omitted rather than sent empty: a null or empty filter
    /// is a 400 on more than one search API.
    static func payload(for arguments: Arguments) -> AIJSONValue {
        .object([
            "query": .string(arguments.query),
            "max_results": .int(arguments.maxResults),
            "include_domains": arguments.site.map { .array([.string($0)]) },
        ])
    }
}

// MARK: - Rendering

extension WebSearchTool {
    static func output(for response: HTTPResponse) -> AIToolOutput {
        guard response.isSuccess else {
            return AIToolOutput(text: failureSentence(for: response))
        }
        guard let results = AIJSONValue.decoded(from: response.body)?["results"]?.arrayValue else {
            return AIToolOutput(text: Sentence.unrecognisedProviderError)
        }
        let rows = results.compactMap(row(from:))
        guard rows.isEmpty == false else {
            return AIToolOutput(text: Sentence.noResults, resultCount: 0)
        }
        return AIToolOutput(text: clamp(rows.joined(separator: "\n")), resultCount: rows.count)
    }

    /// One hit as `title — url — snippet`, or `nil` when it carries no URL.
    ///
    /// A hit with nothing to open is not worth a row: the URL is the only field a
    /// listener — or the link enricher downstream — can act on. Present fields are
    /// joined and absent ones simply left out, so a title-less hit reads as a URL
    /// and its snippet rather than as a row of empty separators.
    static func row(from value: AIJSONValue) -> String? {
        let url = flattened(value["url"]?.stringValue ?? "")
        guard url.isEmpty == false else { return nil }
        let title = elide(flattened(value["title"]?.stringValue ?? ""), to: titleCharacterLimit)
        let snippet = elide(flattened(value["content"]?.stringValue ?? ""), to: snippetCharacterLimit)
        return [title, url, snippet].filter { $0.isEmpty == false }.joined(separator: " — ")
    }

    /// `text` with every whitespace and control scalar collapsed to single spaces,
    /// trimmed. The defence against a snippet forging its own rows — see
    /// `WebSearchTool.swift`'s header.
    static func flattened(_ text: String) -> String {
        let separated = text.unicodeScalars.map { scalar -> Character in
            CharacterSet.whitespacesAndNewlines.contains(scalar) || CharacterSet.controlCharacters.contains(scalar)
                ? " "
                : Character(scalar)
        }
        return String(separated).split(separator: " ").joined(separator: " ")
    }

    /// `text` cut to `limit`, ellipsis included in the count.
    static func elide(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit - 1)) + "…"
    }

    /// `text` cut to ``WebSearchTool/resultCharacterLimit``, ``WebSearchTool/truncationMarker``
    /// included in the count so the clamp is a ceiling and not a ceiling-plus-a-bit.
    static func clamp(_ text: String) -> String {
        guard text.count > resultCharacterLimit else { return text }
        return String(text.prefix(resultCharacterLimit - truncationMarker.count)) + truncationMarker
    }
}

// MARK: - Failure mapping

extension WebSearchTool {
    /// The four statuses worth distinguishing. A TABLE rather than a switch: the
    /// mapping is data, and everything absent from it is the catch-all by
    /// construction rather than by remembering to write a `default:`.
    static let statusSentences: [Int: String] = [
        401: Sentence.keyRejected,
        429: Sentence.rateLimited,
        432: Sentence.planLimitReached,
        433: Sentence.payAsYouGoLimitReached,
    ]

    static let retryAfterHeaderField = "Retry-After"

    /// The key a provider error code is read from, wherever in the body it sits.
    static let errorCodeKey = "code"

    /// How deep the tolerant search for that key goes. Providers nest it under
    /// `detail` or `error`; nobody nests it four levels down.
    static let errorCodeSearchDepth = 3

    static func failureSentence(for response: HTTPResponse) -> String {
        var sentence = statusSentences[response.statusCode] ?? Sentence.unrecognisedProviderError
        if let retryAfter = retryAfterSeconds(in: response) {
            sentence += " Retry in \(retryAfter) seconds."
        }
        if let code = errorCode(in: response.body) {
            sentence += " (provider code: \(code))"
        }
        return sentence
    }

    /// The `Retry-After` hint, only when it is a plain integer count of seconds.
    ///
    /// Round-tripping through `Int` is what makes provider-controlled header text
    /// safe to repeat back to the model.
    static func retryAfterSeconds(in response: HTTPResponse) -> Int? {
        guard let raw = response.headerValue(retryAfterHeaderField),
              let seconds = Int(raw.trimmingCharacters(in: .whitespaces)),
              seconds >= 0
        else { return nil }
        return seconds
    }

    /// The provider's own error code, flattened and clamped, or `nil`.
    static func errorCode(in body: Data) -> String? {
        guard let value = AIJSONValue.decoded(from: body),
              let raw = errorCode(in: value, depth: 0)
        else { return nil }
        let code = elide(flattened(raw), to: errorCodeCharacterLimit)
        return code.isEmpty ? nil : code
    }

    /// Keys are visited in sorted order so a body carrying two codes still produces
    /// one stable sentence rather than a different one per run.
    private static func errorCode(in value: AIJSONValue, depth: Int) -> String? {
        guard depth <= errorCodeSearchDepth, let object = value.objectValue else { return nil }
        if let scalar = object[errorCodeKey], let text = scalarText(scalar) { return text }
        for key in object.keys.sorted() {
            guard let nested = object[key], let found = errorCode(in: nested, depth: depth + 1) else { continue }
            return found
        }
        return nil
    }

    private static func scalarText(_ value: AIJSONValue) -> String? {
        if let text = value.stringValue { return text }
        if let number = value.intValue { return String(number) }
        return nil
    }

    /// The transport taxonomy, as sentences. Exhaustive with no `default:` — see
    /// ``ConnectorFailure``'s header for why that is the point.
    static func sentence(for failure: ConnectorFailure) -> String {
        switch failure {
        case .timeout: Sentence.timedOut
        case .unreachable: Sentence.unreachable
        case .cancelled: Sentence.cancelled
        case .unconfigured, .authExpired: Sentence.keyRejected
        case .rateLimited: Sentence.rateLimited
        case .httpStatus, .malformedResponse, .truncated: Sentence.unrecognisedProviderError
        }
    }
}
