// LibraryChatTools — the five FoundationModels `Tool` conformers over W1's
// `.onDevice` set, plus `search_tracks` and `list_genres` themselves.
//
// ── WHY FIVE HAND-WRITTEN WRAPPERS AND NOT ONE GENERIC ONE ────────────────────
//
// A `LibraryTool` publishes its arguments as a RUNTIME `ToolboxJSON` document. A
// FoundationModels `Tool` publishes them as `parameters: GenerationSchema`, which
// the `@Generable` macro SYNTHESISES AT COMPILE TIME from a nested `Arguments`
// struct — verified in the local SDK, where `Tool.parameters` has a default
// implementation only in `extension Tool where Self.Arguments : Generable`, and
// where a primitive `Arguments` (`String`, `Int`, `Double`, `Bool`, `Decimal`) is
// marked `@available(*, unavailable, message: "… Use '@Generable' struct
// instead.")`. There is therefore NO way to build a schema from a value, and no
// way to have one generic wrapper: five tools means five structs, written by hand.
//
// That duplication is the only place in this epic where one fact is stated twice,
// and it is guarded — see ``ChatToolManifest`` and
// `LibraryChatSchemaParityTests`, which compare the published JSON schema against
// the wrappers' ACTUAL Swift properties by reflection, with no hand-kept list on
// either side.
//
// ── EVERY WRAPPER CALLS `run`, NOT `execute` ──────────────────────────────────
//
// Apple's guidance for a small on-device model is that a RECOVERABLE tool failure
// should come back as a short STRING the model can read and correct itself
// against, not as a thrown error that ends the turn. ``LibraryToolbox/run(_:
// arguments:profile:)`` is exactly that function: it never throws, and it renders
// a ``ToolArgumentError`` or ``LibraryToolError`` as the same model-facing
// sentence the argument accessors already write for that audience. So a wrapper's
// `call` is total, and a bad `limit` costs one wasted round-trip instead of a
// dead conversation.
//
// A `Tool.call` that throws is wrapped by the framework in
// `LanguageModelSession.ToolCallError`; ``LibraryChatSession`` still catches that,
// because a wrapper is not the only thing that can fail. It is simply not the
// mechanism these five use for a bad argument.
//
// ── `@Guide` CARRIES DESCRIPTIONS ONLY, DELIBERATELY ──────────────────────────
//
// The SDK ships two `@Guide` overloads: a plain `description:` peer macro, and a
// generic `description:_ guides: GenerationGuide<T>...` that CONSTRAINS decoding
// (`.range`, `.anyOf`, `.maximumCount`). Only the plain one is used here, for two
// reasons. First, every bound these arguments have is ALREADY enforced by
// ``ToolArguments``' accessors, which answer a violation with a sentence naming
// the argument and its range — a correction the model can act on, where a
// constrained decode just fails. Second, constrained guided generation combined
// with tool calling is the pairing with the known 26.x decoding bugs; the bounds
// are stated in the description text instead, which costs nothing and cannot
// misfire. Revisit only with a live regression test.
//
// ── ONE `Arguments` STRUCT PER TOOL, NEVER A BARE PRIMITIVE ───────────────────
//
// See the `@available(*, unavailable)` extensions quoted above: a `Tool` whose
// `Arguments` is `String`/`Int`/`Double`/`Bool`/`Decimal` does not compile. Even
// `search_tracks`, which has one required argument, therefore wraps it in a
// struct. This is the shape of the fixed-in-26.x primitive-arguments bug.
//
// This file imports Foundation only; it MUST NOT import AppKit or UIKit
// (PlayerCore portability invariant).
import Foundation

#if canImport(FoundationModels)
    import FoundationModels

    // MARK: - Payload building

    /// Accumulates a ``ToolArguments`` payload, skipping absent optionals.
    ///
    /// An omitted argument is written as an ABSENT key rather than as an explicit
    /// `null`. ``ToolArguments/value(_:)`` treats the two identically, so this is a
    /// wash for correctness — but an absent key is also what a hand-written test
    /// payload looks like, which keeps the wrapper tests and the toolbox tests
    /// asserting against the same shape.
    struct ChatArgumentPayload {
        private var values: [String: ToolboxJSON] = [:]

        mutating func put(_ name: String, _ value: String?) {
            guard let value else { return }
            values[name] = .string(value)
        }

        mutating func put(_ name: String, _ value: Int?) {
            guard let value else { return }
            values[name] = .int(value)
        }

        mutating func put(_ name: String, _ value: Double?) {
            guard let value else { return }
            values[name] = .number(value)
        }

        mutating func put(_ name: String, _ value: [Int]?) {
            guard let value else { return }
            values[name] = .array(value.map { .int($0) })
        }

        var arguments: ToolArguments {
            ToolArguments(values)
        }
    }

    // MARK: - Running one tool

    /// The one place a wrapper's `call` reaches the toolbox.
    ///
    /// `runResult` rather than `run` so the answer's ``ToolResult/resultCount`` and
    /// its structured rows can be filed in `counts` before the text — and only the
    /// text — goes back to the model. See `LibraryChatToolCounts.swift` for why
    /// neither can ride the transcript.
    ///
    /// The rows are taken from the FULL result, so the transcript may list tracks
    /// the 600-character on-device render dropped. That is deliberate: the budget
    /// exists to protect the model's context, not the listener's screen.
    enum LibraryChatToolRunner {
        static func answer(
            _ toolbox: LibraryToolbox,
            counts: LibraryChatToolCounts,
            name: String,
            arguments: ToolArguments = ToolArguments()
        ) async -> String {
            let outcome = await toolbox.runResult(name, arguments: arguments, profile: .onDevice)
            await counts.record(
                renderedText: outcome.text,
                resultCount: outcome.resultCount,
                rows: AssistantChatRow.rows(from: outcome.rows),
                suggestions: AssistantChatRow.suggestions(from: outcome.rows)
            )
            return outcome.text
        }
    }

    // MARK: - The set

    /// Builds the FoundationModels projection of ``ToolProfile/onDevice``.
    @available(macOS 26, iOS 26, *)
    public enum LibraryChatTools {
        /// The wrappers for whatever ``ToolProfile/onDevice`` currently publishes.
        ///
        /// DERIVED from `tools(profile: .onDevice)` rather than listed, so the
        /// playback grant is decided in exactly one place
        /// (``LibraryToolboxContext/playback``) and this tier cannot disagree with
        /// the registry about which tools exist. An ungranted toolbox therefore
        /// yields the same five wrappers that shipped before control existed.
        ///
        /// Order is preserved because it is the order the tool DEFINITIONS are
        /// injected into the session's instructions, and a small model reaches for
        /// what it read first — `list_genres` before `sample_tracks` is why it
        /// looks up this library's own spelling instead of inventing one.
        /// - Parameter counts: The ledger every wrapper files its answer's result
        ///   count into. Required rather than defaulted: a session that forgot to
        ///   pass its own would silently lose every count instead of failing.
        public static func onDevice(_ toolbox: LibraryToolbox, counts: LibraryChatToolCounts) -> [any Tool] {
            toolbox.tools(profile: .onDevice).compactMap {
                wrapper(named: $0.name, toolbox: toolbox, counts: counts)
            }
        }

        /// The one name-to-wrapper table. A published tool with no entry is DROPPED
        /// rather than faked, and `LibraryChatSchemaParityTests` fails the build for
        /// the mismatch — which is how a tenth tool arriving without a wrapper is
        /// caught instead of silently vanishing from the on-device session.
        static func wrapper(
            named name: String,
            toolbox: LibraryToolbox,
            counts: LibraryChatToolCounts
        ) -> (any Tool)? {
            switch name {
            case LibraryChatSearchTool.toolName: LibraryChatSearchTool(toolbox: toolbox, counts: counts)
            case LibraryChatGenresTool.toolName: LibraryChatGenresTool(toolbox: toolbox, counts: counts)
            case LibraryChatSampleTool.toolName: LibraryChatSampleTool(toolbox: toolbox, counts: counts)
            case LibraryChatStatsTool.toolName: LibraryChatStatsTool(toolbox: toolbox, counts: counts)
            case LibraryChatProposalTool.toolName: LibraryChatProposalTool(toolbox: toolbox, counts: counts)
            case LibraryChatPlaybackStateTool.toolName:
                LibraryChatPlaybackStateTool(toolbox: toolbox, counts: counts)
            case LibraryChatPlayTracksTool.toolName: LibraryChatPlayTracksTool(toolbox: toolbox, counts: counts)
            case LibraryChatTransportTool.toolName: LibraryChatTransportTool(toolbox: toolbox, counts: counts)
            default: nil
            }
        }

        /// What each wrapper's `Arguments` struct ACTUALLY declares, read by
        /// reflection over a probe instance.
        ///
        /// Lives here rather than in the test target so the drift guard compares
        /// two readings of the shipped code, neither of which is a list a person
        /// maintains. Ordered as a FULLY GRANTED ``onDevice(_:counts:)`` is —
        /// the five library wrappers, then the three control ones — so a missing
        /// entry is as visible as a wrong one. An element is `nil` only if a
        /// wrapper grew a property type ``ChatArgumentKind`` cannot express, which
        /// the parity test rejects.
        public static var reflectedManifests: [ChatToolManifest?] {
            [
                ChatToolManifest.reflected(
                    name: LibraryChatSearchTool.toolName,
                    arguments: LibraryChatSearchTool.Arguments()
                ),
                ChatToolManifest.reflected(
                    name: LibraryChatGenresTool.toolName,
                    arguments: LibraryChatGenresTool.Arguments()
                ),
                ChatToolManifest.reflected(
                    name: LibraryChatSampleTool.toolName,
                    arguments: LibraryChatSampleTool.Arguments()
                ),
                ChatToolManifest.reflected(
                    name: LibraryChatStatsTool.toolName,
                    arguments: LibraryChatStatsTool.Arguments()
                ),
                ChatToolManifest.reflected(
                    name: LibraryChatProposalTool.toolName,
                    arguments: LibraryChatProposalTool.Arguments()
                ),
                ChatToolManifest.reflected(
                    name: LibraryChatPlaybackStateTool.toolName,
                    arguments: LibraryChatPlaybackStateTool.Arguments()
                ),
                ChatToolManifest.reflected(
                    name: LibraryChatPlayTracksTool.toolName,
                    arguments: LibraryChatPlayTracksTool.Arguments()
                ),
                ChatToolManifest.reflected(
                    name: LibraryChatTransportTool.toolName,
                    arguments: LibraryChatTransportTool.Arguments()
                ),
            ]
        }
    }

    // MARK: - search_tracks

    /// `search_tracks` — find a named thing.
    @available(macOS 26, iOS 26, *)
    public struct LibraryChatSearchTool: Tool {
        public static let toolName = "search_tracks"

        /// Restates ``LibraryToolbox/makeSearchTracks(_:)``'s schema:
        /// `query` (required string) + `limit` (optional integer, 1…200).
        @Generable
        public struct Arguments {
            @Guide(description: "Words to match. Each word prefix-matches a title, artist or album token.")
            public var query: String
            @Guide(description: "Maximum tracks to return, 1 to 200. Omit for 20.")
            public var limit: Int?

            public init(query: String = "", limit: Int? = nil) {
                self.query = query
                self.limit = limit
            }
        }

        public let toolbox: LibraryToolbox
        public let counts: LibraryChatToolCounts
        public let name = LibraryChatSearchTool.toolName
        public let description = "Search the listener's library by title, artist or album and return matching tracks."

        public init(toolbox: LibraryToolbox, counts: LibraryChatToolCounts) {
            self.toolbox = toolbox
            self.counts = counts
        }

        public func call(arguments: Arguments) async -> String {
            var payload = ChatArgumentPayload()
            payload.put("query", arguments.query)
            payload.put("limit", arguments.limit)
            return await LibraryChatToolRunner.answer(
                toolbox,
                counts: counts,
                name: Self.toolName,
                arguments: payload.arguments
            )
        }
    }

    // MARK: - list_genres

    /// `list_genres` — learn the library's own vocabulary before guessing at it.
    @available(macOS 26, iOS 26, *)
    public struct LibraryChatGenresTool: Tool {
        public static let toolName = "list_genres"

        /// Restates ``ToolSchema/noArguments``. An EMPTY struct rather than no
        /// `Arguments` type at all: the protocol requires an associated type, and
        /// a primitive stand-in is unavailable (see the file header).
        @Generable
        public struct Arguments {
            public init() {}
        }

        public let toolbox: LibraryToolbox
        public let counts: LibraryChatToolCounts
        public let name = LibraryChatGenresTool.toolName
        public let description = "List the genres present in the listener's library with a track count for each."

        public init(toolbox: LibraryToolbox, counts: LibraryChatToolCounts) {
            self.toolbox = toolbox
            self.counts = counts
        }

        public func call(arguments _: Arguments) async -> String {
            await LibraryChatToolRunner.answer(toolbox, counts: counts, name: Self.toolName)
        }
    }
#endif
