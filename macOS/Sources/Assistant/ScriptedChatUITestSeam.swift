// ScriptedChatUITestSeam — the fake MODEL the chat end-to-end UITests drive, and
// nothing else.
//
// Compiled out of Release entirely, and inert unless the hermetic
// `AppEnvironment.liveForUITesting()` seam is already active (`UITEST_SEED_PATH`) —
// the same two-lock construction ``AssistantUITestSeam`` uses, so shipping behaviour
// is untouched by construction rather than by a flag check.
//
// ── THE FAKE REPLACES THE MODEL, NEVER THE TOOL PLUMBING ─────────────────────
//
// A fake at the ``LibraryChatEngine`` layer would replace the connector AND the tool
// loop AND the merged `[AITool]`, which makes a canned "the model called
// propose_playlist" event inert data that executes NOTHING: tool execution lives
// inside `ToolLoopEngine.run` -> `tool.execute`, which `ConnectorChatEngine`
// instantiates and `AppEnvironment.connectorChatEngine` wraps. So the substitution is
// made at the CONNECTOR layer instead. The scripted call is executed by the REAL loop
// against the REAL merged tools, so a `propose_playlist` script really files through
// `LibraryToolAdapter` -> `LibraryToolbox` -> the proposal filer, and an `mcp__` call
// really round-trips through `MCPClientManager` and a real child process.
//
// ── ONE ROUND OF CALLS, THEN ONE ROUND OF PROSE, STATELESSLY ─────────────────
//
// ``ToolTurnRequest/outcomes`` is empty on the first round of a turn and carries the
// previous round's results afterwards, so "have I already called?" needs no stored
// state and no lock: empty means CALL, non-empty means ANSWER. The answering round
// echoes the outcomes verbatim, which is what lets a UI test assert that the tool
// really ran rather than that a canned sentence was rendered.
//
// ── BOTH HALVES OF THE GATE ARE REQUIRED ────────────────────────────────────
//
// This seam alone is dead. `LibraryChatViewModel.send` is reached only when
// `AssistantView.chatAvailability` resolves `.ready`, and in a UI-test process
// `selectedConnectorID` is nil, so that resolves entirely on the host's
// `SystemLanguageModel` probe — which has no override point. `AssistantView+Chat`
// therefore carries the matching `#if DEBUG` early return. Neither half works alone.
//
// ── THE ENRICHER IS SCRIPTED TOO, FOR THE SAME REASON THE MODEL IS ──────────
//
// `AssistantView.chatAvailability` resolves `.ready(.appleIntelligence)` in a
// UI-test process (see above), and `AppEnvironment.suggestionEnricher` is cloud-only
// BY DESIGN — so a scripted turn could never carry a `videoURL` and the video half of
// the suggestion surface would be untestable. ``scriptedSuggestionEnricher()`` closes
// exactly that hole and nothing wider: it is `#if DEBUG`, it is gated by the same two
// locks, it answers `nil` for every script but ``Script/webLinks``, and it composes a
// FIXED watch URL through `YouTubeLinkResolver.validatedWatchURL` — the one sanctioned
// validator — so it cannot smuggle a link past the gate the surface enforces. It makes
// no request; no transport is touched here.
#if DEBUG
    import AIConnectorKit
    import Foundation
    import Services

    enum ScriptedChatUITestSeam {
        /// Launch-environment switch. Absent ⇒ this file changes nothing.
        static let environmentKey = "UITEST_CHAT_SCRIPT"

        /// Handed to `ConnectorChatEngine` as the model id. Never sent anywhere —
        /// the scripted connector ignores it.
        static let model = "uitest-scripted-model"

        /// Prefixes the answering round's prose so a UI test can wait for the turn to
        /// finish without depending on any tool's own wording.
        static let finalMarker = "Scripted turn complete."

        /// Which canned turn to run.
        enum Script: String {
            /// `propose_playlist` with 25 ids and `target_count: 25` — scenario (a).
            case proposal25
            /// `get_tracks` with five ids, so the transcript renders a real track
            /// list with the library context menu — scenario (b).
            case trackList
            /// `mcp__fixture__echo`, which reaches a real spawned child process
            /// through the real `MCPClientManager` — scenario (c). Also the
            /// server-down failure path, when no server is reachable.
            case mcpEcho
            /// `match_tracks` for two songs no fixture library holds, so the turn
            /// lands with two suggestions and the surface draws both link kinds.
            case webLinks
            /// `propose_playlist` in its CRITERIA form — a genre and a target of 150,
            /// with no `track_ids` — so the app's own materialiser assembles a
            /// membership larger than the preview's row cap and smaller than the
            /// proposal ceiling.
            case criteria150
        }

        /// The genre the ``Script/criteria150`` call names. The test stamps the same
        /// value on its seeded rows through
        /// ``RealAudioLibraryFixture/genreEnvironmentKey``.
        static let criteriaGenre = "Scripted Criteria Genre"

        /// The playlist name that call proposes, so a test can find the sheet by it.
        static let criteriaPlaylistName = "Scripted Criteria 150"

        /// The scripted turn this launch asked for, or `nil` for the real tiers.
        static var script: Script? {
            guard isActive, let raw = value(for: environmentKey) else { return nil }
            return Script(rawValue: raw)
        }

        /// The fake model, or `nil` when the composition root should route normally.
        static func connector() -> (any ToolCallingConnector)? {
            script.map(ScriptedChatConnector.init(script:))
        }

        /// The id every scripted video link carries. Eleven characters from the
        /// video-id alphabet, so the real validator accepts it.
        static let videoID = "uitestVIDE0"

        /// A scripted stand-in for the cloud-only link enricher, or `nil` to leave
        /// `AppEnvironment.suggestionEnricher` in charge.
        ///
        /// Links only the EVEN positions, so one scripted turn renders a verified
        /// video row and a search fallback row side by side. `videoURL` is the only
        /// field written — the same one-field contract the real enricher is held to.
        static func scriptedSuggestionEnricher()
            -> (@Sendable ([AssistantChatSuggestion]) async -> [AssistantChatSuggestion])?
        {
            guard script == .webLinks, let url = scriptedVideoURL else { return nil }
            return { @Sendable suggestions in
                suggestions.enumerated().map { offset, suggestion in
                    AssistantChatSuggestion(
                        title: suggestion.title,
                        artist: suggestion.artist,
                        videoURL: offset.isMultiple(of: 2) ? url : nil
                    )
                }
            }
        }

        private static var scriptedVideoURL: URL? {
            URL(string: "https://www.youtube.com/watch?v=\(videoID)")
                .flatMap(YouTubeLinkResolver.validatedWatchURL)
        }

        private static var isActive: Bool {
            value(for: "UITEST_SEED_PATH") != nil
        }

        private static func value(for key: String) -> String? {
            ProcessInfo.processInfo.environment[key]
        }
    }

    /// A ``ToolCallingConnector`` whose first round emits one canned call and whose
    /// second round answers with what the real tool loop just executed.
    struct ScriptedChatConnector: ToolCallingConnector {
        let script: ScriptedChatUITestSeam.Script

        var id: String {
            "uitest-scripted"
        }

        /// Brand-shaped, never localized — the same contract every connector states.
        var displayName: String {
            "Scripted UI Test"
        }

        /// Never read: this connector is handed straight to the engine factory and is
        /// never put in a `ConnectorRegistry`, which is the only thing that asks.
        var authDescriptor: AuthDescriptor {
            .subscription
        }

        func listModels() async throws -> [ModelInfo] {
            [ModelInfo(
                id: ScriptedChatUITestSeam.model,
                displayName: displayName,
                capabilities: [.chat, .toolUse]
            )]
        }

        /// Unreachable: the chat surface only ever calls ``chatTurn(_:)``. Reported as
        /// `unconfigured` rather than crashing so a stray call is diagnosable.
        func structuredCompletion(
            schema _: JSONSchemaObject,
            instructions _: String,
            prompt _: String,
            model _: String
        ) async throws -> Data {
            throw ConnectorFailure.unconfigured
        }

        /// Unreachable, for the same reason as ``structuredCompletion(schema:instructions:prompt:model:)``.
        func completion(instructions _: String, prompt _: String, model _: String) async throws -> String {
            throw ConnectorFailure.unconfigured
        }

        func chatTurn(_ request: ToolTurnRequest) async throws -> ToolTurnResponse {
            guard request.outcomes.isEmpty else {
                let echoed = request.outcomes.map(\.text).joined(separator: "\n")
                return ToolTurnResponse(text: "\(ScriptedChatUITestSeam.finalMarker)\n\(echoed)")
            }
            return ToolTurnResponse(text: "", toolCalls: [Self.call(for: script)])
        }
    }

    // MARK: - The scripts

    extension ScriptedChatConnector {
        /// The single call each script emits on its first round.
        static func call(for script: ScriptedChatUITestSeam.Script) -> ToolCall {
            switch script {
            case .proposal25:
                ToolCall(id: "scripted-1", name: "propose_playlist", argumentsJSON: proposalArguments)
            case .trackList:
                ToolCall(id: "scripted-1", name: "get_tracks", argumentsJSON: trackListArguments)
            case .mcpEcho:
                ToolCall(id: "scripted-1", name: mcpToolName, argumentsJSON: echoArguments)
            case .webLinks:
                ToolCall(id: "scripted-1", name: "match_tracks", argumentsJSON: matchArguments)
            case .criteria150:
                ToolCall(id: "scripted-1", name: "propose_playlist", argumentsJSON: criteriaArguments)
            }
        }

        /// The projected name of ``MCPFixtureServer``'s one tool, for a server the
        /// test adds under the name `fixture`. Built from the projection's own
        /// constants so a change to the namespace breaks here rather than silently.
        static var mcpToolName: String {
            "mcp__fixture__echo"
        }

        /// The text the echo tool is asked to return — distinctive enough that finding
        /// it in the transcript proves the child process really answered.
        static let echoedText = "macamp-mcp-e2e"

        static var echoArguments: String {
            #"{"text":"\#(echoedText)"}"#
        }

        /// Ids 3...27 — the two base fixture tracks hold 1 and 2, and
        /// ``RealAudioLibraryFixture`` inserts fifty more straight after them, so
        /// every one of these 25 resolves to a real row.
        static var proposalArguments: String {
            let ids = (3 ... 27).map(String.init).joined(separator: ",")
            return #"{"name":"Scripted Rock 25","track_ids":[\#(ids)],"target_count":25}"#
        }

        /// Five ids, which is under ``LibraryChatTrackList``'s collapse threshold, so
        /// the transcript renders every row without an expander.
        static var trackListArguments: String {
            #"{"track_ids":[1,2,3,4,5]}"#
        }

        /// The artist every scripted miss names — distinctive enough that no fixture
        /// library can accidentally match it, which is what makes both pairs misses.
        static let missingArtist = "Scripted Missing Artist"

        /// Two songs that are not in any fixture library, so `match_tracks` answers
        /// with two suggestions and no rows.
        static var matchArguments: String {
            #"{"pairs":[{"title":"Scripted Verified Song","artist":"\#(missingArtist)"},"#
                + #"{"title":"Scripted Unverified Song","artist":"\#(missingArtist)"}]}"#
        }

        /// No `track_ids` at all — the criteria form, which the app materialises.
        static var criteriaArguments: String {
            #"{"name":"\#(ScriptedChatUITestSeam.criteriaPlaylistName)","#
                + #""genre":"\#(ScriptedChatUITestSeam.criteriaGenre)","target_count":150}"#
        }
    }
#endif
