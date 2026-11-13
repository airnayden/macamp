// LibraryChatTools+Sample — `sample_tracks`, the widest of the five.
//
// Split from `LibraryChatTools.swift` for SwiftLint's `file_length` ceiling: nine
// documented arguments plus their payload projection is most of a file on its own.
// Merging it back re-breaks the gate.
//
// ── THE PROPERTY NAMES ARE snake_case ON PURPOSE, AND SWIFTLINT IS SILENCED ───
//
// `@Generable` derives the schema property names the MODEL sees from the Swift
// property names. Spelling them `yearMin` would put a second vocabulary in front
// of the model — one for the on-device tier and W1's `year_min` for the cloud and
// MCP tiers — and would force ``ChatToolManifest``'s drift guard to compare
// through a camel-to-snake conversion, i.e. through a function that can itself be
// wrong. Matching W1's wire names exactly makes the guard an IDENTITY check and
// keeps all three adapters speaking one argument vocabulary.
//
// SwiftLint's `identifier_name` rejects underscores in an identifier, so it is
// disabled around each affected declaration — narrowly, and never file-wide.
//
// This file imports Foundation only; it MUST NOT import AppKit or UIKit
// (PlayerCore portability invariant).
import Foundation

#if canImport(FoundationModels)
    import FoundationModels

    /// `sample_tracks` — get candidates when the request is a mood, not a name.
    @available(macOS 26, iOS 26, *)
    public struct LibraryChatSampleTool: Tool {
        public static let toolName = "sample_tracks"

        /// Restates ``LibraryToolbox/sampleSchema``: nine optional arguments, no
        /// required ones.
        ///
        /// Every bound is stated in prose rather than as a `GenerationGuide` — see
        /// `LibraryChatTools.swift`'s header. `ToolboxSampleFilter`'s two inherited
        /// promises are stated too, because a model that does not know them will
        /// mis-explain its own results: an UNANALYSED track is never excluded by a
        /// tempo or energy bound, and only playable tracks are ever drawn.
        @Generable
        public struct Arguments {
            // swiftlint:disable identifier_name
            @Guide(description: "Exact genre to match, case-insensitively. Call list_genres first.")
            public var genre: String?
            @Guide(description: "Earliest release year, inclusive.")
            public var year_min: Int?
            @Guide(description: "Latest release year, inclusive.")
            public var year_max: Int?
            @Guide(description: "Slowest tempo in bpm, 0 to 400. Unanalysed tracks are not excluded.")
            public var tempo_min: Double?
            @Guide(description: "Fastest tempo in bpm, 0 to 400. Unanalysed tracks are not excluded.")
            public var tempo_max: Double?
            @Guide(description: "Lowest energy, 0 to 1. Unanalysed tracks are not excluded.")
            public var energy_min: Double?
            @Guide(description: "Highest energy, 0 to 1. Unanalysed tracks are not excluded.")
            public var energy_max: Double?
            @Guide(description: "Tracks to draw, 1 to 50. Omit for 20.")
            public var limit: Int?
            @Guide(description: "Shuffle seed, 0 or greater. The same seed always draws the same sample.")
            public var seed: Int?

            public init(
                genre: String? = nil,
                year_min: Int? = nil,
                year_max: Int? = nil,
                tempo_min: Double? = nil,
                tempo_max: Double? = nil,
                energy_min: Double? = nil,
                energy_max: Double? = nil,
                limit: Int? = nil,
                seed: Int? = nil
            ) {
                self.genre = genre
                self.year_min = year_min
                self.year_max = year_max
                self.tempo_min = tempo_min
                self.tempo_max = tempo_max
                self.energy_min = energy_min
                self.energy_max = energy_max
                self.limit = limit
                self.seed = seed
            }

            // swiftlint:enable identifier_name

            /// The payload ``LibraryToolbox`` reads. Absent optionals stay absent.
            var payload: ToolArguments {
                var payload = ChatArgumentPayload()
                payload.put("genre", genre)
                payload.put("year_min", year_min)
                payload.put("year_max", year_max)
                payload.put("tempo_min", tempo_min)
                payload.put("tempo_max", tempo_max)
                payload.put("energy_min", energy_min)
                payload.put("energy_max", energy_max)
                payload.put("limit", limit)
                payload.put("seed", seed)
                return payload.arguments
            }
        }

        public let toolbox: LibraryToolbox
        public let counts: LibraryChatToolCounts
        public let name = LibraryChatSampleTool.toolName
        public let description =
            "Draw a varied sample of playable tracks matching optional genre, year, tempo and energy bounds."

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
