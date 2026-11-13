// MCPLibraryServer — the loopback socket the MCP transport sits on.
//
// ── THE BIND IS THE SECURITY BOUNDARY ────────────────────────────────────────
//
// `requiredLocalEndpoint` is 127.0.0.1, so this listener is never reachable from
// the LAN — not "unlikely to be", not "firewalled": the socket is bound to the
// loopback interface and nothing else can route to it. (`acceptLocalOnly` is set
// beside it as belt-and-braces; it bounds the LINK, which is strictly weaker, so
// the loopback bind is the boundary.) That is why there is no auth token here.
// A second layer, `OriginValidator.localhost(port:)`, is the first validator in
// the transport's pipeline (``MCPServerFactory/transport(port:)``) and refuses a
// DNS-rebinding attempt from a browser that CAN reach loopback — before any tool
// runs and before the library is read.
//
// ── NO SILENT FALLBACK PORT ──────────────────────────────────────────────────
//
// `allowLocalEndpointReuse` is deliberately FALSE and the configured port is the
// only one tried. A busy port surfaces as ``MCPServerStatus/portUnavailable`` in
// the Preferences status row. Quietly moving to another port would mean the
// number on screen is not the number a client must connect to — and the recorded
// OAuth-listener learning (ai-fixes-round2, wave B) is the same lesson from the
// other side: a port choice a human has to act on must be reported, not guessed.
//
// ── NOTHING HERE MAKES AN OUTBOUND REQUEST ───────────────────────────────────
//
// This is the only `Network` use in the AI surface and it is INBOUND ONLY: a
// listener, its accepted connections, and no `NWConnection` this process ever
// initiates. `scripts/check-ai-network-boundary.sh` looks for `URLSession` (the
// outbound transport) and finds none, which stays true by construction.
import Foundation
import Network
import os

/// What the listener is actually doing, as one value the pane can render.
enum MCPServerStatus: Equatable {
    case stopped
    case running(port: Int)
    /// The configured port is taken — by another app, or by a second copy of this one.
    case portUnavailable(port: Int)
    case failed(reason: String)
}

protocol MCPExternalAccessServing: Actor {
    var status: MCPServerStatus { get }
    func start(port: Int, source: MCPToolboxSource) async -> MCPServerStatus
    func stop() async
    func setFailureHandler(_ handler: @escaping @Sendable () async -> Void)
}

actor MCPLibraryServer: MCPExternalAccessServing {
    /// The shipped default. Inside the IANA dynamic range (49152 is the formal
    /// floor, but 46114 is above every registered service and below the ephemeral
    /// range macOS actually allocates from), so a collision needs another app to
    /// have chosen the same arbitrary number.
    static let defaultPort = 46114

    private(set) var status: MCPServerStatus = .stopped

    private var failureHandler: (@Sendable () async -> Void)?

    func setFailureHandler(_ handler: @escaping @Sendable () async -> Void) {
        failureHandler = handler
    }

    private let queue = DispatchQueue(label: "com.example.macamp.mcp.listener", qos: .userInitiated)
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    /// Binds the port and starts serving. Idempotent by teardown: an already
    /// running listener is stopped first, so a port change is one call.
    @discardableResult
    func start(port: Int, source: MCPToolboxSource) async -> MCPServerStatus {
        await stop()
        guard let rawPort = UInt16(exactly: port), let endpointPort = NWEndpoint.Port(rawValue: rawPort),
              rawPort > 0
        else {
            status = .failed(reason: "port \(port) is not a usable TCP port")
            return status
        }

        let listener: NWListener
        do {
            // NO `on:` argument — `requiredLocalEndpoint` already names the host AND
            // the port, and supplying both is `EINVAL`.
            listener = try NWListener(using: Self.loopbackParameters(port: endpointPort))
        } catch {
            status = Self.status(for: error, port: port)
            return status
        }

        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection, source: source, port: port) }
        }

        switch await ready(listener) {
        case .ready:
            self.listener = listener
            observeFailure(of: listener)
            status = .running(port: port)
        case let .failed(error):
            listener.cancel()
            status = Self.status(for: error, port: port)
        default:
            listener.cancel()
            status = .failed(reason: "the listener did not come up")
        }
        return status
    }

    /// Releases the port and drops every connection. Cancelling a connection ends
    /// the read its loop is parked on, and the loop stops its own `Server` on the
    /// way out — so there is nothing session-shaped left to tear down here.
    func stop() async {
        listener?.newConnectionHandler = nil
        listener?.stateUpdateHandler = nil
        listener?.cancel()
        listener = nil
        for connection in connections.values {
            connection.cancel()
        }
        connections.removeAll()
        status = .stopped
    }

    /// Live accepted connections. Each owns one `MCP.Server`; there are no sessions.
    func connectionCount() -> Int {
        connections.count
    }
}

// MARK: - Listener plumbing

private extension MCPLibraryServer {
    static func loopbackParameters(port: NWEndpoint.Port) -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
        // FALSE on purpose — see this file's header. Reuse would let a second
        // instance bind the same port and split traffic between two libraries.
        parameters.allowLocalEndpointReuse = false
        parameters.acceptLocalOnly = true
        parameters.includePeerToPeer = false
        (parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)?.noDelay = true
        return parameters
    }

    /// The first terminal state the listener reaches. `stateUpdateHandler` fires
    /// repeatedly, so the continuation is guarded by a lock rather than by hope.
    func ready(_ listener: NWListener) async -> NWListener.State {
        let queue = queue
        return await withCheckedContinuation { (continuation: CheckedContinuation<NWListener.State, Never>) in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready, .failed, .cancelled:
                    let isFirst = resumed.withLock { done in
                        defer { done = true }
                        return !done
                    }
                    if isFirst { continuation.resume(returning: state) }
                case .setup, .waiting:
                    break
                @unknown default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    /// Keeps reporting after start-up: a listener can fail later (the interface
    /// goes away), and a status row that froze at `.running` would be a lie.
    func observeFailure(of listener: NWListener) {
        listener.stateUpdateHandler = { [weak self] state in
            guard case let .failed(error) = state else { return }
            Task { await self?.note(error) }
        }
    }

    func note(_ error: NWError) async {
        guard case let .running(port) = status else { return }
        status = Self.status(for: error, port: port)
        await stop()
        status = Self.status(for: error, port: port)
        await failureHandler?()
    }

    static func status(for error: some Error, port: Int) -> MCPServerStatus {
        if case let .posix(code) = error as? NWError, code == .EADDRINUSE || code == .EADDRNOTAVAIL {
            return .portUnavailable(port: port)
        }
        return .failed(reason: String(describing: error))
    }

    func accept(_ connection: NWConnection, source: MCPToolboxSource, port: Int) {
        connections[ObjectIdentifier(connection)] = connection
        connection.start(queue: queue)
        Task { [weak self] in
            await MCPHTTPConnectionLoop.run(connection: connection, source: source, port: port)
            await self?.forget(connection)
        }
    }

    func forget(_ connection: NWConnection) {
        connections.removeValue(forKey: ObjectIdentifier(connection))
    }
}
