// DecoderOpenGate — serialises decoder CONSTRUCTION, and nothing else.
//
// Several of the codec backends behind ``SFBDecoderProvider`` do process-global
// first-time initialisation the first time a decoder of their family is built.
// mpg123 is the one that bites: its `INT123_frame_init_par` / `wrap_getcpuflags`
// path is not thread-safe on first entry, and two threads reaching it at the
// same instant fault with SIGBUS (EXC_ARM_DA_ALIGN). The offline analysis pass
// fans out `AudioAnalysisService.concurrencyCap` extractions per page, so seven
// or more threads opening their first MP3 together is the ordinary case, not a
// corner one. Routing those opens through one actor makes the first
// initialisation happen exactly once, on one thread, with everybody else
// suspended behind it.
//
// SCOPE — read this before adding a call site. The gate covers the OFFLINE
// paths only: the analysis feature pass and the separation pipeline. It is
// deliberately NOT reachable from ``SFBPlaybackEngine``'s `load()`/`enqueue()`,
// which run on the main actor and must never suspend behind a background
// decode. That path is protected instead by the analysis service's one-shot
// warm-up, which performs the first initialisation before any fan-out begins.
//
// The gate is held for the OPEN ONLY — the header parse — never across the
// decode loop. ``open(_:with:)`` has no suspension point in its body, so the
// backend call is atomic with respect to this actor.
//
// This file imports only Foundation; it MUST NOT import AppKit or UIKit
// (PlayerCore portability invariant).
import Foundation

/// Serialises ``DecoderProviding/makeDecoder(for:)`` calls across the offline
/// decode paths, so a codec's process-global first-time initialisation can never
/// run on two threads at once.
public actor DecoderOpenGate {
    /// The process-wide gate. Shared deliberately: the initialisation it
    /// protects is process-global, so a per-caller instance would serialise
    /// nothing that matters.
    public static let shared = DecoderOpenGate()

    private let willOpen: (@Sendable () -> Void)?
    private let didOpen: (@Sendable () -> Void)?

    /// - Parameters:
    ///   - willOpen: Called immediately before the backend is entered.
    ///   - didOpen: Called immediately after it returns or throws.
    ///
    /// Both are a test seam: a suite passes a counter pair to observe how many
    /// opens are inside the backend at once, which is the property this type
    /// exists to pin. Production uses ``shared``, which installs neither.
    public init(
        willOpen: (@Sendable () -> Void)? = nil,
        didOpen: (@Sendable () -> Void)? = nil
    ) {
        self.willOpen = willOpen
        self.didOpen = didOpen
    }

    /// Opens `url` through `provider`, serialised against every other caller.
    ///
    /// The returned decoder is `sending`: it is constructed here and referenced
    /// nowhere afterwards, so the caller receives it in its own region and may
    /// keep pulling from it on its own thread — the gate is released the instant
    /// this returns.
    ///
    /// - Throws: whatever `provider` throws, unchanged. The gate adds no error
    ///   semantics of its own.
    public func open(_ url: URL, with provider: any DecoderProviding) throws -> sending any PCMDecoding {
        willOpen?()
        defer { didOpen?() }
        return try provider.makeDecoder(for: url)
    }
}
