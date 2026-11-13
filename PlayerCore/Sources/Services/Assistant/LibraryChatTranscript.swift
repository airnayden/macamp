// LibraryChatTranscript — the gated translation from Apple's `Transcript.Entry`
// onto this module's ``ChatTranscriptEntry``.
//
// The same two-layer shape as `AssistantAvailability.swift`: a pure, floor
// available mapper (``AssistantChatEventMapping``) over a repo-internal mirror,
// and ONE gated file that does nothing but move a system enum onto it. Everything
// interesting — which entries become events, what a turn's answer text is, when to
// condense — is therefore table-testable on any host, and the part that genuinely
// needs the SDK is this, which has no branches worth testing.
//
// ── SEGMENTS ARE FLATTENED, NOT DROPPED ──────────────────────────────────────
//
// Every carrier entry holds `[Transcript.Segment]`, which is `.text(TextSegment)`
// or `.structure(StructuredSegment)`. A structured segment is a `GeneratedContent`
// — the shape a tool result takes when a tool returns a `@Generable` value rather
// than a string. These five tools all return `String`, so `.structure` is not on
// the live path today; it is still read (as its `jsonString`) rather than skipped,
// because a silently empty tool result would look exactly like a tool that
// answered with nothing.
//
// ── `@unknown default:` IS MANDATORY HERE AND FORBIDDEN NEXT DOOR ────────────
//
// `Transcript.Entry` and `Transcript.Segment` are RESILIENT SYSTEM enums that may
// gain a case in any OS update (a `.reasoning` entry already exists in newer
// previews behind `#if compiler(>=6.4)`), so both switches degrade rather than
// fail to compile — the same sanctioned carve-out `AssistantFailure.mapping(_:)`
// documents. The switches over ``ChatTranscriptEntry`` in
// `AssistantChatEvent.swift` carry NO `default:` for the opposite reason: that one
// is this repo's own enum, and a new case there must break the build.
//
// An unrecognised entry maps to `.response("")`, which
// ``AssistantChatEventMapping`` drops as blank prose. A future entry kind
// therefore costs a missing event, never a crash and never a fabricated one.
//
// This file imports Foundation only; it MUST NOT import AppKit or UIKit
// (PlayerCore portability invariant).
import Foundation

#if canImport(FoundationModels)
    import FoundationModels

    /// Reads a FoundationModels transcript into floor-available values.
    @available(macOS 26, iOS 26, *)
    public enum LibraryChatTranscript {
        /// The mirror of one transcript entry.
        public static func mirror(_ entry: Transcript.Entry) -> ChatTranscriptEntry {
            switch entry {
            case let .instructions(instructions):
                .instructions(text(of: instructions.segments))
            case let .prompt(prompt):
                .prompt(text(of: prompt.segments))
            case let .toolCalls(calls):
                .toolCalls(calls.map(\.toolName))
            case let .toolOutput(output):
                .toolOutput(name: output.toolName, text: text(of: output.segments))
            case let .response(response):
                .response(text(of: response.segments))
            @unknown default:
                .response("")
            }
        }

        /// The mirror of a run of entries — what ``LibraryChatSession`` hands the
        /// mapper after each turn.
        public static func mirror(_ entries: some Sequence<Transcript.Entry>) -> [ChatTranscriptEntry] {
            entries.map(mirror(_:))
        }

        /// A segment run as plain text, newline-joined.
        static func text(of segments: [Transcript.Segment]) -> String {
            segments.map(text(of:)).joined(separator: "\n")
        }

        static func text(of segment: Transcript.Segment) -> String {
            switch segment {
            case let .text(segment):
                segment.content
            case let .structure(segment):
                segment.content.jsonString
            @unknown default:
                ""
            }
        }
    }
#endif
