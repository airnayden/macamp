// GenreNormalizer — resolves a raw genre tag value into a single display genre.
//
// Handles three kinds of legacy ID3 genre encoding, in this order:
//   1. NUL-separated multi-value frames (ID3v2.4) — keep the FIRST value.
//   2. ID3 numeric codes, bare ("17") or parenthesised ("(17)") — resolve to the
//      canonical name. A leading parenthesised code wins over trailing refinement
//      text ("(17)Hardcore" → "Rock"); an unknown code falls back to that text
//      ("(255)Bluegrass" → "Bluegrass") or passes the raw token through ("(255)").
//   3. Plain free-text genres pass through verbatim — NEVER split on '/', ' ', ';'
//      so "Pop/Funk" and "Drum & Bass" survive intact.
import Foundation

/// Normalizes a raw genre tag value into a single display genre.
public enum GenreNormalizer {
    /// Resolves a raw genre tag into a single canonical display string.
    ///
    /// Returns `nil` for `nil`, empty, or whitespace-only input.
    public static func normalize(_ raw: String?) -> String? {
        guard let raw else { return nil }

        // ID3v2.4 stores multiple values NUL-separated; keep only the first.
        let firstValue: String = if let nul = raw.firstIndex(of: "\u{0}") {
            String(raw[..<nul])
        } else {
            raw
        }

        let trimmed = firstValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Parenthesised ID3 reference, e.g. "(17)", "(RX)", "(17)Hardcore".
        if trimmed.hasPrefix("(") {
            return resolveParenthesised(trimmed)
        }
        // Bare numeric ID3 code, e.g. "17".
        if let code = Int(trimmed), let name = id3Genre(code) {
            return name
        }
        // Free-text genre — passes through untouched.
        return trimmed
    }

    /// Resolves a token that begins with `(`. Always returns a non-empty string:
    /// the resolved genre, the trailing refinement text, or the raw token.
    private static func resolveParenthesised(_ token: String) -> String {
        guard let close = token.firstIndex(of: ")") else {
            return token // malformed — no closing paren; treat as free text
        }
        let inner = String(token[token.index(after: token.startIndex) ..< close])
        let refinement = String(token[token.index(after: close)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let resolved = resolveCode(inner) {
            return resolved // a known code wins over any trailing refinement
        }
        // Unknown code: prefer trailing refinement text, else the raw token.
        return refinement.isEmpty ? token : refinement
    }

    /// Resolves the text inside a `(…)` reference: the `RX`/`CR` refinements or a
    /// numeric ID3 code. Returns `nil` when the code is not recognised.
    private static func resolveCode(_ code: String) -> String? {
        switch code {
        case "RX": return "Remix"
        case "CR": return "Cover"
        default:
            guard let value = Int(code) else { return nil }
            return id3Genre(value)
        }
    }

    /// Maps a numeric ID3v1/Winamp genre code to its canonical name, or `nil` when
    /// the code is outside the known table.
    private static func id3Genre(_ code: Int) -> String? {
        guard code >= 0, code < id3GenreTable.count else { return nil }
        return id3GenreTable[code]
    }
}

/// The canonical ID3v1 genre table (0–79) plus the Winamp extensions (80–191),
/// indexed by numeric code. File-scoped so the enum body stays small.
private let id3GenreTable: [String] = [
    // 0–19 — original ID3v1
    "Blues", "Classic Rock", "Country", "Dance", "Disco",
    "Funk", "Grunge", "Hip-Hop", "Jazz", "Metal",
    "New Age", "Oldies", "Other", "Pop", "R&B",
    "Rap", "Reggae", "Rock", "Techno", "Industrial",
    // 20–39
    "Alternative", "Ska", "Death Metal", "Pranks", "Soundtrack",
    "Euro-Techno", "Ambient", "Trip-Hop", "Vocal", "Jazz+Funk",
    "Fusion", "Trance", "Classical", "Instrumental", "Acid",
    "House", "Game", "Sound Clip", "Gospel", "Noise",
    // 40–59
    "Alternative Rock", "Bass", "Soul", "Punk", "Space",
    "Meditative", "Instrumental Pop", "Instrumental Rock", "Ethnic", "Gothic",
    "Darkwave", "Techno-Industrial", "Electronic", "Pop-Folk", "Eurodance",
    "Dream", "Southern Rock", "Comedy", "Cult", "Gangsta",
    // 60–79
    "Top 40", "Christian Rap", "Pop/Funk", "Jungle", "Native American",
    "Cabaret", "New Wave", "Psychedelic", "Rave", "Showtunes",
    "Trailer", "Lo-Fi", "Tribal", "Acid Punk", "Acid Jazz",
    "Polka", "Retro", "Musical", "Rock & Roll", "Hard Rock",
    // 80–99 — Winamp extensions
    "Folk", "Folk-Rock", "National Folk", "Swing", "Fast Fusion",
    "Bebop", "Latin", "Revival", "Celtic", "Bluegrass",
    "Avantgarde", "Gothic Rock", "Progressive Rock", "Psychedelic Rock", "Symphonic Rock",
    "Slow Rock", "Big Band", "Chorus", "Easy Listening", "Acoustic",
    // 100–119
    "Humour", "Speech", "Chanson", "Opera", "Chamber Music",
    "Sonata", "Symphony", "Booty Bass", "Primus", "Porn Groove",
    "Satire", "Slow Jam", "Club", "Tango", "Samba",
    "Folklore", "Ballad", "Power Ballad", "Rhythmic Soul", "Freestyle",
    // 120–139
    "Duet", "Punk Rock", "Drum Solo", "A Cappella", "Euro-House",
    "Dance Hall", "Goa", "Drum & Bass", "Club-House", "Hardcore",
    "Terror", "Indie", "BritPop", "Afro-Punk", "Polsk Punk",
    "Beat", "Christian Gangsta Rap", "Heavy Metal", "Black Metal", "Crossover",
    // 140–159
    "Contemporary Christian", "Christian Rock", "Merengue", "Salsa", "Thrash Metal",
    "Anime", "JPop", "Synthpop", "Abstract", "Art Rock",
    "Baroque", "Bhangra", "Big Beat", "Breakbeat", "Chillout",
    "Downtempo", "Dub", "EBM", "Eclectic", "Electro",
    // 160–179
    "Electroclash", "Emo", "Experimental", "Garage", "Global",
    "IDM", "Illbient", "Industro-Goth", "Jam Band", "Krautrock",
    "Leftfield", "Lounge", "Math Rock", "New Romantic", "Nu-Breakz",
    "Post-Punk", "Post-Rock", "Psytrance", "Shoegaze", "Space Rock",
    // 180–191
    "Trop Rock", "World Music", "Neoclassical", "Audiobook", "Audio Theatre",
    "Neue Deutsche Welle", "Podcast", "Indie Rock", "G-Funk", "Dubstep",
    "Garage Rock", "Psybient",
]
