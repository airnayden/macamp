// YouTubeURLNormalizer — pure, dependency-free URL classification for the downloader.
//
// The single place that decides "is this a YouTube link, and which video/playlist does
// it name?". It performs NO network access and NO scraping (the plan forbids HTML
// parsing of YouTube outright) — it is straight `URLComponents` arithmetic, so it is
// exhaustively table-testable and safe to call on the main actor.
//
// Four accepted families, all collapsing to the same 11-character canonical id:
//   https://www.youtube.com/watch?v=<id>       (plus &list=/&t=/&index= noise)
//   https://youtu.be/<id>
//   https://www.youtube.com/shorts/<id>
//   https://music.youtube.com/watch?v=<id>
// Everything else is rejected.
//
// This file imports only Foundation and MUST NOT import AppKit/UIKit, Process, or
// URLSession (PlayerCore portability invariant + the downloader boundary gate).
import Foundation

/// Pure classification of YouTube URLs into canonical video ids and playlist links.
public enum YouTubeURLNormalizer {
    /// The exact length of a YouTube video id. Not a heuristic — the id is a
    /// base64url-encoded 64-bit value, which is always 11 characters.
    public static let videoIDLength = 11

    /// The canonical 11-character video id `url` names, or `nil` when it names none.
    ///
    /// Accepts the four families listed at the top of this file. Query noise
    /// (`&list=`, `&t=`, `&index=`, `&si=`, …) is discarded by construction: only the
    /// `v` item and the relevant path component are ever read.
    public static func canonicalVideoID(from url: URL) -> String? {
        guard let family = family(for: url) else { return nil }
        let candidate = switch family {
        case .short: firstPathComponent(of: url)
        case .main: mainFamilyVideoIDCandidate(url)
        }
        guard let candidate, isValidVideoID(candidate) else { return nil }
        return candidate
    }

    /// The canonical video id named by `text`, or `nil` when `text` is not a URL that
    /// names one.
    ///
    /// A convenience for paste handling, where the input arrives as free text. Leading
    /// and trailing whitespace is trimmed; nothing else is inferred.
    public static func canonicalVideoID(from text: String) -> String? {
        guard let url = url(from: text) else { return nil }
        return canonicalVideoID(from: url)
    }

    /// The playlist id `url` carries in its `list` query item, or `nil` when it has
    /// none (or is not a YouTube URL).
    ///
    /// Presence of a playlist id does NOT make `url` a playlist link — see
    /// ``isPlaylistURL(_:)`` for the precedence rule.
    public static func playlistID(from url: URL) -> String? {
        guard family(for: url) != nil else { return nil }
        guard let value = queryValue(named: "list", in: url), !value.isEmpty else { return nil }
        return value
    }

    /// Whether `url` should be EXPANDED into many downloads rather than treated as one.
    ///
    /// # Precedence rule (a named case in the normalizer tests)
    /// A URL that carries BOTH a video reference and `list=` is a **single video** —
    /// the canonical id wins and the URL never expands. That shape
    /// (`watch?v=<id>&list=<id>&index=3`) is YouTube's most common share format for a
    /// video played from a playlist; expanding it would turn one paste into a 500-item
    /// confirmation sheet, which is exactly the failure this rule prevents.
    ///
    /// Expansion applies ONLY when `list=` appears WITHOUT a video reference —
    /// `playlist?list=<id>` and a bare `watch?list=<id>`.
    ///
    /// "Video reference" is deliberately broader than "resolvable canonical id": a
    /// present-but-malformed `v=` still suppresses expansion, so a typo can never
    /// balloon into a playlist. Such a URL is neither a video nor a playlist, and the
    /// caller rejects it.
    public static func isPlaylistURL(_ url: URL) -> Bool {
        guard family(for: url) != nil else { return false }
        guard !carriesVideoReference(url) else { return false }
        return playlistID(from: url) != nil
    }

    /// Whether `url` belongs to a YouTube family this normalizer understands.
    ///
    /// A `true` result means only that the host and scheme are recognized — the URL
    /// may still name neither a video nor a playlist.
    public static func isYouTubeURL(_ url: URL) -> Bool {
        family(for: url) != nil
    }

    /// The canonical, noise-free watch URL for `videoID`, or `nil` when `videoID` is
    /// not a well-formed id.
    ///
    /// This is what gets handed to the download engine: building it from the id alone
    /// is what actually strips `&list=`/`&t=`/`&index=` from the person's paste, so a
    /// share link never drags playlist context into the download.
    public static func canonicalURL(forVideoID videoID: String) -> URL? {
        guard isValidVideoID(videoID) else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.youtube.com"
        components.path = "/watch"
        components.queryItems = [URLQueryItem(name: "v", value: videoID)]
        return components.url
    }

    /// Whether `candidate` has the exact shape of a YouTube video id: 11 characters
    /// drawn from the base64url alphabet.
    public static func isValidVideoID(_ candidate: String) -> Bool {
        guard candidate.count == videoIDLength else { return false }
        return candidate.allSatisfy(isVideoIDCharacter)
    }
}

// MARK: - Family + component parsing

private extension YouTubeURLNormalizer {
    /// The two URL shapes YouTube publishes: the short `youtu.be/<id>` redirector and
    /// everything hosted on `youtube.com` (including the `m.` and `music.` subdomains).
    enum Family {
        case short
        case main
    }

    static func family(for url: URL) -> Family? {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            return nil
        }
        guard let host = url.host()?.lowercased() else { return nil }
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        switch bare {
        case "youtu.be":
            return .short
        case "youtube.com", "m.youtube.com", "music.youtube.com":
            return .main
        default:
            return nil
        }
    }

    /// The id candidate for a `youtube.com`-hosted URL: the `v` query item on
    /// `/watch`, or the component after `/shorts`.
    static func mainFamilyVideoIDCandidate(_ url: URL) -> String? {
        let components = pathComponents(of: url)
        guard let first = components.first else { return nil }
        switch first {
        case "watch":
            return queryValue(named: "v", in: url)
        case "shorts":
            return components.count > 1 ? components[1] : nil
        default:
            return nil
        }
    }

    /// Whether `url` points at a specific video at all — a resolvable canonical id, or
    /// a `v` query item that is merely PRESENT. See ``isPlaylistURL(_:)``.
    static func carriesVideoReference(_ url: URL) -> Bool {
        if canonicalVideoID(from: url) != nil { return true }
        guard let value = queryValue(named: "v", in: url) else { return false }
        return !value.isEmpty
    }

    static func firstPathComponent(of url: URL) -> String? {
        pathComponents(of: url).first
    }

    /// The URL's path split on `/`, with the empty leading/trailing segments removed.
    static func pathComponents(of url: URL) -> [String] {
        url.path(percentEncoded: false).split(separator: "/").map(String.init)
    }

    static func queryValue(named name: String, in url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems
        else {
            return nil
        }
        return items.first { $0.name == name }?.value
    }

    static func url(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed)
    }

    /// The base64url alphabet: `A–Z`, `a–z`, `0–9`, `-`, `_`. ASCII only — a
    /// non-ASCII letter must NOT pass, so `isLetter` would be wrong here.
    static func isVideoIDCharacter(_ character: Character) -> Bool {
        guard let ascii = character.asciiValue else { return false }
        switch ascii {
        case UInt8(ascii: "A") ... UInt8(ascii: "Z"),
             UInt8(ascii: "a") ... UInt8(ascii: "z"),
             UInt8(ascii: "0") ... UInt8(ascii: "9"):
            return true
        case UInt8(ascii: "-"), UInt8(ascii: "_"):
            return true
        default:
            return false
        }
    }
}
