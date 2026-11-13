// MCPClientManager — one external MCP server's connection, for the lifetime of a
// chat surface.
//
// ── ONE MANAGER PER SERVER, AND IT OWNS THE CONNECTION ───────────────────────
//
// An `MCP.Client` is bound to exactly one transport and refuses a second
// `initialize`, so "one client per server" is the SDK's shape, not a preference.
// The manager adds the three things the SDK deliberately leaves to its embedder:
// a deadline, a reconnect policy, and a failure taxonomy that renders.
//
// ── RECONNECT-ON-DEMAND, NEVER RECONNECT-ON-A-TIMER ──────────────────────────
//
// There is no keepalive and no retry loop. Every entry point calls
// ``connect()``, which is a no-op when a live client exists and builds one when it
// does not; every failure tears the client down so the NEXT call rebuilds it. A
// stdio server is a CHILD PROCESS, so an eager reconnect policy would respawn a
// program on the listener's Mac in the background, on a schedule they never asked
// for. Work happens when the model calls a tool, or not at all.
//
// ── WHY THE DEADLINE IS NOT `withDeadline(seconds:operation:)` ───────────────
//
// The kit's helper is correct for a COOPERATIVE operation and documents that it
// hangs on one that parks in a continuation it never resumes. `Client`'s requests
// are exactly that shape, verified in the pinned 0.12.1 source: `sendAndAwait`
// awaits an UNSTRUCTURED `Task`'s value, and the continuation inside it is only
// resumed by an inbound response, by `cancelRequest`, or by `disconnect()`.
// Cancelling the awaiting task moves nothing. So the deadline here does not just
// race — it ACTS: on expiry it disconnects the client, which the SDK resumes every
// pending continuation from, and only then can the race's losing child finish.
// Tearing down is also the honest state to be left in: a server that blew a 30 s
// budget has told us nothing about what it is still doing.
//
// ── SECRETS ──────────────────────────────────────────────────────────────────
//
// Nothing here reads an environment VALUE. The descriptor carries key NAMES, the
// transport factory resolves them, and no failure payload in ``MCPClientFailure``
// has a field one could be written into.
import AIConnectorKit
import Foundation
import MCP

/// A live connection to one external MCP server.
public actor MCPClientManager {
    /// Builds the transport for a descriptor. Injected so tests can hand over an
    /// `InMemoryTransport` and the shell can hand over an HTTP or child-process
    /// one without this type learning either.
    public typealias TransportFactory = @Sendable (MCPServerDescriptor) async throws -> any Transport

    /// Seconds one connect, list or call may take.
    ///
    /// Generous next to `URLSessionTransport`'s 20 s because an MCP tool is
    /// frequently a web search or a shell-out, and short enough that a wedged
    /// server cannot hold a chat turn open past what a listener would tolerate.
    public static let callTimeoutSeconds: TimeInterval = 30

    /// The client name this app introduces itself to servers with.
    public static let defaultClientName = "MacAMP"

    /// The server this manager speaks to. `nonisolated` so a shell can read the
    /// name for a status row without awaiting a possibly-busy actor.
    public nonisolated let descriptor: MCPServerDescriptor

    private let clientName: String
    private let clientVersion: String
    private let timeoutSeconds: TimeInterval
    private let makeTransport: TransportFactory

    private var client: Client?
    private var publishedNames: Set<String> = []

    public init(
        descriptor: MCPServerDescriptor,
        clientName: String = MCPClientManager.defaultClientName,
        clientVersion: String = "1.0",
        timeoutSeconds: TimeInterval = MCPClientManager.callTimeoutSeconds,
        transportFactory: @escaping TransportFactory
    ) {
        self.descriptor = descriptor
        self.clientName = clientName
        self.clientVersion = clientVersion
        self.timeoutSeconds = timeoutSeconds
        makeTransport = transportFactory
    }

    // MARK: - Lifecycle

    /// Connects and completes the `initialize` handshake, or does nothing when a
    /// live client already exists.
    @discardableResult
    public func connect() async throws -> Client {
        if let client { return client }
        let fresh = Client(name: clientName, version: clientVersion)
        do {
            let transport = try await makeTransport(descriptor)
            try await bounded(
                unblock: { await fresh.disconnect() },
                operation: { _ = try await fresh.connect(transport: transport) }
            )
        } catch {
            await fresh.disconnect()
            throw mapped(error, fallingBackTo: MCPClientFailure.DiagnosticToken.handshakeFailed)
        }
        client = fresh
        return fresh
    }

    /// Drops the connection. A stdio transport terminates its child here.
    public func disconnect() async {
        guard let live = client else { return }
        client = nil
        publishedNames = []
        await live.disconnect()
    }

    // MARK: - Tools

    /// What the server publishes, connecting first if needed.
    public func listTools() async throws -> [MCP.Tool] {
        let live = try await connect()
        do {
            let tools = try await bounded(
                unblock: { await live.disconnect() },
                operation: { try await live.listTools().tools }
            )
            publishedNames = Set(tools.map(\.name))
            return tools
        } catch {
            await disconnect()
            throw mapped(error, fallingBackTo: MCPClientFailure.DiagnosticToken.connectionClosed)
        }
    }

    /// Runs one tool by the server's OWN name — never a projected `mcp__` name.
    ///
    /// - Parameter argumentsJSON: The model's raw argument text. `""` and `"{}"`
    ///   are both accepted spellings of "no arguments"; two of the four provider
    ///   wire formats emit the former.
    public func callTool(name: String, argumentsJSON: String) async throws -> String {
        let live = try await connect()
        if publishedNames.isEmpty == false, publishedNames.contains(name) == false {
            throw MCPClientFailure.unknownTool(name: name)
        }
        let arguments = Self.arguments(from: argumentsJSON)
        do {
            let content = try await bounded(
                unblock: { await live.disconnect() },
                operation: { try await live.callTool(name: name, arguments: arguments).content }
            )
            return Self.text(from: content)
        } catch {
            await disconnect()
            throw mapped(error, fallingBackTo: MCPClientFailure.DiagnosticToken.connectionClosed)
        }
    }

    /// This server's tools, namespaced, budgeted and quarantine-framed.
    ///
    /// The returned tools hold the manager WEAKLY: a stdio server is a child
    /// process, and an abandoned tool array must not be able to keep one alive.
    public func projectedTools() async throws -> [AITool] {
        let published = try await listTools()
        return MCPToolProjection.tools(
            serverName: descriptor.name,
            published: published
        ) { [weak self] remoteName, argumentsJSON in
            guard let self else {
                throw MCPClientFailure.unreachable(
                    underlying: MCPClientFailure.DiagnosticToken.connectionClosed
                )
            }
            return try await callTool(name: remoteName, argumentsJSON: argumentsJSON)
        }
    }
}

// MARK: - Deadline

private extension MCPClientManager {
    /// Runs `operation` under this manager's budget, calling `unblock` on expiry.
    ///
    /// `unblock` exists because the loser of a task-group race is still awaited at
    /// scope exit — see the file header. It must be something that makes a parked
    /// SDK continuation resume; in practice that is `Client.disconnect()`.
    func bounded<Value: Sendable>(
        unblock: @escaping @Sendable () async -> Void,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let seconds = timeoutSeconds
        let expiry = ExpiryFlag()
        do {
            return try await withThrowingTaskGroup(of: Value?.self) { group in
                group.addTask { try await operation() }
                group.addTask {
                    try? await Task.sleep(for: .seconds(seconds))
                    guard Task.isCancelled == false else { return nil }
                    await expiry.trip()
                    await unblock()
                    return nil
                }
                while let next = try await group.next() {
                    guard let value = next else { continue }
                    group.cancelAll()
                    return value
                }
                throw MCPClientFailure.timeout
            }
        } catch {
            if await expiry.didExpire { throw MCPClientFailure.timeout }
            throw error
        }
    }
}

/// Whether the deadline fired, readable after the race has been unwound.
private actor ExpiryFlag {
    private(set) var didExpire = false

    func trip() {
        didExpire = true
    }
}

// MARK: - Payload conversion

private extension MCPClientManager {
    /// The model's argument text as MCP values, or `nil` for an argument-less call.
    static func arguments(from argumentsJSON: String) -> [String: MCP.Value]? {
        let trimmed = argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false,
              let value = try? JSONDecoder().decode(MCP.Value.self, from: Data(trimmed.utf8)),
              case let .object(object) = value,
              object.isEmpty == false
        else { return nil }
        return object
    }

    /// A tool result's content as the one string a model can read.
    ///
    /// Non-text parts are NAMED, never inlined: a base64 image is thousands of
    /// characters of budget the model cannot see anyway, and a resource blob is
    /// somebody else's bytes arriving in a text channel.
    static func text(from content: [MCP.Tool.Content]) -> String {
        content.map { part in
            switch part {
            case let .text(text, _, _): text
            case .image: "[image content omitted]"
            case .audio: "[audio content omitted]"
            case .resource: "[resource content omitted]"
            case .resourceLink: "[resource link omitted]"
            }
        }.joined(separator: "\n")
    }
}

// MARK: - Failure mapping

private extension MCPClientManager {
    /// Every error this module can see, reduced to the taxonomy that renders.
    ///
    /// - Parameter fallingBackTo: The ``MCPClientFailure/DiagnosticToken`` for an
    ///   error the SDK did not raise — a transport factory's own failure, say.
    func mapped(_ error: any Error, fallingBackTo token: String) -> MCPClientFailure {
        if let failure = error as? MCPClientFailure { return failure }
        if error is CancellationError { return .cancelled }
        guard let mcpError = error as? MCPError else { return .unreachable(underlying: token) }
        switch mcpError {
        case .connectionClosed, .internalError:
            // `internalError` is the SDK's spelling for every "there is no live
            // connection" case: "Client disconnected", "Transport not connected",
            // "Transport not paired". All of them mean unreachable, not malformed.
            return .unreachable(underlying: MCPClientFailure.DiagnosticToken.connectionClosed)
        case .transportError:
            return .unreachable(underlying: MCPClientFailure.DiagnosticToken.transportFailure)
        case .parseError:
            return .protocolViolation(underlying: MCPClientFailure.DiagnosticToken.malformedPayload)
        case .invalidRequest, .invalidParams, .methodNotFound, .serverError, .urlElicitationRequired:
            return .protocolViolation(underlying: MCPClientFailure.DiagnosticToken.handshakeFailed)
        }
    }
}
