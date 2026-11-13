// DownloadEngineRun — drains one spawned engine process into a result.
//
// Split out of `DownloadQueueService+Driver.swift` for the file-length budget, along the
// isolation seam the two already had: everything here runs INSIDE `Task.detached`, off
// the main actor, while the driver that calls it is `@MainActor`. Keeping the two apart
// makes that boundary a file boundary rather than a convention.
//
// This file imports only Foundation and MUST NOT import AppKit/UIKit, Process, or
// URLSession (PlayerCore portability invariant + the downloader boundary gate).
import Foundation

/// The raw result of draining one engine process for a QUEUED DOWNLOAD.
///
/// Distinct from `ToolUpdateInstaller`'s `ToolRunResult`, which collects both streams of
/// a short-lived verification command; this one carries what the download's termination
/// map needs and nothing else.
///
/// `termination` is OPTIONAL because a stream that ends without one is the documented
/// cancellation shape (``ToolProcessRunning``) — never a success.
struct DownloadRunResult {
    let termination: ProcessTermination?
    let filePath: String?
    /// The last stderr line that was not one of MacAMP's own sentinels — see
    /// ``DownloadOutputInterpreter/lastErrorLine``.
    let lastErrorLine: String?
}

/// Everything the conversion poller needs, captured BY VALUE when the transfer spawns.
///
/// `durationSeconds` is a snapshot of the row's enriched duration taken at spawn time,
/// not a live read: the row it came from keeps mutating on the main actor while this
/// value travels into a detached task. It is `nil` whenever the `-J` prefetch failed,
/// which makes every fraction `nil` — the graceful degradation, never a guess.
struct ConversionProgressSource {
    let progressFile: URL
    let durationSeconds: Double?
}

/// Drains a spawned engine process.
///
/// A caseless enum rather than methods on the service: these run INSIDE
/// `Task.detached`, and a `static` member of a `@MainActor` class would inherit that
/// isolation and force a hop back to the main actor for every output line.
enum DownloadEngineRun {
    /// How often the conversion progress file is re-read, in milliseconds.
    ///
    /// 4 Hz: fast enough that a bar moves smoothly, slow enough that a minutes-long
    /// transcode costs a few hundred small reads in total. ffmpeg writes a block roughly
    /// once a second, so polling faster would mostly re-read the same sample — which
    /// `emitItemState`'s same-value suppression would drop anyway.
    static let conversionPollIntervalMilliseconds = 250
    /// Drains a download, publishing each recognized state transition as it arrives.
    ///
    /// BOTH streams are interpreted, because the engine splits MacAMP's own sentinels
    /// across them — `postprocess:` progress goes to stderr while download progress and
    /// `--print` go to stdout. ``DownloadOutputInterpreter`` owns that contract, the
    /// measurement behind it, and the ordering it defends against; this loop only
    /// routes lines into it and awaits what it hands back.
    ///
    /// `publish` is AWAITED rather than fired and forgotten. That is what makes the
    /// ordering the whole `@MainActor` design exists for actually hold: a `pause()` or
    /// `cancelCurrent()` triggered by an observer of one sample is guaranteed to have
    /// landed before the next sample is read. The cost is one actor hop per engine
    /// progress line — I/O-paced, not compute-paced.
    ///
    /// # The conversion poller starts from the drain loop, never before it
    /// `conversion` is only ever read after the interpreter has ADMITTED a
    /// `.postProcessing` state, and the poller it starts is the sole reader of the
    /// progress file. Deriving the start from the sentinel rather than from the spawn is
    /// what makes two orderings impossible rather than merely unlikely: a fraction can
    /// never precede the phase it belongs to and rewind a live download bar, and the
    /// interpreter's own post-processing latch is already set by the time any fraction
    /// exists, so a straggling `.downloading` sample from the other stream stays refused.
    static func transfer(
        runner: any ToolProcessRunning,
        tool: URL,
        arguments: [String],
        conversion: ConversionProgressSource?,
        publish: @Sendable @escaping (DownloadState) async -> Void
    ) async throws -> DownloadRunResult {
        var interpreter = DownloadOutputInterpreter()
        var termination: ProcessTermination?
        var conversionPoll: Task<Void, Never>?
        defer { conversionPoll?.cancel() }
        for try await event in try await runner.spawn(tool: tool, arguments: arguments) {
            try Task.checkCancellation()
            let line: String
            let stream: DownloadOutputStream
            switch event {
            case let .stdout(value): line = value; stream = .standardOutput
            case let .stderr(value): line = value; stream = .standardError
            case let .terminated(value): termination = value; continue
            }
            guard let state = interpreter.interpret(line, from: stream) else { continue }
            await publish(state)
            if case .postProcessing = state, conversionPoll == nil, let conversion {
                conversionPoll = pollConversion(conversion, publish: publish)
            }
        }
        return DownloadRunResult(
            termination: termination,
            filePath: interpreter.filePath,
            lastErrorLine: interpreter.lastErrorLine
        )
    }

    /// Re-reads the progress file at ``conversionPollIntervalMilliseconds`` and publishes
    /// whatever fraction it honestly reports — including `nil`.
    ///
    /// Detached at utility priority and never awaited: the drain loop must keep reading
    /// the engine's streams while this runs, and the transfer's own `defer` cancels it.
    /// A `nil` fraction is published rather than skipped so the bar returns to
    /// indeterminate at `progress=end`; repeats of it cost nothing, because
    /// `emitItemState` drops a sample identical to the previous one.
    ///
    /// The first read waits a full interval, which also gives ffmpeg time to create and
    /// truncate the file before anything looks at it.
    private static func pollConversion(
        _ source: ConversionProgressSource,
        publish: @Sendable @escaping (DownloadState) async -> Void
    ) -> Task<Void, Never> {
        Task.detached(priority: .utility) {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(conversionPollIntervalMilliseconds))
                guard !Task.isCancelled else { return }
                let contents = (try? String(contentsOf: source.progressFile, encoding: .utf8)) ?? ""
                await publish(.postProcessing(fraction: FFProgressFileTailer.fraction(
                    inContents: contents,
                    durationSeconds: source.durationSeconds
                )))
            }
        }
    }

    /// Drains a `-J` prefetch, returning the decoded document only on a clean exit.
    ///
    /// A non-zero exit means the engine could not list the URL at all; returning `nil`
    /// there keeps a half-listed playlist from being presented as a complete one.
    static func info(runner: any ToolProcessRunning, tool: URL, url: URL) async throws -> YtDlpInfoPayload? {
        var lines: [String] = []
        var termination: ProcessTermination?
        let arguments = YtDlpCommandBuilder.prefetchArguments(for: url)
        for try await event in try await runner.spawn(tool: tool, arguments: arguments) {
            try Task.checkCancellation()
            switch event {
            case let .stdout(line): lines.append(line)
            case .stderr: break
            case let .terminated(value): termination = value
            }
        }
        guard termination?.isSuccess == true else { return nil }
        return YtDlpInfoPayload.decode(from: lines)
    }
}
