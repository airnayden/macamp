// LibraryChatTools+Answer — `get_listening_stats` and `propose_playlist`: the two
// tools that end a request rather than feed one.
//
// Split from `LibraryChatTools.swift` for SwiftLint's `file_length` ceiling.
//
// ── `Int64` IS NOT `Generable`, SO THE WIRE TYPE IS `[Int]` ───────────────────
//
// ``ToolArguments/identifiers(_:limit:)`` answers in `[Int64]` because that is
// what a GRDB row id is. `Int64` has no `Generable` conformance in the macOS 26.5
// SDK, so `propose_playlist`'s wrapper declares `[Int]` and widens at the
// boundary. That is lossless on every platform this ships to (`Int` is 64-bit on
// arm64 and x86_64), and JSON itself has one number type anyway — the toolbox
// would have decoded a `Double` back to `Int64` regardless.
//
// This is also why ``ChatArgumentKind`` has an `integerArray` case rather than a
// generic array case: the tool layer's only array builder is
// ``ToolSchema/integerArray(_:maxItems:)``, and pretending otherwise would let a
// future array-of-strings argument pass the drift guard unrestated.
//
// This file imports Foundation only; it MUST NOT import AppKit or UIKit
// (PlayerCore portability invariant).
import Foundation

#if canImport(FoundationModels)
    import FoundationModels

    // MARK: - get_listening_stats

    /// `get_listening_stats` — learn this listener's taste.
    @available(macOS 26, iOS 26, *)
    public struct LibraryChatStatsTool: Tool {
        public static let toolName = "get_listening_stats"

        /// Restates ``LibraryToolbox/makeGetListeningStats(_:)``'s schema: one
        /// optional `window` from a closed four-token vocabulary.
        ///
        /// The vocabulary is spelled into the description rather than fixed with a
        /// `GenerationGuide.anyOf` — see `LibraryChatTools.swift`'s header. A token
        /// outside it is answered by ``ToolArgumentError/notAllowed(argument:
        /// allowed:)``, whose message LISTS the four, so a wrong guess self-corrects
        /// on the next call rather than failing the decode.
        @Generable
        public struct Arguments {
            @Guide(description: "Time span to summarise: 7d, 30d, 12m or all. Omit for 30d.")
            public var window: String?

            public init(window: String? = nil) {
                self.window = window
            }
        }

        public let toolbox: LibraryToolbox
        public let counts: LibraryChatToolCounts
        public let name = LibraryChatStatsTool.toolName
        public let description =
            "Summarise what this listener actually played, with their top tracks, artists and genres."

        public init(toolbox: LibraryToolbox, counts: LibraryChatToolCounts) {
            self.toolbox = toolbox
            self.counts = counts
        }

        public func call(arguments: Arguments) async -> String {
            var payload = ChatArgumentPayload()
            payload.put("window", arguments.window)
            return await LibraryChatToolRunner.answer(
                toolbox,
                counts: counts,
                name: Self.toolName,
                arguments: payload.arguments
            )
        }
    }

    // MARK: - propose_playlist

    /// `propose_playlist` — hand the answer back for review.
    ///
    /// The only write-adjacent tool, and it still writes nothing: it FILES an offer
    /// through ``ToolboxProposalFiling``. The rendered result says "Nothing has
    /// been saved yet" in words precisely so the model does not tell the listener
    /// it created a playlist. That sentence is W1's, unchanged — this wrapper adds
    /// no policy of its own.
    @available(macOS 26, iOS 26, *)
    public struct LibraryChatProposalTool: Tool {
        public static let toolName = "propose_playlist"

        /// Restates ``LibraryToolbox/makeProposePlaylist(_:)``'s schema: `name` is
        /// the only required argument; the membership is either `track_ids` or the
        /// `genre` the app materialises it from.
        ///
        /// `track_ids` being OPTIONAL is the whole point of the criteria form and is
        /// parity-visible — W1's `required` list carries the same flip, and
        /// `LibraryChatSchemaParityTests` fails if only one side moves.
        @Generable
        public struct Arguments {
            // `track_ids` matches W1's wire name exactly; see the header of
            // `LibraryChatTools+Sample.swift` for why the model must not be shown a
            // second, camelCased vocabulary.
            // swiftlint:disable identifier_name
            @Guide(description: "Name for the proposed playlist, in the listener's language.")
            public var name: String
            @Guide(description: "Library ids to include, in playing order. At most 500.")
            public var track_ids: [Int]?
            @Guide(description: "Exact library genre.")
            public var genre: String?
            @Guide(description: "Requested track total.")
            public var target_count: Int?
            @Guide(description: "One line explaining the selection.")
            public var description: String?

            public init(
                name: String = "",
                track_ids: [Int]? = nil,
                genre: String? = nil,
                target_count: Int? = nil,
                description: String? = nil
            ) {
                self.name = name
                self.track_ids = track_ids
                self.genre = genre
                self.target_count = target_count
                self.description = description
            }

            // swiftlint:enable identifier_name

            /// The payload ``LibraryToolbox`` reads.
            var payload: ToolArguments {
                var payload = ChatArgumentPayload()
                payload.put("name", name)
                payload.put("track_ids", track_ids)
                payload.put("genre", genre)
                payload.put("target_count", target_count)
                payload.put("description", description)
                return payload.arguments
            }
        }

        public let toolbox: LibraryToolbox
        public let counts: LibraryChatToolCounts
        public let name = LibraryChatProposalTool.toolName
        public let description = "Offer a new playlist to the listener for review. Saves nothing by itself."

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
#endif
