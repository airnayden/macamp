// LibraryToolbox+Control — `get_playback_state` and `transport`: the two control
// tools that name no tracks.
//
// ── AN ACTION ANSWERS WITH THE STATE IT PRODUCED ──────────────────────────────
//
// Every control tool renders the SAME state sentence, from the snapshot the seam
// returned after doing the work. That is not decoration: `transport("next")` at
// the end of a queue does nothing observable, and a tool that answered "next" with
// "OK" would have lied. Reporting the resulting state makes success and no-op
// distinguishable without a second round-trip — which matters most on-device,
// where a round-trip costs a slice of a 4096-token window.
//
// ── THE UP-NEXT TOTAL GOES IN THE SUMMARY, NOT INTO `totalCount` ──────────────
//
// ``ToolResult/truncationSuffix(omitted:)`` reads "+N more — refine your query",
// which is the right sentence for a search and the wrong one for a queue: there is
// no query to refine. So the rows are exactly what fits, `totalCount` stays at
// `rows.count`, and the real length of the queue is stated in words instead.
//
// This file imports only Foundation; it MUST NOT import AppKit or UIKit
// (PlayerCore portability invariant).
import Foundation

extension LibraryToolbox {
    static func makeGetPlaybackState(_ playback: any ToolboxPlaybackControlling) -> LibraryTool {
        LibraryTool(
            name: "get_playback_state",
            description: "Report what is playing now, how far in, the shuffle and repeat settings, and what is next.",
            parametersSchema: ToolSchema.noArguments,
            execute: { _ in
                let snapshot = await playback.playbackSnapshot(
                    upNextLimit: ToolResultBudget.playbackQueuePreviewLimit
                )
                return controlResult(snapshot)
            }
        )
    }

    static func makeTransport(_ playback: any ToolboxPlaybackControlling) -> LibraryTool {
        LibraryTool(
            name: "transport",
            description: "Press one playback control: play, pause, next, previous or stop.",
            parametersSchema: ToolSchema.object([
                .init("action", ToolSchema.string(
                    "The control to press.",
                    allowed: ToolboxTransportAction.allCases.map(\.rawValue)
                )),
            ], required: ["action"]),
            execute: { arguments in
                let raw = try arguments.enumValue(
                    "action",
                    allowed: ToolboxTransportAction.allCases.map(\.rawValue)
                )
                // `enumValue` already refused anything outside the vocabulary, so
                // the initialiser cannot fail — but a force-unwrap here would make
                // a future vocabulary edit a crash instead of a refusal.
                guard let action = ToolboxTransportAction(rawValue: raw) else {
                    throw ToolArgumentError.notAllowed(
                        argument: "action",
                        allowed: ToolboxTransportAction.allCases.map(\.rawValue)
                    )
                }
                return await controlResult(playback.perform(action))
            }
        )
    }
}

// MARK: - Shared rendering

extension LibraryToolbox {
    /// A control tool's answer: an optional lead sentence, the state sentence, and
    /// the queue preview as rows.
    ///
    /// `resultCount` is deliberately `nil` on every control tool. "How many
    /// results" is not a question a transport press can be asked, and a shell that
    /// labelled "Paused" as "— 3 results" would be reporting the queue length as a
    /// lookup size. Same reasoning as `get_listening_stats` and `propose_playlist`.
    static func controlResult(_ snapshot: ToolboxPlaybackSnapshot, lead: String? = nil) -> ToolResult {
        let sentence = stateSentence(snapshot)
        let summary = [lead, sentence].compactMap(\.self).joined(separator: " ")
        return ToolResult(summary: summary, rows: snapshot.upNext.map { ToolboxRendering.row($0) })
    }

    static func stateSentence(_ snapshot: ToolboxPlaybackSnapshot) -> String {
        var facets = [activityClause(snapshot)]
        if snapshot.current != nil, let position = positionClause(snapshot) {
            facets.append(position)
        }
        facets.append("shuffle \(snapshot.isShuffling ? "on" : "off")")
        facets.append("repeat \(snapshot.repeatSetting.rawValue)")
        facets.append(upNextClause(snapshot))
        return facets.joined(separator: ToolboxRendering.separator) + "."
    }

    /// Total over ``ToolboxPlaybackActivity`` with no `default:`.
    private static func activityClause(_ snapshot: ToolboxPlaybackSnapshot) -> String {
        guard let current = snapshot.current else { return "Nothing is playing" }
        let name = ToolboxRendering.compactLine(current)
        return switch snapshot.activity {
        case .playing: "Playing \(name)"
        case .paused: "Paused at \(name)"
        case .stopped: "Stopped, with \(name) loaded"
        }
    }

    private static func positionClause(_ snapshot: ToolboxPlaybackSnapshot) -> String? {
        guard let elapsed = ToolboxRendering.durationText(max(0, snapshot.elapsedSeconds)) ?? zeroClock(snapshot),
              let total = ToolboxRendering.durationText(snapshot.durationSeconds)
        else { return nil }
        return "\(elapsed) of \(total)"
    }

    /// ``ToolboxRendering/durationText(_:)`` answers `nil` for zero, which is right
    /// for a track length and wrong for a playhead that genuinely sits at the start.
    private static func zeroClock(_ snapshot: ToolboxPlaybackSnapshot) -> String? {
        snapshot.elapsedSeconds < 1 ? "0:00" : nil
    }

    private static func upNextClause(_ snapshot: ToolboxPlaybackSnapshot) -> String {
        guard snapshot.upNextTotal > 0 else { return "nothing up next" }
        return "\(snapshot.upNextTotal) up next"
    }
}
