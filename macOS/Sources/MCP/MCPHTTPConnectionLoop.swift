// MCPHTTPConnectionLoop — one TCP connection, read to write, and the (`Server`,
// `StatelessHTTPServerTransport`) pair that answers on it.
//
// The pair is built HERE rather than shared, for the two SDK reasons recorded in
// ``MCPServerFactory``: a `Server` refuses a second `initialize`, and a stateless
// transport's response waiters are keyed by the client's own JSON-RPC id. Both
// hazards need two clients to reach; a connection-scoped pair means there is only
// ever one. It costs two handler registrations and a receive task per connection,
// and buys a listener with no cross-client state whatsoever.
//
// Deliberately free functions on an enum rather than an actor: a connection has no
// state worth isolating beyond its parser and its pair, which are locals.
//
// Two framing facts are load-bearing:
//
//   * A response with a known length is written whole with `Content-Length` and the
//     connection is KEPT — which is what makes a pipelined pair of requests answer
//     twice instead of once.
//   * The `.stream` branch is UNREACHABLE with the stateless transport, which never
//     returns SSE. It is kept because `HTTPResponse` can express it and the framer
//     is a total HTTP/1.1 responder — three lines that keep `write` exhaustive
//     rather than a `default:` that would silently mis-frame a future response.
import Foundation
import MCP
import Network

enum MCPHTTPConnectionLoop {
    /// One read is at most this many bytes. The parser reassembles, so the value
    /// trades syscalls against peak buffer, nothing else.
    static let readChunkBytes = 64 * 1024

    static func run(connection: NWConnection, source: MCPToolboxSource, port: Int) async {
        defer { connection.cancel() }
        let transport = MCPServerFactory.transport(port: port)
        let server = await MCPServerFactory.make(source: source)
        do {
            try await server.start(transport: transport)
        } catch {
            try? await refuse(on: connection)
            return
        }
        await serve(connection: connection, transport: transport)
        await server.stop()
    }

    private static func serve(connection: NWConnection, transport: StatelessHTTPServerTransport) async {
        var parser = MCPHTTPRequestParser()
        while !Task.isCancelled {
            let received: (data: Data?, isComplete: Bool)
            do {
                received = try await receive(on: connection)
            } catch {
                return
            }
            if let data = received.data, !data.isEmpty {
                let heads: [MCPHTTPRequestHead]
                do {
                    heads = try parser.append(data)
                } catch let failure as MCPHTTPParseFailure {
                    try? await refuse(failure, on: connection)
                    return
                } catch {
                    return
                }
                for head in heads {
                    let response = await transport.handleRequest(head.transportRequest)
                    do {
                        try await write(response, to: connection)
                    } catch {
                        return
                    }
                }
            }
            if received.isComplete { return }
        }
    }
}

// MARK: - Wire

private extension MCPHTTPConnectionLoop {
    static func receive(on connection: NWConnection) async throws -> (Data?, Bool) {
        try await withCheckedThrowingContinuation { continuation in
            connection
                .receive(minimumIncompleteLength: 1, maximumLength: readChunkBytes) { data, _, isComplete, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: (data, isComplete))
                    }
                }
        }
    }

    static func send(_ payload: Data, on connection: NWConnection) async throws {
        guard !payload.isEmpty else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: payload, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    static func write(_ response: HTTPResponse, to connection: NWConnection) async throws {
        guard case let .stream(events, headers) = response else {
            try await send(
                MCPHTTPResponseWriter.framed(
                    status: response.statusCode,
                    headers: response.headers,
                    body: response.bodyData
                ),
                on: connection
            )
            return
        }
        try await send(
            MCPHTTPResponseWriter.chunkedHead(status: response.statusCode, headers: headers),
            on: connection
        )
        for try await event in events {
            try await send(MCPHTTPResponseWriter.chunk(event), on: connection)
        }
        try await send(MCPHTTPResponseWriter.terminator, on: connection)
    }

    /// A framing refusal is answered before the connection is dropped, because a
    /// silently closed socket is indistinguishable from a crash at the other end.
    static func refuse(_ failure: MCPHTTPParseFailure, on connection: NWConnection) async throws {
        try await send(
            MCPHTTPResponseWriter.framed(
                status: failure.status,
                headers: ["Content-Type": "text/plain; charset=utf-8"],
                body: Data("\(failure)\n".utf8)
            ),
            on: connection
        )
    }

    /// The same courtesy when the pair itself could not be started: say so, rather
    /// than hanging up on a client that would otherwise wait for a response.
    static func refuse(on connection: NWConnection) async throws {
        try await send(
            MCPHTTPResponseWriter.framed(
                status: 500,
                headers: ["Content-Type": "text/plain; charset=utf-8"],
                body: Data("could not start an MCP server for this connection\n".utf8)
            ),
            on: connection
        )
    }
}
