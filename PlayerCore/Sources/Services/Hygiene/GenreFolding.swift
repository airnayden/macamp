// GenreFolding — collapses spelling variants of one genre onto a single key.
//
// NOT a second `GenreNormalizer`, and not a wrapper around one. `GenreNormalizer`
// answers "what genre is this tag?" — it resolves ID3 numeric codes ("(17)" →
// "Rock"), keeps the first value of a NUL-separated frame, and passes free text
// through UNTOUCHED, deliberately never splitting or rewriting it so "Pop/Funk" and
// "Drum & Bass" survive.
//
// This file answers a different question: "are these two genre STRINGS the same
// genre spelled differently?" — "Hip Hop" / "Hip-Hop" / "hip hop" / "HIPHOP". That
// needs exactly the rewriting `GenreNormalizer` refuses to do, so it belongs here,
// downstream of it: the analyzer resolves the raw tag with `GenreNormalizer` FIRST,
// then folds the resolved display text with ``key(for:)``. Running them in that
// order is what makes a numerically-coded row cluster with its free-text
// neighbours instead of forming a variant of its own.
//
// The fold is LOSSY BY DESIGN and is never written anywhere: it is a grouping key
// only. The spelling that ends up on the files is always one the library already
// contained — see `GenreCluster.canonicalGenre`.
//
// This file imports only Foundation; it MUST NOT import AppKit or UIKit
// (PlayerCore portability invariant).
import Foundation

/// Derives a comparison key that ignores case, accents, width and every
/// separator, so spelling variants of one genre collapse onto one bucket.
///
/// Pure, stateless, `Sendable`: a deterministic transform of its input with no
/// shared state.
public enum GenreFolding {
    /// The fixed folding locale, for the same reason ``SortKey`` uses one: the fold
    /// must not depend on the device's runtime locale (Turkish-i safe).
    private static let foldingLocale = Locale(identifier: "en_US_POSIX")

    /// The fold key for a display genre, or `nil` when nothing comparable remains.
    ///
    /// Case, diacritics and width are folded, then every character that is not a
    /// letter or a digit is dropped — which is what makes hyphen, space, underscore
    /// and ampersand variants of one genre agree:
    ///
    /// ```
    /// "Hip-Hop"  → "hiphop"
    /// "hip hop"  → "hiphop"
    /// "HIPHOP"   → "hiphop"
    /// "Drum & Bass" → "drumbass"
    /// "R&B"      → "rb"
    /// ```
    ///
    /// Returns `nil` for `nil`, blank, or punctuation-only input, so a tag with no
    /// letters at all never forms a bucket that could absorb unrelated rows.
    public static func key(for genre: String?) -> String? {
        guard let genre else { return nil }
        let folded = genre.folding(
            options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
            locale: foldingLocale
        )
        let stripped = folded.unicodeScalars.filter(isSignificant)
        guard !stripped.isEmpty else { return nil }
        return String(String.UnicodeScalarView(stripped))
    }

    /// Whether a scalar survives the fold. Letters and digits only — everything
    /// else is separator noise for this purpose.
    private static func isSignificant(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.alphanumerics.contains(scalar)
    }
}
