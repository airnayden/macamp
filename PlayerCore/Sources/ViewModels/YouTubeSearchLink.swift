// YouTubeSearchLink — the ONE place a "not in your library" suggestion becomes a URL.
//
// ── WHY THE APP BUILDS THE LINK, NEVER THE MODEL ──────────────────────────────
//
// `match_tracks` answers with misses: titles the listener asked for that the library
// does not have. The obvious next affordance is "look it up" — and the obvious wrong
// way to build it is to let the model hand back a URL, because a URL a model wrote is
// a URL nobody reviewed. This helper takes ONLY the two strings the miss already
// carries (``AssistantChatSuggestion``'s `title`/`artist`, which came from the
// LISTENER's own request) and composes a fixed search endpoint around them.
//
// AMENDED INVARIANT. The sentence that used to end this section — "no shell may render
// any other URL beside a suggestion", resting on there being no field on
// ``AssistantChatSuggestion`` that could carry one — is narrowed rather than dropped.
// ``AssistantChatSuggestion/videoURL`` now exists, filled in after a turn lands by
// ``LibraryChatViewModel``'s enrichment seam. The rule is therefore: a RECEIVED URL
// renders only if `YouTubeLinkResolver.validatedWatchURL` — AIConnectorKit's ONE
// sanctioned validator — accepted it; everything else a shell draws is still built
// here. This file is unaffected either way: it is the BUILT half, and it composes a
// search link from two strings that are not a URL to begin with.
//
// ── ENCODING IS EXPLICIT, NOT `queryItems`' DEFAULT ───────────────────────────
//
// `URLComponents.queryItems` percent-encodes against `urlQueryAllowed` minus `&`/`=`,
// which leaves `+` LITERAL — and a literal `+` in a query is read as a SPACE by every
// search endpoint, so "Bad Religion +" would silently search for "Bad Religion  ".
// So the query is encoded here against an explicit allowed set and assigned through
// ``URLComponents/percentEncodedQuery``. `'` stays literal (it is in
// `urlQueryAllowed` and is not reserved), which is what makes
// "Guns N' Roses" read as itself.
//
// Foundation only — this file is in PlayerCore and MUST NOT import AppKit or UIKit.
// It also performs no I/O: it returns a `URL`, and opening it is the shell's
// user-initiated navigation (a SwiftUI `Link`), never a `URLSession` request.
import Foundation

/// A web search for one track the library does not have.
public enum YouTubeSearchLink {
    /// The search endpoint every link points at. A constant, never model-supplied.
    static let host = "www.youtube.com"
    static let path = "/results"
    static let queryName = "search_query"

    /// Characters that may appear unescaped in the query.
    ///
    /// `urlQueryAllowed` minus the five sub-delimiters that would change how the
    /// query PARSES (`&`, `=`, `?`, `/`) or how it READS (`+` → space). Everything
    /// else — apostrophes, parentheses, `!`, `*` — survives verbatim, so a title
    /// stays legible in the address bar.
    static let allowed: CharacterSet = .urlQueryAllowed
        .subtracting(CharacterSet(charactersIn: "+&=?/"))

    /// A YouTube search for `title` (and `artist` when there is one), or `nil` when
    /// there is nothing to search for.
    ///
    /// The two fields are joined by a single space in the order a person would say
    /// them. Blank and whitespace-only inputs are dropped rather than encoded, so a
    /// miss carrying `artist: ""` searches for the title alone instead of for
    /// "title ".
    public static func url(title: String, artist: String?) -> URL? {
        let terms = [title, artist]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !terms.isEmpty else { return nil }
        guard let encoded = terms.joined(separator: " ").addingPercentEncoding(withAllowedCharacters: allowed)
        else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        components.percentEncodedQuery = "\(queryName)=\(encoded)"
        return components.url
    }
}
