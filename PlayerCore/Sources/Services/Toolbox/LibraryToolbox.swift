// LibraryToolbox — the one typed tool layer over MacAMP's library.
//
// Three adapters are built ON this and none of them is allowed to grow its own
// copy: FoundationModels `Tool` conformers, a provider-agnostic agentic loop over
// AIConnectorKit, and an in-process MCP server. Each takes ``LibraryTool``'s four
// fields — stable name, one-sentence description, JSON-Schema arguments, async
// execute — and projects them into its own vocabulary. Nothing tier-specific is
// allowed in here; the ONLY thing a tier changes is which subset it publishes
// (``tools(profile:)``) and how much text a result may occupy (``ToolProfile``).
//
// ── WHY `.onDevice` PUBLISHES FIVE, AND WHICH FIVE ────────────────────────────
//
// Apple's guidance is 3–5 tools per FoundationModels session; five is the ceiling
// and ``ToolResultBudget/onDeviceToolLimit`` enforces it. The five are the ones a
// small model needs to complete the whole "make me a playlist" loop end to end:
//
//   search_tracks        find a named thing
//   list_genres          learn the library's own vocabulary before guessing at it
//   sample_tracks        get candidates when the request is a mood, not a name
//   get_listening_stats  learn this listener's taste
//   propose_playlist     hand the answer back for review
//
// `get_tracks`, `get_track_features`, `list_playlists` and `get_playlist` are
// omitted from that set because each is a REFINEMENT of information the five
// already return, and a sixth definition would cost context on every turn.
//
// ── READS ARE PROFILE-SCOPED AND OFF-MAIN ─────────────────────────────────────
//
// Every read is scoped by `context.profileId` through the same `LibraryVisibility`
// predicate the browse surface uses, and the synchronous repository calls are
// funnelled through ``ToolboxExecutor/offMain(_:)`` so a `@MainActor` caller never
// parks the main thread on a pooled GRDB connection.
//
// This file imports Foundation + Persistence; it MUST NOT import AppKit, UIKit or
// `ViewModels` (PlayerCore portability + layering invariants).
import Foundation
import Persistence

/// Everything the tools read and file through.
public struct LibraryToolboxContext: Sendable {
    /// The concrete repository, not the protocol — ``TrackRepository/resolvedTracks(profileId:trackIds:)``
    /// and the facet reads are concrete-extension APIs by the long-standing
    /// precedent the engineering contract records for ProfileState reads.
    public var tracks: TrackRepository
    public var playlists: any PlaylistRepositoryProviding
    public var digests: any ListeningDigestBuilding
    public var reader: any ToolboxLibraryReading
    public var proposals: any ToolboxProposalFiling
    /// The player, or `nil` when this caller was not granted control of it.
    ///
    /// OPTIONAL is the whole gating mechanism: `nil` means the four control tools
    /// are never REGISTERED, so they are absent from every tier's list and a model
    /// is never shown a capability it would be refused. An "always registered,
    /// refuses when ungranted" design was rejected — it teaches the model the tool
    /// exists, costs its definition in the on-device window for nothing, and turns
    /// a settings state into a runtime error.
    public var playback: (any ToolboxPlaybackControlling)?
    /// The profile every read is scoped to.
    public var profileId: Int64
    /// The evaluation instant, injected so a test can pin recency windows.
    public var now: @Sendable () -> Date
    /// Told which playlist `get_playlist` served, or `nil` when nobody is watching.
    ///
    /// OPTIONAL and defaulted for the same reason ``playback`` is: `nil` is what
    /// every construction that predates the seam gets, so installing an observer is
    /// additive rather than a migration. Unlike `playback` it gates NOTHING — the
    /// answer a model receives is byte-identical either way (see
    /// ``ToolboxPlaylistReadObserving``).
    public var playlistReadObserver: (any ToolboxPlaylistReadObserving)?

    public init(
        tracks: TrackRepository,
        playlists: any PlaylistRepositoryProviding,
        digests: any ListeningDigestBuilding,
        reader: any ToolboxLibraryReading,
        proposals: any ToolboxProposalFiling,
        playback: (any ToolboxPlaybackControlling)? = nil,
        profileId: Int64 = ProfileRecord.guestID,
        now: @escaping @Sendable () -> Date = { Date() },
        playlistReadObserver: (any ToolboxPlaylistReadObserving)? = nil
    ) {
        self.tracks = tracks
        self.playlists = playlists
        self.digests = digests
        self.reader = reader
        self.proposals = proposals
        self.playback = playback
        self.profileId = profileId
        self.now = now
        self.playlistReadObserver = playlistReadObserver
    }
}

/// The registry: every tool, keyed by its stable name, subsettable per tier.
public struct LibraryToolbox: Sendable {
    /// The five LIBRARY tools ``ToolProfile/onDevice`` publishes, in the order it
    /// publishes them. See the file header for why these five.
    public static let onDeviceToolNames = [
        "search_tracks",
        "list_genres",
        "sample_tracks",
        "get_listening_stats",
        "propose_playlist",
    ]

    /// The CONTROL tools ``ToolProfile/onDevice`` adds when a playback seam is
    /// granted, in publication order. See the file header for the measurement.
    public static let onDeviceControlToolNames = [
        "get_playback_state",
        "play_tracks",
        "transport",
    ]

    /// Every control tool, in registry order. The set gated by
    /// ``LibraryToolboxContext/playback``.
    public static let controlToolNames = [
        "get_playback_state",
        "play_tracks",
        "queue_tracks",
        "transport",
    ]

    /// What the tools read and file through.
    public let context: LibraryToolboxContext

    private let ordered: [LibraryTool]
    private let byName: [String: LibraryTool]

    public init(context: LibraryToolboxContext) {
        self.context = context
        let tools = Self.makeTools(context)
        ordered = tools
        byName = Dictionary(tools.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Every registered tool, in declaration order.
    public var allTools: [LibraryTool] {
        ordered
    }

    /// The tools `profile` publishes.
    ///
    /// `.onDevice` returns at most ``ToolResultBudget/onDeviceToolLimit`` library
    /// tools plus at most ``ToolResultBudget/onDeviceControlToolLimit`` control
    /// tools; every other tier returns all of them. A control tool that was never
    /// registered (no playback grant) drops out of both lists by `compactMap`, so
    /// the ungranted on-device set is byte-identical to what shipped before.
    public func tools(profile: ToolProfile) -> [LibraryTool] {
        guard profile.restrictsToolCount else { return ordered }
        let library = Self.onDeviceToolNames
            .compactMap { byName[$0] }
            .prefix(ToolResultBudget.onDeviceToolLimit)
        let control = Self.onDeviceControlToolNames
            .compactMap { byName[$0] }
            .prefix(ToolResultBudget.onDeviceControlToolLimit)
        return Array(library) + Array(control)
    }

    /// The tool registered under `name`, or `nil`.
    public func tool(named name: String) -> LibraryTool? {
        byName[name]
    }

    /// Runs a tool, throwing the typed refusal when it cannot.
    public func execute(_ name: String, arguments: ToolArguments = ToolArguments()) async throws -> ToolResult {
        guard let tool = byName[name] else { throw LibraryToolError.unknownTool(name: name) }
        return try await tool.execute(arguments)
    }

    /// Runs a tool and renders the outcome — INCLUDING a refusal — as the text the
    /// tier hands back to the model.
    ///
    /// Never throws: a tool call that fails must come back as a sentence the model
    /// can act on, not as an exception that ends the turn.
    public func run(
        _ name: String,
        arguments: ToolArguments = ToolArguments(),
        profile: ToolProfile
    ) async -> String {
        await runResult(name, arguments: arguments, profile: profile).text
    }

    /// ``run(_:arguments:profile:)`` plus the answer's ``ToolResult/resultCount``.
    ///
    /// The seam an adapter uses when its shell wants to say "— 12 results" beside a
    /// lookup: the count travels as a number rather than being recovered from the
    /// rendered text, which is the whole point of it existing. A refusal reports
    /// `nil`, so a shell cannot label a failed call as a lookup that found nothing.
    public func runResult(
        _ name: String,
        arguments: ToolArguments = ToolArguments(),
        profile: ToolProfile
    ) async -> ToolRunOutcome {
        do {
            let result = try await execute(name, arguments: arguments)
            return ToolRunOutcome(
                text: result.renderedText(profile: profile),
                resultCount: result.resultCount,
                rows: result.rows
            )
        } catch let error as ToolArgumentError {
            return Self.refusal(error.message, profile: profile)
        } catch let error as LibraryToolError {
            return Self.refusal(error.message, profile: profile)
        } catch {
            return Self.refusal(LibraryToolError.readFailed(reason: "\(error)").message, profile: profile)
        }
    }

    static func refusal(_ message: String, profile: ToolProfile) -> ToolRunOutcome {
        ToolRunOutcome(text: ToolResult.message(message).renderedText(profile: profile))
    }
}

/// What one ``LibraryToolbox/runResult(_:arguments:profile:)`` produced.
public struct ToolRunOutcome: Sendable, Equatable, Hashable {
    /// Exactly what ``LibraryToolbox/run(_:arguments:profile:)`` returns.
    public let text: String
    /// ``ToolResult/resultCount``, or `nil` for a refusal.
    public let resultCount: Int?
    /// The result's rows BEFORE `text` dropped any to fit the tier's budget.
    ///
    /// The structured counterpart of `resultCount`, and pre-truncation for exactly
    /// the same reason: an adapter that draws its own list must not be limited to
    /// the rows the MODEL was shown. Empty for a refusal.
    public let rows: [ToolResultRow]

    public init(text: String, resultCount: Int? = nil, rows: [ToolResultRow] = []) {
        self.text = text
        self.resultCount = resultCount
        self.rows = rows
    }
}

// MARK: - Registry

extension LibraryToolbox {
    /// Declaration order is the order `allTools` and every non-restricted tier
    /// publish in. Ten LIBRARY tools: the v1 set covering the eight capabilities
    /// it names — playlists are two (list, then open one) — plus `match_tracks`.
    /// The four CONTROL tools sit between them, and only when a playback seam was
    /// granted, because `match_tracks` is registered AFTER the conditional control
    /// block: position 10 ungranted, position 14 granted.
    ///
    /// EVERY addition is APPENDED rather than interleaved, because the names and
    /// their order are a wire format an external MCP client reads: neither a grant
    /// nor a later library tool may renumber a list a client already saw. That is
    /// why the control block is an `if let` rather than an early return — a tool
    /// added after it must reach BOTH grant states, and an early return would
    /// silently leave the ungranted tier one tool short.
    static func makeTools(_ context: LibraryToolboxContext) -> [LibraryTool] {
        var tools = [
            makeSearchTracks(context),
            makeListGenres(context),
            makeGetTracks(context),
            makeGetTrackFeatures(context),
            makeGetListeningStats(context),
            makeListPlaylists(context),
            makeGetPlaylist(context),
            makeSampleTracks(context),
            makeProposePlaylist(context),
        ]
        if let playback = context.playback {
            tools.append(contentsOf: [
                makeGetPlaybackState(playback),
                makePlayTracks(context, playback),
                makeQueueTracks(context, playback),
                makeTransport(playback),
            ])
        }
        tools.append(makeMatchTracks(context))
        return tools
    }
}

// MARK: - Off-main funnel

/// Runs a blocking repository call off the calling actor.
///
/// The synchronous repository overloads park their thread on a pooled GRDB
/// connection. A `@MainActor` adapter calling a tool must not do that, and a
/// `nonisolated async` function is only guaranteed to leave the caller's executor
/// under Swift's current rules — so the hop is made explicit rather than assumed.
enum ToolboxExecutor {
    static func offMain<Value: Sendable>(_ work: @escaping @Sendable () throws -> Value) async throws -> Value {
        try await Task.detached(priority: .utility) { try work() }.value
    }

    /// ``offMain(_:)`` with the failure re-typed, so a GRDB error reaches the model
    /// as a sentence instead of as a stringified `NSError` with a SQLite code in it.
    static func read<Value: Sendable>(_ work: @escaping @Sendable () throws -> Value) async throws -> Value {
        do {
            return try await offMain(work)
        } catch {
            throw LibraryToolError.readFailed(reason: "\(error)")
        }
    }

    /// The same re-typing for a repository call that is ALREADY `async` (and
    /// therefore already suspends on a GRDB reader off the calling actor — no
    /// second hop is wanted).
    ///
    /// A refusal this layer produced itself passes through untouched: re-wrapping
    /// a `notFound` as a `readFailed` would replace a precise sentence with a vague
    /// one.
    static func readAsync<Value: Sendable>(_ work: () async throws -> Value) async throws -> Value {
        do {
            return try await work()
        } catch let error as LibraryToolError {
            throw error
        } catch let error as ToolArgumentError {
            throw error
        } catch {
            throw LibraryToolError.readFailed(reason: "\(error)")
        }
    }
}
