// Fakes for the bridge's tool-loop suites.
//
// ``FakeToolPublisher`` stands in for `LibraryToolbox` — see
// `LibraryToolAdapterTests`' header for why a real one is the wrong instrument
// here. It records the tier every call was routed at and which argument keys
// survived decoding, which is the whole of what the adapter is responsible for.
//
// ``ScriptedToolConnector`` stands in for a provider on the far side of
// ``ConnectorChatEngine``, so the composition can be asserted without a
// transport.
import AIConnectorBridge
import AIConnectorKit
import Foundation
import Services

// MARK: - Toolbox

struct FakeToolCall: Equatable {
    let name: String
    let profile: ToolProfile
    /// Argument keys that survived decoding, sorted so the assertion is stable.
    let keys: [String]
}

final class FakeToolPublisher: LibraryToolPublishing, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [FakeToolCall] = []
    private let published: [ToolProfile: [LibraryTool]]
    private let answers: [String: String]
    /// The `resultCount` each named tool reports. Absent means not list-shaped.
    private let resultCounts: [String: Int]
    /// The structured rows each named tool answers with, pre-truncation, exactly
    /// as `LibraryToolbox.runResult` hands them over.
    private let rows: [String: [ToolResultRow]]

    init(
        published: [ToolProfile: [LibraryTool]],
        answers: [String: String],
        resultCounts: [String: Int] = [:],
        rows: [String: [ToolResultRow]] = [:]
    ) {
        self.published = published
        self.answers = answers
        self.resultCounts = resultCounts
        self.rows = rows
    }

    var calls: [FakeToolCall] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func tools(profile: ToolProfile) -> [LibraryTool] {
        published[profile] ?? []
    }

    func runResult(_ name: String, arguments: ToolArguments, profile: ToolProfile) async -> ToolRunOutcome {
        // Via a SYNCHRONOUS helper: `NSLock.lock()` is unavailable from an async
        // context, and `runResult` is a protocol requirement, so it cannot be an
        // actor.
        record(FakeToolCall(name: name, profile: profile, keys: arguments.values.keys.sorted()))
        return ToolRunOutcome(
            text: answers[name] ?? "ran \(name)",
            resultCount: resultCounts[name],
            rows: rows[name] ?? []
        )
    }

    private func record(_ call: FakeToolCall) {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(call)
    }

    /// Two tools with REAL `ToolSchema` documents, and an `.onDevice` tier that
    /// publishes a strict subset — mirroring `LibraryToolbox`'s own five-library-tool
    /// on-device rule so the adapter cannot pass by hardcoding one tier's list.
    static func standard() -> FakeToolPublisher {
        let search = LibraryTool(
            name: "search_tracks",
            description: "Finds tracks.",
            parametersSchema: ToolSchema.object(
                [
                    ToolSchema.Property("query", ToolSchema.string("What to search for.")),
                    ToolSchema.Property("limit", ToolSchema.integer("How many rows.", minimum: 1, maximum: 200)),
                ],
                required: ["query"]
            ),
            execute: { _ in ToolResult.message("unused: the adapter routes through `run`") }
        )
        let genres = LibraryTool(
            name: "list_genres",
            description: "Lists the library's genres.",
            parametersSchema: ToolSchema.noArguments,
            execute: { _ in ToolResult.message("unused: the adapter routes through `run`") }
        )
        return FakeToolPublisher(
            published: [
                .cloud: [search, genres],
                .external: [search, genres],
                .onDevice: [search],
            ],
            answers: [:]
        )
    }
}

// MARK: - Row payloads

/// The payload SHAPES `ToolboxRendering` really writes, so the adapter's
/// projection is asserted against the JSON one layer down rather than against a
/// shape invented here.
///
/// Four of the seven shapes are enough to drive both gates: one that is a track,
/// one that is a miss, one the SHAPE gate rejects, and one only the ALLOW-LIST
/// can reject.
enum ToolRowFixture {
    static func track(id: Int64, title: String, artist: String) -> ToolResultRow {
        ToolResultRow(
            text: "\(title) — \(artist)",
            payload: .object([
                "id": .int(id),
                "title": .string(title),
                "artist": .string(artist),
                "album": .string("An Album"),
                "durationSeconds": .number(210),
                "availability": .string("present"),
            ])
        )
    }

    /// `match_tracks`' not-found row: a `kind` of `miss`, and no library id.
    static func miss(title: String, artist: String) -> ToolResultRow {
        ToolResultRow(
            text: "\(title) — \(artist) (not found)",
            payload: .object([
                "kind": .string("miss"),
                "title": .string(title),
                "artist": .string(artist),
            ])
        )
    }

    /// A genre row: no `id`, and a `trackCount` the shape gate forbids.
    static func genre(name: String, trackCount: Int) -> ToolResultRow {
        ToolResultRow(
            text: "\(name) (\(trackCount))",
            payload: .object(["genre": .string(name), "trackCount": .int(trackCount)])
        )
    }

    /// The entry all four CONTROL tools answer with. Its keys are a strict SUBSET
    /// of a track's, so NO shape predicate can reject it — only the allow-list.
    static func playbackEntry(id: Int64, title: String, artist: String) -> ToolResultRow {
        ToolResultRow(
            text: "\(title) — \(artist)",
            payload: .object([
                "id": .int(id),
                "title": .string(title),
                "artist": .string(artist),
                "durationSeconds": .number(210),
            ])
        )
    }
}

// MARK: - Connector

/// A ``ToolCallingConnector`` with no transport, for asserting the composition
/// rather than a wire format.
final class ScriptedToolConnector: ToolCallingConnector, @unchecked Sendable {
    enum Script {
        case calls([ToolCall])
        case text(String)
        case failure(ConnectorFailure)
    }

    let id = "scripted"
    let displayName = "Scripted"
    let authDescriptor = AuthDescriptor.subscription

    private let lock = NSLock()
    private var pending: [Script]
    private var recorded: [ToolTurnRequest] = []

    init(_ pending: [Script]) {
        self.pending = pending
    }

    var recordedRequests: [ToolTurnRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func chatTurn(_ request: ToolTurnRequest) async throws -> ToolTurnResponse {
        switch next(recording: request) {
        case let .calls(calls):
            return ToolTurnResponse(text: "", toolCalls: calls, transcript: request.transcript)
        case let .text(text):
            return ToolTurnResponse(text: text, transcript: request.transcript)
        case let .failure(failure):
            throw failure
        }
    }

    private func next(recording request: ToolTurnRequest) -> Script {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(request)
        return pending.isEmpty ? .text("done") : pending.removeFirst()
    }

    func listModels() async throws -> [ModelInfo] {
        throw ConnectorFailure.unconfigured
    }

    func structuredCompletion(
        schema _: JSONSchemaObject,
        instructions _: String,
        prompt _: String,
        model _: String
    ) async throws -> Data {
        throw ConnectorFailure.unconfigured
    }

    func completion(instructions _: String, prompt _: String, model _: String) async throws -> String {
        throw ConnectorFailure.unconfigured
    }
}
