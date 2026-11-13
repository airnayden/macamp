// SortKey — NFC normalisation + deterministic, locale-stable sort-key derivation.
//
// Tag text arrives in arbitrary Unicode normal forms and scripts. Two problems
// follow at library scale (100k+ tracks):
//
//   1. The SAME visible string can carry different bytes (NFC "é" U+00E9 vs NFD
//      "e" + U+0301). Equality, de-duplication and `ORDER BY` all break unless
//      every value is normalised to one form. We pick **NFC** (Apple's
//      `precomposedStringWithCanonicalMapping`) for every textual value.
//
//   2. Humans expect "The Beatles" under *B*, "Café" next to "Cafe", "日本語"
//      ordered phonetically, full-width "ＡＢＣ" next to "ABC". A naive byte sort
//      gets all of these wrong. ``sortKey(for:)`` derives a folded, article-
//      stripped key that a plain SQLite `BINARY` collation orders correctly.
//
// The derived key is deliberately computed against a FIXED `en_US_POSIX` locale
// (never the user's runtime locale): the key is *stored* in the database, so it
// must be byte-stable across devices and locales — otherwise the same library
// would sort differently per user and keyset pagination would corrupt.
//
// This file imports only Foundation (CoreFoundation's `CFStringTransform` is
// re-exported); it MUST NOT import AppKit or UIKit (PlayerCore portability
// invariant).
import Foundation

/// NFC normalisation and sort-key derivation for tag text.
///
/// Pure, stateless, `Sendable`: every function is a deterministic transform of
/// its input string with no shared state.
public enum SortKey {
    /// Canonical, fixed locale used for case/diacritic/width folding so a stored
    /// key never depends on the device's runtime locale (Turkish-i safe).
    private static let foldingLocale = Locale(identifier: "en_US_POSIX")

    /// Leading English articles stripped from sort keys, longest first so `"an "`
    /// is tested before `"a "`. Matched case-insensitively against the folded
    /// (lower-cased) key, each with its trailing space.
    private static let leadingArticles = ["the ", "an ", "a "]

    // MARK: - NFC normalisation

    /// Returns `raw` in Unicode Normalization Form C (canonical composition).
    ///
    /// Apply this to **every** textual tag value (title, artist, album, …) so
    /// equality and ordering are independent of how the source encoded accents.
    public static func normalized(_ raw: String) -> String {
        raw.precomposedStringWithCanonicalMapping
    }

    /// NFC-normalises and trims an optional value, mapping empty/whitespace-only
    /// tags to `nil` so blank frames never masquerade as real metadata. Leading
    /// and trailing whitespace (near-always accidental in tags) is stripped.
    public static func normalizedOrNil(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = normalized(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Sort-key derivation

    /// Derives a deterministic sort key from `raw`:
    ///
    /// 1. NFC-normalise, 2. transliterate non-Latin scripts to Latin (Han →
    /// pinyin, kana → romaji, Cyrillic → Latin), 3. fold away diacritics, case
    /// and full/half width against `en_US_POSIX`, 4. strip a leading English
    /// article, 5. trim. The result is lower-case ASCII-leaning text that sorts
    /// correctly under SQLite's default `BINARY` collation.
    ///
    /// Examples: `"The Beatles" → "beatles"`, `"Café del Mar" → "cafe del mar"`,
    /// `"日本語" → "ri ben yu"`, `"ＡＢＣ" → "abc"`.
    public static func sortKey(for raw: String) -> String {
        let transliterated = latinised(normalized(raw))
        let folded = transliterated
            .folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: foldingLocale)
        let deArticled = strippingLeadingArticle(folded).trimmingCharacters(in: .whitespacesAndNewlines)
        if deArticled.isEmpty {
            return folded.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return deArticled
    }

    /// Derives a sort key from an optional value, returning `nil` for absent or
    /// blank input (so the caller can store `NULL` rather than an empty string).
    public static func sortKeyOrNil(_ raw: String?) -> String? {
        guard let value = normalizedOrNil(raw) else { return nil }
        let key = sortKey(for: value)
        return key.isEmpty ? nil : key
    }

    // MARK: - Private transforms

    /// Transliterates any script to Latin then strips combining marks, using
    /// CoreFoundation's documented two-step transform. ASCII passes through
    /// unchanged; CJK becomes space-separated romanisation.
    private static func latinised(_ value: String) -> String {
        let mutable = NSMutableString(string: value) as CFMutableString
        CFStringTransform(mutable, nil, kCFStringTransformToLatin, false)
        CFStringTransform(mutable, nil, kCFStringTransformStripCombiningMarks, false)
        return mutable as String
    }

    /// Removes a single leading English article (`"the "`, `"an "`, `"a "`) from
    /// an already-folded, lower-cased key. Input must already be lower-cased.
    private static func strippingLeadingArticle(_ folded: String) -> String {
        for article in leadingArticles where folded.hasPrefix(article) {
            return String(folded.dropFirst(article.count))
        }
        return folded
    }
}
