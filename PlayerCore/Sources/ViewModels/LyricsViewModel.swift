// LyricsViewModel — resolves lyrics and tracks the active line/word for a UI.
//
// It resolves lyrics asynchronously through ``LyricsProviding`` (honouring the
// opt-in online policy), builds a ``SyncedHighlighter`` over the timed lines, and
// exposes the active line + word for a given playback time so a karaoke-style UI
// can highlight at 60 fps (the highlighter does an `O(log n)` binary search).
//
// This file imports only Foundation + Lyrics + Observation + os; it MUST NOT
// import AppKit or UIKit (PlayerCore portability invariant), and it MUST NOT
// construct a `URLSession` — every transport lives behind ``LyricsProviding``.
import Foundation
import Lyrics
import Observation
import os

/// The user-visible outcome of the most recent lyrics resolution.
///
/// Online resolutions report progress and their result, including automatic
/// track-change lookups. Offline passive loads resolve to ``idle`` or ``found``.
///
/// ``noMatch`` and ``failed`` are deliberately distinct: ``LyricsProviding``
/// returning `nil` WITHOUT throwing means the sources genuinely have nothing for
/// this track, while a throw means the service could not be reached — the two
/// deserve different copy.
public enum LyricsFetchOutcome: Equatable, Sendable {
    /// Nothing to report for the current track.
    case idle
    /// A visible lyrics fetch is in flight.
    case loading
    /// Lyrics were resolved.
    case found
    /// The resolve completed, but no source had lyrics for this track.
    case noMatch
    /// The resolve threw — the lyrics service could not be reached.
    case failed
}

/// The available cause of a failed resolution, retained for localized UI feedback.
public enum LyricsFetchFailure: Equatable, Sendable {
    case serviceStatus(Int)
    case invalidRequest
    case invalidResponse
    case network(code: Int, message: String)
    case other(message: String)

    init(error: any Error) {
        switch error {
        case let error as OnlineLyricsError:
            switch error {
            case .invalidURL: self = .invalidRequest
            case let .httpStatus(status):
                self = status > 0 ? .serviceStatus(status) : .invalidResponse
            }
        case let error as URLError:
            self = .network(code: error.errorCode, message: error.localizedDescription)
        case is DecodingError:
            self = .invalidResponse
        default:
            self = .other(message: error.localizedDescription)
        }
    }
}

/// Resolves + highlights synced lyrics for the lyrics UI.
@MainActor
@Observable
public final class LyricsViewModel {
    /// The resolved lyrics document, if any.
    public private(set) var lyrics: Lyrics?
    /// `true` while a resolution is in flight.
    public private(set) var isLoading = false
    /// The timed lines (sorted), as exposed by the highlighter.
    public private(set) var lines: [LyricLine] = []
    /// Index (into ``lines``) of the active line, or `nil` before the first line.
    public private(set) var activeLineIndex: Int?
    /// Index of the active word within the active line, or `nil`.
    public private(set) var activeWordIndex: Int?
    /// Outcome of the most recent resolution, for a UI's inline fetch status.
    public private(set) var fetchOutcome: LyricsFetchOutcome = .idle
    /// The cause reported by the provider, cleared when another resolution starts.
    public private(set) var fetchFailure: LyricsFetchFailure?

    @ObservationIgnored private let provider: any LyricsProviding
    @ObservationIgnored private var highlighter: SyncedHighlighter?
    @ObservationIgnored private var resolveTask: Task<Void, Never>?

    /// Creates a lyrics view model over an injected resolver.
    public init(provider: any LyricsProviding) {
        self.provider = provider
    }

    deinit {
        resolveTask?.cancel()
    }

    /// Resolves lyrics for `request`, honouring the opt-in online policy.
    ///
    /// - Parameter explicit: `true` when the listener asked for this fetch (the
    ///   panel's Fetch button). Online automatic lookups also report their progress
    ///   and result so network failures remain visible.
    public func resolve(
        request: LyricsRequest,
        options: LyricsOptions = .default,
        explicit: Bool = false
    ) {
        resolveTask?.cancel()
        isLoading = true
        fetchFailure = nil
        let reportsOutcome = explicit || options.allowOnlineFetch
        setFetchOutcome(reportsOutcome ? .loading : .idle)
        let provider = provider
        resolveTask = Task { [weak self] in
            do {
                let resolved = try await provider.resolveLyrics(for: request, options: options)
                if Task.isCancelled { return }
                self?.apply(resolved, outcome: Self.outcome(resolved: resolved, reportsOutcome: reportsOutcome))
            } catch {
                if Task.isCancelled { return }
                Self.log.error("lyrics resolve failed: \(error.localizedDescription, privacy: .public)")
                self?.apply(
                    nil,
                    outcome: reportsOutcome ? .failed : .idle,
                    failure: reportsOutcome ? LyricsFetchFailure(error: error) : nil
                )
            }
        }
    }

    /// Cancels any in-flight resolution and returns the model to its as-constructed
    /// empty state, so a long-lived instance can be reused without being replaced.
    public func clear() {
        resolveTask?.cancel()
        resolveTask = nil
        apply(nil, outcome: .idle)
    }

    /// Updates the active line/word for the given playback time.
    public func updateHighlight(at time: TimeInterval) {
        guard let highlighter else {
            setHighlight(line: nil, word: nil)
            return
        }
        let position = highlighter.activePosition(at: time)
        setHighlight(line: position?.lineIndex, word: position?.wordIndex)
    }

    /// `@Observable` notifies on every write, including same-value writes — and
    /// this runs on a 0.5 s playback tick, so unconditional assignment re-rendered
    /// every lyrics view twice a second even while the highlight never moved.
    private func setHighlight(line: Int?, word: Int?) {
        if activeLineIndex != line { activeLineIndex = line }
        if activeWordIndex != word { activeWordIndex = word }
    }

    /// The active line, if any.
    public var activeLine: LyricLine? {
        guard let index = activeLineIndex, lines.indices.contains(index) else { return nil }
        return lines[index]
    }
}

private extension LyricsViewModel {
    static let log = Logger(subsystem: "si.macamp.MacAMP", category: "lyrics-online")

    /// A resolve that returns `nil` WITHOUT throwing is a genuine miss, not a
    /// failure. Offline passive loads keep a miss silent.
    static func outcome(resolved: Lyrics?, reportsOutcome: Bool) -> LyricsFetchOutcome {
        if resolved != nil { return .found }
        return reportsOutcome ? .noMatch : .idle
    }

    func apply(_ resolved: Lyrics?, outcome: LyricsFetchOutcome, failure: LyricsFetchFailure? = nil) {
        lyrics = resolved
        fetchFailure = failure
        if let resolved {
            let made = SyncedHighlighter(resolved)
            highlighter = made
            lines = made.lines
        } else {
            highlighter = nil
            lines = []
        }
        activeLineIndex = nil
        activeWordIndex = nil
        isLoading = false
        setFetchOutcome(outcome)
    }

    /// Same-value guard, for the same reason ``setHighlight(line:word:)`` has one.
    func setFetchOutcome(_ outcome: LyricsFetchOutcome) {
        if fetchOutcome != outcome { fetchOutcome = outcome }
    }
}
