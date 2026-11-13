// PlaybackEngine — the @MainActor transport abstraction over a playback graph.
//
// The app's view-models talk to playback exclusively through this protocol, so
// they never see SFBAudioEngine types. Two conformers exist: the production
// ``SFBPlaybackEngine`` (real audio through SFBAudioEngine) and the file-free
// ``FakePlaybackEngine`` (a deterministic state-machine double for tests), which
// now lives in `FakePlaybackEngine.swift` — each seam added to the contract has
// to be mirrored in the double, so the two grew together past SwiftLint's
// 400-line ceiling.
//
// State changes are delivered through a plain `stateDidChange` callback rather
// than the `@Observable` macro: that macro is a compiler-plugin that would force
// the Xcode toolchain onto every consumer of this module (the same build risk
// the design system avoided with `#Preview`), so a hand-rolled callback keeps
// the dependency surface minimal while staying observable.
//
// Decoding is re-exported (`@_exported`) because the engine's contract surfaces
// it directly: `load`/`enqueue` validate through a ``DecoderProviding`` and throw
// typed ``DecodingError`` values that callers pattern-match for their error UI.
//
// `Models` is imported PLAINLY (not re-exported) for ``OutputDeviceID``. That
// typealias lives in `Models` precisely so this module can name it: the device
// vocabulary's other half (`OutputDeviceControlling`) is in `Services`, which
// `AudioEngine` cannot import without inverting the module graph. Re-exporting
// would pull all of `Models` into everything that imports the engine for the sake
// of one `UInt32` alias, so consumers that want to SPELL the type import `Models`
// themselves — every one of them already does.
//
// `DSP` is imported PLAINLY for ``CrossfeedLevel``, the vocabulary the crossfeed
// seam speaks. `SFBPlaybackEngine.swift` already re-exports `DSP` for consumers
// of this module, so no caller gains an import obligation from it.
//
// This file imports only AVFAudio + Decoding + DSP + Foundation + Models; it MUST
// NOT import AppKit or UIKit (PlayerCore portability invariant).
import AVFAudio
@_exported import Decoding
import DSP
import Foundation
import Models

/// The coarse transport state of a playback engine.
public enum PlaybackState: Sendable, Equatable {
    /// Constructed; nothing loaded yet.
    case idle
    /// A source is loaded (or playback was stopped) and ready to play.
    case stopped
    /// Actively rendering audio.
    case playing
    /// Loaded and positioned, but rendering is suspended.
    case paused
}

/// A `@MainActor` transport over an audio playback graph.
///
/// Conformers own a ten-band EQ (see ``makeEQUnit()``) and apply ReplayGain via
/// the EQ's global gain. Every member is main-actor isolated: the UI drives the
/// transport and observes ``state`` either directly or via ``stateDidChange``.
@MainActor
public protocol PlaybackEngine: AnyObject {
    /// The current transport state.
    var state: PlaybackState { get }
    /// Playback position of the current item in seconds (0 when none).
    var currentTime: TimeInterval { get }
    /// Total duration of the current item in seconds (0 when unknown / none).
    var duration: TimeInterval { get }
    /// Invoked on the main actor whenever ``state`` changes.
    var stateDidChange: ((PlaybackState) -> Void)? { get set }

    /// Replaces the current item with `url`, leaving the engine ``stopped``.
    /// - Throws: ``DecodingError`` if `url` cannot be opened (engine stays usable).
    func load(_ url: URL) throws
    /// Appends `url` for gapless continuation after the current item.
    /// - Throws: ``DecodingError`` if `url` cannot be opened (engine stays usable).
    func enqueue(_ url: URL) throws
    /// Replaces the current item with `source`, leaving the engine ``stopped``.
    ///
    /// The object-returning load path: `source` is resolved through the engine's
    /// ``DecoderProviding`` and the resulting DECODER is handed to the playback
    /// graph. `load(_ url:)` is the whole-stream shorthand for this.
    /// - Throws: ``DecodingError`` if `source` cannot be opened (engine stays usable).
    func load(source: DecoderSource) throws
    /// Appends `source` for gapless continuation after the current item.
    /// - Throws: ``DecodingError`` if `source` cannot be opened (engine stays usable).
    func enqueue(source: DecoderSource) throws
    /// Starts or resumes rendering.
    func play()
    /// Suspends rendering, retaining position.
    func pause()
    /// Stops rendering and resets the position to the start.
    func stop()
    /// Seeks the current item to `time` seconds (clamped to `0 ... duration`).
    func seek(to time: TimeInterval)
    /// Swaps the current source to `url` in place, re-seeking to `time` — a
    /// mid-song source swap (e.g. toggling the karaoke instrumental variant).
    ///
    /// Equivalent to `load` → `seek(to:)` → optionally `play`, applied as one
    /// step: it ends ``PlaybackState/playing`` when `resumePlaying` is `true`,
    /// else ``PlaybackState/paused``, positioned at `time`. The ten-band EQ (band
    /// gains + ReplayGain global gain) and balance are preserved across the swap.
    /// - Throws: ``DecodingError`` if `url` cannot be opened; the prior position,
    ///   transport state, and EQ are left intact (the swap is all-or-nothing).
    func reload(url: URL, at time: TimeInterval, resumePlaying: Bool) throws
    /// Swaps the current source to `source` in place, re-seeking to `time`.
    ///
    /// Identical in every respect to ``reload(url:at:resumePlaying:)`` — which is
    /// the whole-stream shorthand for it — except that `source` may name a frame
    /// region rather than an entire file.
    /// - Throws: ``DecodingError`` if `source` cannot be opened; the prior
    ///   position, transport state, and EQ are left intact.
    func reload(source: DecoderSource, at time: TimeInterval, resumePlaying: Bool) throws
    /// Sets the gain (dB) of EQ band `index`; out-of-range indices are ignored.
    func setBandGain(_ index: Int, dB decibels: Float)
    /// Sets the composed global gain (dB), clamped via ``clampGlobalGain(_:)``.
    ///
    /// - Important: this is the gain PORT, not the gain API. ``GainComposer`` is
    ///   its only caller — contributors (ReplayGain, the graphic and parametric
    ///   pre-amps, a head-room trim) each write their own summand on
    ///   ``PlaybackEngine/gainComposer`` and let the composer push the total.
    ///   Calling this directly overwrites every other contribution.
    func setGlobalGain(_ decibels: Float)

    /// Installs `configuration` on the parametric EQ stage, or removes the stage
    /// entirely when `configuration` is `nil`.
    ///
    /// A SEPARATE seam from ``setBandGain(_:dB:)``, which indexes the fixed
    /// ten-band graphic unit: the parametric stage is a second, independent node
    /// carrying a variable filter list, and it neither reads nor writes the
    /// graphic unit. `nil` DETACHES that node from the graph rather than
    /// bypassing its bands, so a bypassed signal path is the one that was there
    /// before the stage existed, not a transparent-by-arithmetic imitation of it.
    ///
    /// - Important: `configuration.preampDB` is NOT applied to any node's
    ///   `globalGain`. It is pushed onto ``GainComposer/setParametricPreamp(_:)``
    ///   so it SUMS with ReplayGain, the graphic pre-amp and the head-room trim
    ///   instead of overwriting them; `nil` zeroes that summand.
    /// - Throws: ``ParametricEQConfigurationError/tooManyFilters(count:maximum:)``
    ///   when the configuration exceeds
    ///   ``ParametricEQConfiguration/maximumFilterCount``. The stage, the pre-amp
    ///   summand, and the graphic EQ are all left exactly as they were.
    func setParametricConfiguration(_ configuration: ParametricEQConfiguration?) throws

    /// The current output volume (0…1). `NaN` when not available.
    var volume: Float { get }
    /// Sets the output volume (clamped to 0…1).
    func setVolume(_ volume: Float)

    /// The current stereo balance (−1 full-left … 0 center … +1 full-right).
    var balance: Float { get }
    /// Sets the stereo balance (clamped to −1…1).
    func setBalance(_ balance: Float)

    /// The bs2b crossfeed strength currently in the signal path, or `nil` when the
    /// crossfeed stage is not inserted.
    var crossfeedLevel: CrossfeedLevel? { get }

    /// Inserts, retunes, or removes the bs2b crossfeed stage.
    ///
    /// `fcut` (Hz) and `feedDB` (dB) are clamped per component into the legal bs2b
    /// range by ``CrossfeedLevel``, so an out-of-range value is honoured on the
    /// component that WAS legal rather than refused. This never throws: a stale
    /// preference produces a clamped stage, not a failure.
    ///
    /// - Important: the crossfeed stage's own output compensation is applied
    ///   INSIDE its kernel and contributes nothing to ``GainComposer``. It also
    ///   sits DOWNSTREAM of the spectrum tap, so neither the visualizer nor the
    ///   metering ring sees it.
    func setCrossfeed(enabled: Bool, fcut: Double, feedDB: Double)

    /// The device the engine's output is currently routed to, or `nil` when the
    /// platform exposes no selection (iOS) or reports no device.
    ///
    /// Transient: the platform reuses an identifier for a DIFFERENT device after
    /// a replug, so this value is only ever read, never persisted. Preferences
    /// store a device's UID and resolve it to an identifier just before the set.
    var outputDeviceID: OutputDeviceID? { get }

    /// Routes the engine's output to `deviceID`, leaving playback running.
    ///
    /// The route is switched on the live graph — the engine is NOT stopped and
    /// restarted around it, so a mid-song device change neither interrupts the
    /// stream nor disturbs the processing chain, its tap, or the composed gain.
    /// - Throws: ``OutputDeviceSelectionError`` when the platform refuses the
    ///   device. The route and the transport state are left exactly as they were.
    func setOutputDeviceID(_ deviceID: OutputDeviceID) throws

    /// The format the processing chain is currently wired at — the sample rate
    /// and channel count audio is actually flowing through the engine in.
    ///
    /// This is the graph's own format, not the source file's: it is what the
    /// signal-path readout compares against the device's nominal rate to decide
    /// whether sample-rate conversion is happening, and what a metering consumer
    /// reads to learn how many channels the tap is delivering. Always valid —
    /// before any media is loaded it reports the engine's standby format rather
    /// than a zero-channel placeholder.
    var currentConnectionFormat: AVAudioFormat { get }

    /// Called on the main actor when the current decoder finishes (end of audio).
    /// The coordinator hooks this to auto-advance.
    var onEndOfAudio: (() -> Void)? { get set }
    /// Called on the main actor when rendering of the enqueued successor completes
    /// (gapless pre-schedule point). The coordinator hooks this to pre-schedule the
    /// NEXT successor.
    var onRenderingComplete: (() -> Void)? { get set }
}

/// Neutral defaults for the output-routing surface.
///
/// The two production conformers both declare these as real members, so they
/// dispatch dynamically through the protocol witness exactly as the transport
/// members do. The defaults exist for a conformer that has no output graph at all
/// — a coordinator spy, for instance — which would otherwise have to restate a
/// route it does not own just to keep compiling.
public extension PlaybackEngine {
    /// No route to report when the conformer owns no output graph.
    var outputDeviceID: OutputDeviceID? {
        nil
    }

    /// Refuses every selection: a conformer with no output graph has nothing to
    /// route, and silently accepting would let a caller believe otherwise.
    func setOutputDeviceID(_: OutputDeviceID) throws {
        throw OutputDeviceSelectionError.unsupportedOnPlatform
    }

    /// The standby format every conformer falls back to: 44.1 kHz stereo float.
    var currentConnectionFormat: AVAudioFormat {
        PlaybackEngineFormats.standby
    }

    /// No crossfeed stage to report when the conformer owns no processing chain.
    var crossfeedLevel: CrossfeedLevel? {
        nil
    }

    /// Inert: a conformer with no processing chain has nowhere to insert the
    /// stage, and silently accepting would let a caller believe otherwise.
    func setCrossfeed(enabled _: Bool, fcut _: Double, feedDB _: Double) {}

    /// Enforces the band-capacity ceiling and then does nothing: a conformer with
    /// no processing chain has no parametric stage to install onto.
    ///
    /// The capacity check is kept even in the inert default because the ceiling
    /// belongs to the CONTRACT, not to one engine's private graph — a spy double
    /// must refuse an over-capacity profile exactly where the production engine
    /// does, or a caller's error handling is only ever exercised with hardware.
    func setParametricConfiguration(_ configuration: ParametricEQConfiguration?) throws {
        try configuration?.validateFilterCapacity()
    }
}

/// The format the engine layer falls back to when no graph format is available.
///
/// Computed rather than stored: `AVAudioFormat` is not `Sendable`, so a `static
/// let` would be a shared-mutable-state violation under strict concurrency, and
/// constructing one is cheap enough that the fallback path never notices.
enum PlaybackEngineFormats {
    /// 44.1 kHz stereo float — the one format assumed constructible everywhere.
    ///
    /// Serves both the protocol's standby ``PlaybackEngine/currentConnectionFormat``
    /// and the production engine's wiring fallback before the first decoder is
    /// enqueued (the source node reports zero channels until then).
    static var standby: AVAudioFormat {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2) else {
            fatalError("standard 44.1 kHz stereo float format is unconstructible")
        }
        return format
    }
}
