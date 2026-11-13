// MCPHTTPFraming — the HTTP/1.1 wire under the MCP transport, hand-rolled and PURE.
//
// The SDK's HTTP server transports are framework-agnostic by design: they consume
// an `HTTPRequest` and produce an `HTTPResponse`, and the socket layer is ours to
// supply. This file IS that layer's grammar, with no `Network` import anywhere —
// which is what lets every framing rule below (partial reads, pipelining, the
// header ceiling, a refused chunked upload) be driven by an ordinary unit test
// instead of by opening a port.
//
// The subset is deliberately only what MCP's streamable HTTP speaks:
//
//   * REQUESTS are `Content-Length`-framed. A chunked request is REFUSED rather
//     than guessed at — no MCP client sends one, and a decoder written for a
//     shape nobody exercises is a decoder that is wrong in the dark.
//   * RESPONSES are `Content-Length`-framed, except an SSE stream, which is
//     `Transfer-Encoding: chunked`. Chunked rather than body-until-EOF so the
//     connection survives the stream and a pipelining client is never punished
//     for reusing it.
import Foundation
import MCP

/// A parsed request line plus headers plus body, as values.
///
/// Not `MCP.HTTPRequest` directly because that type is not `Equatable`, and the
/// whole point of this layer is that a test can state the expected frame.
struct MCPHTTPRequestHead: Equatable {
    var method: String
    /// The request target as written, query string included.
    var target: String
    var headers: [String: String]
    var body: Data

    /// The transport's own request shape. `path` drops the query: the validators
    /// that read it match on `/mcp` and `/.well-known/…`, never on parameters.
    var transportRequest: HTTPRequest {
        HTTPRequest(
            method: method,
            headers: headers,
            body: body.isEmpty ? nil : body,
            path: target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? target
        )
    }
}

enum MCPHTTPParseFailure: Error, Equatable {
    case malformedRequestLine
    case malformedHeader
    case headersTooLarge
    case bodyTooLarge
    case chunkedRequestUnsupported
}

/// Incremental HTTP/1.1 request framing over a byte stream that arrives in
/// arbitrary pieces.
///
/// `append` returns EVERY complete request the buffer now holds, so a single read
/// carrying two pipelined POSTs yields two — dropping the second (the naive
/// "parse one frame per read" shape) loses a request with no error anywhere.
struct MCPHTTPRequestParser {
    /// A ceiling on the head, not on the request: a peer that never sends the
    /// blank line would otherwise grow this buffer without bound.
    static let maximumHeaderBytes = 16 * 1024
    /// Every MCP body is a JSON-RPC message. A megabyte is orders of magnitude
    /// past the largest one this server can provoke.
    static let maximumBodyBytes = 1024 * 1024

    private static let headerTerminator = Data("\r\n\r\n".utf8)

    private var buffer = Data()

    mutating func append(_ bytes: Data) throws -> [MCPHTTPRequestHead] {
        buffer.append(bytes)
        var parsed: [MCPHTTPRequestHead] = []
        while let head = try parseOne() {
            parsed.append(head)
        }
        return parsed
    }

    private mutating func parseOne() throws -> MCPHTTPRequestHead? {
        guard let terminator = buffer.firstRange(of: Self.headerTerminator) else {
            guard buffer.count <= Self.maximumHeaderBytes else { throw MCPHTTPParseFailure.headersTooLarge }
            return nil
        }
        let headBytes = buffer[buffer.startIndex ..< terminator.lowerBound]
        guard headBytes.count <= Self.maximumHeaderBytes else { throw MCPHTTPParseFailure.headersTooLarge }

        var head = try Self.parseHead(headBytes)
        guard head.headers.first(where: { $0.key.lowercased() == "transfer-encoding" }) == nil else {
            throw MCPHTTPParseFailure.chunkedRequestUnsupported
        }
        let length = try Self.contentLength(head.headers)

        let bodyStart = terminator.upperBound
        guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= length else { return nil }
        let bodyEnd = buffer.index(bodyStart, offsetBy: length)
        head.body = Data(buffer[bodyStart ..< bodyEnd])
        buffer.removeSubrange(buffer.startIndex ..< bodyEnd)
        return head
    }

    private static func contentLength(_ headers: [String: String]) throws -> Int {
        guard let raw = headers.first(where: { $0.key.lowercased() == "content-length" })?.value else { return 0 }
        guard let length = Int(raw.trimmingCharacters(in: .whitespaces)), length >= 0 else {
            throw MCPHTTPParseFailure.malformedHeader
        }
        guard length <= maximumBodyBytes else { throw MCPHTTPParseFailure.bodyTooLarge }
        return length
    }

    /// The request line and headers only. `body` is EMPTY and invalid until the
    /// caller fills it from the bytes after the terminator.
    private static func parseHead(_ bytes: some DataProtocol) throws -> MCPHTTPRequestHead {
        guard let text = String(bytes: bytes, encoding: .utf8) else { throw MCPHTTPParseFailure.malformedRequestLine }
        var lines = text.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { throw MCPHTTPParseFailure.malformedRequestLine }

        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count >= 3, requestLine[2].hasPrefix("HTTP/") else {
            throw MCPHTTPParseFailure.malformedRequestLine
        }

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let separator = line.firstIndex(of: ":") else { throw MCPHTTPParseFailure.malformedHeader }
            let name = String(line[line.startIndex ..< separator]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { throw MCPHTTPParseFailure.malformedHeader }
            headers[name] = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
        }
        return MCPHTTPRequestHead(
            method: String(requestLine[0]),
            target: String(requestLine[1]),
            headers: headers,
            body: Data()
        )
    }
}

/// Serialises an `HTTPResponse` back onto the wire.
enum MCPHTTPResponseWriter {
    /// The head plus the whole body, for every response that knows its length.
    static func framed(status: Int, headers: [String: String], body: Data?) -> Data {
        var response = head(
            status: status,
            headers: headers.merging(["Content-Length": String(body?.count ?? 0)]) { _, new in new }
        )
        if let body { response.append(body) }
        return response
    }

    /// The head of a `Transfer-Encoding: chunked` response. Every subsequent
    /// ``chunk(_:)`` is one frame; ``terminator`` ends the body and frees the
    /// connection for the next request.
    static func chunkedHead(status: Int, headers: [String: String]) -> Data {
        var merged = headers
        merged.removeValue(forKey: "Content-Length")
        merged["Transfer-Encoding"] = "chunked"
        return head(status: status, headers: merged)
    }

    static func chunk(_ payload: Data) -> Data {
        guard !payload.isEmpty else { return Data() }
        var framed = Data(String(format: "%llx\r\n", UInt64(payload.count)).utf8)
        framed.append(payload)
        framed.append(Data("\r\n".utf8))
        return framed
    }

    static var terminator: Data {
        Data("0\r\n\r\n".utf8)
    }

    private static func head(status: Int, headers: [String: String]) -> Data {
        var text = "HTTP/1.1 \(status) \(reason(status))\r\n"
        var merged = headers
        merged["Connection"] = "keep-alive"
        for name in merged.keys.sorted() {
            text += "\(name): \(merged[name] ?? "")\r\n"
        }
        text += "\r\n"
        return Data(text.utf8)
    }

    /// Only the codes this server can actually emit. An unlisted one still frames
    /// correctly — the reason phrase is advisory, and no client parses it.
    private static let reasonPhrases: [Int: String] = [
        200: "OK",
        202: "Accepted",
        400: "Bad Request",
        403: "Forbidden",
        404: "Not Found",
        405: "Method Not Allowed",
        406: "Not Acceptable",
        409: "Conflict",
        413: "Content Too Large",
        415: "Unsupported Media Type",
        421: "Misdirected Request",
        431: "Request Header Fields Too Large",
        500: "Internal Server Error",
    ]

    private static func reason(_ status: Int) -> String {
        reasonPhrases[status] ?? "Error"
    }
}

extension MCPHTTPParseFailure {
    /// The status this refusal is answered with before the connection is dropped.
    var status: Int {
        switch self {
        case .headersTooLarge: 431
        case .bodyTooLarge: 413
        case .malformedRequestLine, .malformedHeader, .chunkedRequestUnsupported: 400
        }
    }
}
