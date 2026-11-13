// MCPHTTPFramingTests — the hand-rolled HTTP/1.1 wire, driven without a socket.
//
// The framer is the one piece of this wave with no library behind it, so it is the
// one piece that gets exhaustive unit coverage. Every case here is a real thing a
// peer does: TCP splits a request across reads, a client pipelines two, a hostile
// peer never sends the blank line, a well-meaning one sends chunked.
import Foundation
@testable import MacAMP
import Testing

@Suite("MCP HTTP framing")
struct MCPHTTPFramingTests {
    private static func request(
        method: String = "POST",
        target: String = "/mcp",
        headers: [String] = ["Host: 127.0.0.1:46114", "Content-Type: application/json"],
        body: String = ""
    ) -> Data {
        var text = "\(method) \(target) HTTP/1.1\r\n"
        for header in headers {
            text += header + "\r\n"
        }
        text += "Content-Length: \(body.utf8.count)\r\n\r\n\(body)"
        return Data(text.utf8)
    }

    // MARK: Reassembly

    @Test("a request split one byte per read yields exactly one frame, at the last byte")
    func partialReadsReassemble() throws {
        var parser = MCPHTTPRequestParser()
        let bytes = Array(Self.request(body: #"{"jsonrpc":"2.0"}"#))
        var produced: [MCPHTTPRequestHead] = []
        for (index, byte) in bytes.enumerated() {
            let heads = try parser.append(Data([byte]))
            produced += heads
            // Nothing may be produced before the final byte lands.
            #expect(heads.isEmpty || index == bytes.count - 1)
        }
        #expect(produced.count == 1)
        #expect(produced.first?.method == "POST")
        #expect(produced.first?.target == "/mcp")
        #expect(produced.first?.body == Data(#"{"jsonrpc":"2.0"}"#.utf8))
    }

    @Test("two pipelined requests in ONE read produce TWO frames, in order")
    func pipeliningProducesEveryFrame() throws {
        var parser = MCPHTTPRequestParser()
        var buffer = Self.request(body: #"{"id":1}"#)
        buffer.append(Self.request(method: "DELETE", body: ""))
        let heads = try parser.append(buffer)
        #expect(heads.count == 2)
        #expect(heads.map(\.method) == ["POST", "DELETE"])
        #expect(heads.first?.body == Data(#"{"id":1}"#.utf8))
        #expect(heads.last?.body.isEmpty == true)
    }

    @Test("a frame that arrives after a partial one is still parsed from the same buffer")
    func aSplitBoundaryDoesNotLoseTheSecondFrame() throws {
        var parser = MCPHTTPRequestParser()
        var buffer = Self.request(body: #"{"id":1}"#)
        let second = Self.request(body: #"{"id":2}"#)
        buffer.append(second.prefix(10))
        #expect(try parser.append(buffer).count == 1)
        #expect(try parser.append(second.dropFirst(10)).count == 1)
    }

    // MARK: Refusals

    @Test("headers that never terminate are refused once past the ceiling, with 431")
    func oversizedHeadersAreRefused() {
        var parser = MCPHTTPRequestParser()
        let filler = Data(String(repeating: "x", count: MCPHTTPRequestParser.maximumHeaderBytes + 1).utf8)
        #expect(throws: MCPHTTPParseFailure.headersTooLarge) {
            _ = try parser.append(filler)
        }
        #expect(MCPHTTPParseFailure.headersTooLarge.status == 431)
    }

    @Test("a chunked request is refused rather than guessed at")
    func chunkedRequestsAreRefused() {
        var parser = MCPHTTPRequestParser()
        let raw = Data("POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)
        #expect(throws: MCPHTTPParseFailure.chunkedRequestUnsupported) {
            _ = try parser.append(raw)
        }
    }

    @Test("a body past the ceiling is refused before a byte of it is buffered, with 413")
    func oversizedBodiesAreRefused() {
        var parser = MCPHTTPRequestParser()
        let length = MCPHTTPRequestParser.maximumBodyBytes + 1
        let raw = Data("POST /mcp HTTP/1.1\r\nContent-Length: \(length)\r\n\r\n".utf8)
        #expect(throws: MCPHTTPParseFailure.bodyTooLarge) {
            _ = try parser.append(raw)
        }
        #expect(MCPHTTPParseFailure.bodyTooLarge.status == 413)
    }

    @Test("a request line that is not a request line is refused")
    func malformedRequestLinesAreRefused() {
        var parser = MCPHTTPRequestParser()
        #expect(throws: MCPHTTPParseFailure.malformedRequestLine) {
            _ = try parser.append(Data("HELLO\r\n\r\n".utf8))
        }
    }

    @Test("a header with no colon is refused")
    func malformedHeadersAreRefused() {
        var parser = MCPHTTPRequestParser()
        #expect(throws: MCPHTTPParseFailure.malformedHeader) {
            _ = try parser.append(Data("GET /mcp HTTP/1.1\r\nnonsense\r\n\r\n".utf8))
        }
    }

    // MARK: Header semantics

    @Test("header lookup is case-insensitive through the transport request, query stripped from the path")
    func headersAndPathReachTheTransport() throws {
        var parser = MCPHTTPRequestParser()
        let raw = Data("GET /mcp?x=1 HTTP/1.1\r\nMCP-SESSION-ID: abc\r\n\r\n".utf8)
        let head = try #require(try parser.append(raw).first)
        #expect(head.target == "/mcp?x=1")
        #expect(head.transportRequest.path == "/mcp")
        #expect(head.transportRequest.header("Mcp-Session-Id") == "abc")
        // An empty body reaches the transport as nil, not as zero bytes.
        #expect(head.transportRequest.body == nil)
    }

    // MARK: Responses

    @Test("a length-framed response carries Content-Length and keeps the connection")
    func framedResponsesAreComplete() throws {
        let body = Data(#"{"ok":true}"#.utf8)
        let bytes = MCPHTTPResponseWriter.framed(
            status: 200,
            headers: ["Content-Type": "application/json"],
            body: body
        )
        let text = try #require(String(bytes: bytes, encoding: .utf8))
        #expect(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(text.contains("Content-Length: \(body.count)\r\n"))
        #expect(text.contains("Connection: keep-alive\r\n"))
        #expect(text.hasSuffix("\r\n\r\n" + #"{"ok":true}"#))
    }

    @Test("a bodyless response still states a zero length, so a client does not wait")
    func bodylessResponsesStateZeroLength() throws {
        let bytes = MCPHTTPResponseWriter.framed(status: 202, headers: [:], body: nil)
        let text = try #require(String(bytes: bytes, encoding: .utf8))
        #expect(text.hasPrefix("HTTP/1.1 202 Accepted\r\n"))
        #expect(text.contains("Content-Length: 0\r\n"))
    }

    @Test("an SSE response is chunked, never length-framed, and terminates")
    func streamResponsesAreChunked() throws {
        let head = try #require(String(
            bytes: MCPHTTPResponseWriter.chunkedHead(status: 200, headers: ["Content-Type": "text/event-stream"]),
            encoding: .utf8
        ))
        #expect(head.contains("Transfer-Encoding: chunked\r\n"))
        #expect(!head.contains("Content-Length"))

        let payload = Data("data: hi\n\n".utf8)
        let chunk = try #require(String(bytes: MCPHTTPResponseWriter.chunk(payload), encoding: .utf8))
        #expect(chunk == "a\r\ndata: hi\n\n\r\n")
        #expect(MCPHTTPResponseWriter.chunk(Data()).isEmpty)
        #expect(MCPHTTPResponseWriter.terminator == Data("0\r\n\r\n".utf8))
    }
}
