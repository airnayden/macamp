// LibraryChatTools+Control — the three FoundationModels wrappers over the
// on-device CONTROL set.
//
// Split from `LibraryChatTools.swift` for SwiftLint's `file_length` ceiling, on
// the same reasoning as `LibraryChatTools+Answer.swift`.
//
// ── THREE WRAPPERS, NOT FOUR, AND THE NUMBER WAS MEASURED ────────────────────
//
// `queue_tracks` has no wrapper. Every published definition — name, sentence and
// argument schema — is re-billed against the 4096-token window on EVERY turn, and
// the cost was counted with `SystemLanguageModel.tokenCount(for:)` on a real
// session rather than estimated: 143 tokens for the instructions alone, 955 with
// the five library tools, 1250 with these three, 1288 once the control
// instruction line joins them — the SHIPPED prefix, 31.4% of the window — and
// 1396 with `queue_tracks` as a fourth, past the third a per-turn prefix is held
// to. It is also a refinement of `play_tracks` in exactly the way `get_tracks` is
// a refinement of `search_tracks`, so it is the right one to drop. Cloud and
// external have no such ceiling and publish all four.
//
// ── THE SET IS DERIVED, NEVER RESTATED ───────────────────────────────────────
//
// ``LibraryChatTools/onDevice(_:counts:)`` maps over `tools(profile: .onDevice)`
// instead of listing wrappers, so the playback GRANT is decided in exactly one
// place (`LibraryToolboxContext.playback`) and this tier inherits it. A listener
// who turned assistant control off gets a session whose tool list is
// byte-identical to the one that shipped before control existed — not a session
// with three tools that refuse.
//
// This file imports Foundation only; it MUST NOT import AppKit or UIKit
// (PlayerCore portability invariant).
import Foundation

#if canImport(FoundationModels)
    import FoundationModels

    // MARK: - get_playback_state

    /// `get_playback_state` — answer "what's playing?" without guessing.
    @available(macOS 26, iOS 26, *)
    public struct LibraryChatPlaybackStateTool: Tool {
        public static let toolName = "get_playback_state"

        /// Restates ``ToolSchema/noArguments``. Empty rather than absent for the
        /// reason `list_genres` documents: the protocol requires the associated
        /// type and a primitive stand-in is unavailable.
        @Generable
        public struct Arguments {
            public init() {}
        }

        public let toolbox: LibraryToolbox
        public let counts: LibraryChatToolCounts
        public let name = LibraryChatPlaybackStateTool.toolName
        public let description =
            "Report what is playing now, how far in, the shuffle and repeat settings, and what is next."

        public init(toolbox: LibraryToolbox, counts: LibraryChatToolCounts) {
            self.toolbox = toolbox
            self.counts = counts
        }

        public func call(arguments _: Arguments) async -> String {
            await LibraryChatToolRunner.answer(toolbox, counts: counts, name: Self.toolName)
        }
    }

    // MARK: - play_tracks

    /// `play_tracks` — start playing, immediately.
    ///
    /// The only on-device tool that changes something the listener can hear, and it
    /// is NOT a proposal: playback is ephemeral, local and reversed by pressing
    /// pause. See `ToolboxPlaybackSeam.swift`'s header for why that boundary sits
    /// where it does.
    @available(macOS 26, iOS 26, *)
    public struct LibraryChatPlayTracksTool: Tool {
        public static let toolName = "play_tracks"

        /// Restates ``LibraryToolbox/makePlayTracks(_:_:)``'s schema:
        /// `track_ids` required, `mode` optional.
        @Generable
        public struct Arguments {
            // `track_ids` matches W1's wire name exactly; see the header of
            // `LibraryChatTools+Sample.swift` for why the model must not be shown a
            // second, camelCased vocabulary.
            // swiftlint:disable identifier_name
            @Guide(description: "Library ids to play, in the order they should play. At most 100.")
            public var track_ids: [Int]
            @Guide(description: "How to start. Only \"replace\" is supported; omit it for that.")
            public var mode: String?

            public init(track_ids: [Int] = [], mode: String? = nil) {
                self.track_ids = track_ids
                self.mode = mode
            }

            // swiftlint:enable identifier_name

            var payload: ToolArguments {
                var payload = ChatArgumentPayload()
                payload.put("track_ids", track_ids)
                payload.put("mode", mode)
                return payload.arguments
            }
        }

        public let toolbox: LibraryToolbox
        public let counts: LibraryChatToolCounts
        public let name = LibraryChatPlayTracksTool.toolName
        public let description = "Start playing the given library tracks now, replacing whatever is queued."

        public init(toolbox: LibraryToolbox, counts: LibraryChatToolCounts) {
            self.toolbox = toolbox
            self.counts = counts
        }

        public func call(arguments: Arguments) async -> String {
            await LibraryChatToolRunner.answer(
                toolbox,
                counts: counts,
                name: Self.toolName,
                arguments: arguments.payload
            )
        }
    }

    // MARK: - transport

    /// `transport` — press one of the five buttons.
    @available(macOS 26, iOS 26, *)
    public struct LibraryChatTransportTool: Tool {
        public static let toolName = "transport"

        /// Restates ``LibraryToolbox/makeTransport(_:)``'s schema: one required
        /// value from a closed five-token vocabulary.
        ///
        /// Spelled into the description rather than fixed with a
        /// `GenerationGuide.anyOf`, for the reason `get_listening_stats`'s wrapper
        /// records: a token outside it is answered by a refusal that LISTS the
        /// five, so a wrong guess self-corrects instead of failing the decode.
        @Generable
        public struct Arguments {
            @Guide(description: "The control to press: play, pause, next, previous or stop.")
            public var action: String

            public init(action: String = "") {
                self.action = action
            }
        }

        public let toolbox: LibraryToolbox
        public let counts: LibraryChatToolCounts
        public let name = LibraryChatTransportTool.toolName
        public let description = "Press one playback control: play, pause, next, previous or stop."

        public init(toolbox: LibraryToolbox, counts: LibraryChatToolCounts) {
            self.toolbox = toolbox
            self.counts = counts
        }

        public func call(arguments: Arguments) async -> String {
            var payload = ChatArgumentPayload()
            payload.put("action", arguments.action)
            return await LibraryChatToolRunner.answer(
                toolbox,
                counts: counts,
                name: Self.toolName,
                arguments: payload.arguments
            )
        }
    }
#endif
