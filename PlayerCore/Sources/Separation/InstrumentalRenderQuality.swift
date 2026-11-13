// InstrumentalRenderQuality — the encode tier for a separated instrumental.
//
// The separation pipeline reconstructs the instrumental as 44.1 kHz stereo
// float32 PCM, then hands it to `InstrumentalWriter` for on-disk encoding. That
// encode has two tiers, both in an `.m4a` container:
//
//   • `.lossless` — 24-bit Apple Lossless (ALAC). Byte-exact playback, larger
//     files. The original default, kept for users who want reference quality.
//   • `.standard` — 256 kbps AAC. Transparent for karaoke playback at a fraction
//     of the disk footprint (the karaoke cache is capped at 2 GB, so a smaller
//     per-track file fits many more instrumentals before eviction).
//
// The raw `String` value is the persistence + UI contract: `AppSettings` stores
// the selected tier as its raw string and the preferences Picker iterates
// `allCases`, so the case names below are load-bearing — do not rename them
// without a matching settings migration.
import Foundation

/// The encode tier `InstrumentalWriter` uses for a separated instrumental `.m4a`.
public enum InstrumentalRenderQuality: String, CaseIterable, Sendable {
    /// 256 kbps AAC — smaller files, transparent for karaoke playback.
    case standard
    /// 24-bit Apple Lossless (ALAC) — byte-exact, larger files.
    case lossless
}
