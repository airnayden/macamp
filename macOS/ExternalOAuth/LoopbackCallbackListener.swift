// LoopbackCallbackListener — the one-shot socket that catches an OAuth redirect.
//
// ── WHY THIS EXISTS AT ALL ────────────────────────────────────────────────────
//
// Claude's flow redirects to a HOSTED page that displays a pasteable `code#state`
// line, so ``ClaudeSignInModel`` needs no listener. ChatGPT's does not: its
// `redirect_uri` is `http://localhost:1455/auth/callback`, registered server-side,
// and the authorize endpoint will only ever redirect a browser THERE. Without
// something bound to that port the browser lands on a connection error and the
// listener has no way to complete a login.
//
// ── WHY RAW POSIX AND NOT `NWListener` ────────────────────────────────────────
//
// The port choice must be SYNCHRONOUS and exact. Only 1455 and 1457 survive the
// provider's exact-match check on `redirect_uri`, so "1455, else 1457, else fail"
// has to be decided before the browser is opened. `bind(2)` reports `EADDRINUSE`
// immediately; `NWListener` reports the same condition asynchronously through its
// state handler, which would mean opening the browser and only then discovering
// the socket never came up. Thirty lines of `bind`/`listen`/`accept` buy a
// deterministic answer, and the request being parsed is a single HTTP GET line.
//
// ── SECURITY POSTURE ──────────────────────────────────────────────────────────
//
//   * BOUND TO 127.0.0.1, NEVER `INADDR_ANY`. Nothing off this machine can reach
//     it, which matters because the thing it receives is an authorization code.
//   * ONE REQUEST, THEN CLOSED. The socket exists for the seconds between opening
//     the browser and the redirect arriving, and ``cancel()`` closes it on every
//     other path — abandonment, failure, timeout, sheet dismissal.
//   * NOTHING IS LOGGED. The captured URL carries the code and the state; it goes
//     straight to the flow's exchange and is never rendered.
//   * THE `state` CHECK IS THE FLOW'S JOB, NOT THIS TYPE'S. Anything on this Mac
//     can connect to a loopback port, so a callback arriving here proves nothing
//     about who sent it — ``ChatGPTOAuthFlow/exchange(callbackURL:request:)``
//     refuses a foreign `state` before any network call.
import Darwin
import Foundation

/// Accepts exactly one HTTP request on a loopback port and reports its URL.
actor LoopbackCallbackListener {
    enum Failure: Error, Equatable {
        /// Neither registered port could be bound.
        case noPortAvailable
        /// ``cancel()`` was called before a callback arrived.
        case cancelled
        /// Something connected but did not send a parseable HTTP request line.
        case malformedRequest
    }

    /// The port actually bound. `nonisolated` so a caller can read it without an
    /// `await` while building the authorize URL that must name the same one.
    nonisolated let port: Int

    private let socketDescriptor: Int32
    private var isClosed = false
    private var isClosedByCancellation = false

    private init(socketDescriptor: Int32, port: Int) {
        self.socketDescriptor = socketDescriptor
        self.port = port
    }

    /// Binds the first available port, in order.
    ///
    /// - Throws: ``Failure/noPortAvailable`` when every candidate is taken. That is
    ///   a real dead end rather than a reason to pick a free port: an unregistered
    ///   `redirect_uri` is refused by the authorize endpoint.
    static func bind(preferredPorts: [Int]) throws -> LoopbackCallbackListener {
        for candidate in preferredPorts {
            guard let descriptor = makeBoundSocket(port: candidate) else { continue }
            return LoopbackCallbackListener(socketDescriptor: descriptor, port: candidate)
        }
        throw Failure.noPortAvailable
    }

    /// Waits for the redirect and returns the URL the browser asked for.
    ///
    /// The blocking `accept(2)` runs on a detached task, so the actor is not held
    /// during the wait and ``cancel()`` can still run — which is what unblocks it.
    func waitForCallback() async throws -> URL {
        let descriptor = socketDescriptor
        let boundPort = port
        let captured = await Task.detached(priority: .userInitiated) {
            LoopbackCallbackListener.acceptOneRequest(on: descriptor, port: boundPort)
        }.value
        close()
        if isClosedByCancellation { throw Failure.cancelled }
        guard let captured else { throw Failure.malformedRequest }
        return captured
    }

    /// Closes the socket, failing any wait in progress.
    func cancel() {
        isClosedByCancellation = true
        close()
    }

    private func close() {
        guard isClosed == false else { return }
        isClosed = true
        // `shutdown` first so a thread parked in `accept(2)` wakes immediately;
        // `close` alone is not guaranteed to unblock it on Darwin.
        shutdown(socketDescriptor, SHUT_RDWR)
        Darwin.close(socketDescriptor)
    }
}

// MARK: - Socket

private extension LoopbackCallbackListener {
    /// A listening socket on `127.0.0.1:port`, or `nil` when the port is taken.
    static func makeBoundSocket(port: Int) -> Int32? {
        guard let portNumber = UInt16(exactly: port) else { return nil }
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }

        var reuse: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = portNumber.bigEndian
        // LOOPBACK, never INADDR_ANY: the payload is an authorization code.
        address.sin_addr.s_addr = in_addr_t(INADDR_LOOPBACK).bigEndian

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(descriptor, 1) == 0 else {
            Darwin.close(descriptor)
            return nil
        }
        return descriptor
    }

    /// One `accept` → parse → reply → close cycle.
    static func acceptOneRequest(on descriptor: Int32, port: Int) -> URL? {
        let connection = accept(descriptor, nil, nil)
        guard connection >= 0 else { return nil }
        defer { Darwin.close(connection) }
        let target = readRequestTarget(connection)
        let url = target.flatMap { URL(string: "http://localhost:\(port)\($0)") }
        send(page: CallbackPage.html(succeeded: url != nil), to: connection)
        return url
    }

    /// The request-target out of `GET /auth/callback?code=…&state=… HTTP/1.1`.
    ///
    /// Only the first line is read. Headers and body are irrelevant — the payload
    /// of an authorization-code redirect is entirely in the query string — and
    /// reading past the line would mean handling `Content-Length` for nothing.
    static func readRequestTarget(_ connection: Int32) -> String? {
        var buffer = [UInt8](repeating: 0, count: 8192)
        var filled = 0
        while filled < buffer.count {
            let read = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.read(connection, base.advanced(by: filled), raw.count - filled)
            }
            guard read > 0 else { break }
            filled += read
            // A partial read can split a multi-byte sequence, so a failed decode is
            // "keep reading", never an error.
            guard let text = String(bytes: buffer[0 ..< filled], encoding: .utf8) else { continue }
            if let line = text.components(separatedBy: "\r\n").first, text.contains("\r\n") {
                return requestTarget(inLine: line)
            }
        }
        return nil
    }

    static func requestTarget(inLine line: String) -> String? {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0] == "GET", parts[1].hasPrefix("/") else { return nil }
        return String(parts[1])
    }

    static func send(page: String, to connection: Int32) {
        let body = Data(page.utf8)
        let header = """
        HTTP/1.1 200 OK\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(body.count)\r
        Connection: close\r
        \r

        """
        var payload = Data(header.utf8)
        payload.append(body)
        payload.withUnsafeBytes { raw in
            guard var base = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                let written = Darwin.write(connection, base, remaining)
                guard written > 0 else { return }
                remaining -= written
                base = base.advanced(by: written)
            }
        }
        shutdown(connection, SHUT_WR)
    }
}

// MARK: - Browser page

/// The page the browser lands on after the redirect.
///
/// Localized like any other user-facing copy — it is read by the same person who
/// is looking at the app, and the zero-hardcoded-text rule does not stop at the
/// window edge. Resolved with `String(localized:)` because this string becomes
/// bytes on a socket, not a SwiftUI `Text`.
enum CallbackPage {
    static func html(succeeded: Bool) -> String {
        let title = String(localized: succeeded
            ? ExternalOAuthStrings.chatGPTCallbackSuccessTitle
            : ExternalOAuthStrings.chatGPTCallbackFailureTitle)
        let body = String(localized: succeeded
            ? ExternalOAuthStrings.chatGPTCallbackSuccessBody
            : ExternalOAuthStrings.chatGPTCallbackFailureBody)
        return """
        <!DOCTYPE html>
        <html lang="en"><head><meta charset="utf-8"><title>\(escaped(title))</title></head>
        <body style="font-family:-apple-system,system-ui,sans-serif;padding:3rem;text-align:center">
        <h1>\(escaped(title))</h1><p>\(escaped(body))</p></body></html>
        """
    }

    /// Minimal HTML escaping. The inputs are catalog strings rather than anything
    /// a remote party controls, but a translator writing `&` or `<` must not be
    /// able to produce broken markup.
    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
