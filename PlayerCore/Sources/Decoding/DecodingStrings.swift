// DecodingStrings — every user-facing string in the Decoding module.
//
// Centralized as `LocalizedStringResource` keys with an English `defaultValue`,
// exactly like `SeparationStrings`. The module never emits a bare literal for
// user-visible copy — ``DecodingError/message`` references these constants — so
// it is localization-clean by construction. Until the app String Catalogs sync
// the keys, the `defaultValue` renders. Dotted keys follow the project
// convention (`decoding.<area>.<case>`).
//
// `description` (the diagnostic text on ``DecodingError``) stays UNLOCALIZED on
// purpose: it is a log / CLI string that carries a file name and a backend
// message verbatim, and translating a diagnostic makes bug reports unreadable.
// ``DecodingError/message`` is the user-facing counterpart.
import Foundation

/// Localized copy for ``DecodingError``.
public enum DecodingStrings {
    public static let errorIOError = LocalizedStringResource(
        "decoding.error.ioError",
        defaultValue: "This file couldn't be read.",
        comment: "Shown when an audio file is missing, unreadable, or hit a device I/O error"
    )
    public static let errorUnsupportedFormat = LocalizedStringResource(
        "decoding.error.unsupportedFormat",
        defaultValue: "This audio format isn't supported.",
        comment: "Shown when no registered decoder recognises a file's container or codec"
    )
    public static let errorCorruptedFile = LocalizedStringResource(
        "decoding.error.corruptedFile",
        defaultValue: "This file's audio data is damaged.",
        comment: "Shown when a decoder claimed a file but its contents are malformed"
    )
    public static let errorTruncated = LocalizedStringResource(
        "decoding.error.truncated",
        defaultValue: "This file ends earlier than it claims to.",
        comment: "Shown when a stream ends before the frame count promised by its header"
    )
    public static let errorUnsupportedSampleRate = LocalizedStringResource(
        "decoding.error.unsupportedSampleRate",
        defaultValue: "This file's sample rate isn't supported. Only DSD64 can be converted for playback.",
        comment: "Shown when a DSD128/256/512 file is refused — MacAMP converts DSD64 only, and never resamples"
    )
}
