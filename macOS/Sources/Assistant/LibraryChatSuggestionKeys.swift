// LibraryChatSuggestionKeys — what a suggestion row is ticked, counted and reported
// under, for the rows that name a verified video and for the rows that do not.
//
// Split from `LibraryChatSuggestionSelection.swift` to keep both files inside
// SwiftLint's 400-line ceiling, the same reason that file was split from the list.
// See that file's header for WHY selection is keyed rather than indexed.
//
// ── THE FOLD IS IMPLEMENTED HERE ON PURPOSE ──────────────────────────────────
//
// `FolderSidebarViewModel.foldedForMatching` folds identically, and this deliberately
// does NOT call it: that lives in PlayerCore's `ViewModels`, which this surface has no
// other reason to import, and the two folds answer different questions — one decides
// whether a folder matches what someone typed, this one decides whether two chat rows
// name the same song. Coupling them would mean a future tweak to folder search silently
// re-keying every tick in the transcript.
import Foundation
import Services

extension LibraryChatSuggestionList {
    /// Marks a key as naming a QUERY rather than a video.
    ///
    /// Cannot collide with the other kind of key: a canonical video id is exactly 11
    /// base64url characters, and `:` is not one of them.
    static let candidateKeyPrefix = "q:"

    /// The key this row is ticked, counted and reported under.
    ///
    /// A verified row keys by the canonical id the downloader will actually be handed, so
    /// a ticked row cannot become an un-downloadable one. Every other row — a search
    /// fallback, or a `.video` row whose URL names no id this app accepts — keys by the
    /// two strings the miss was named by, which is exactly what a later lookup gets.
    static func rowKey(_ suggestion: LinkableSuggestion) -> String {
        verifiedVideoID(suggestion) ?? candidateKey(title: suggestion.title, artist: suggestion.artist)
    }

    /// The canonical id a row ALREADY names, or `nil` when it names none.
    ///
    /// Two gates, both load-bearing: the row must promise a VIDEO — a search row opens a
    /// query page, which names no video to download — and its destination must yield an
    /// id the downloader accepts.
    static func verifiedVideoID(_ suggestion: LinkableSuggestion) -> String? {
        guard suggestion.kind == .video else { return nil }
        return YouTubeURLNormalizer.canonicalVideoID(from: suggestion.url)
    }

    /// The key a row with no verified video is ticked under.
    ///
    /// Folded so the same song written two ways collapses to one tick and one download —
    /// a model that answers "Café Zoë" once and "CAFE ZOE" the next turn named one song.
    /// The `|` is a separator rather than punctuation: `"Live"` by `"Alice"` and
    /// `"Live Alice"` by nobody must not become the same key.
    static func candidateKey(title: String, artist: String?) -> String {
        "\(candidateKeyPrefix)\(folded(title))|\(folded(artist ?? ""))"
    }

    /// The key this row can be picked by, or `nil` when it cannot be picked.
    ///
    /// The one refusal left: a row with no title to look up. Every such row folds to the
    /// same `"q:|"`, so one tick would select all of them and one download would stand
    /// for a song nobody named.
    static func selectableKey(_ suggestion: LinkableSuggestion) -> String? {
        if let videoID = verifiedVideoID(suggestion) {
            return videoID
        }
        guard !folded(suggestion.title).isEmpty else { return nil }
        return candidateKey(title: suggestion.title, artist: suggestion.artist)
    }

    /// The form two rows are compared in: case-, diacritic- and width-insensitive, with
    /// surrounding whitespace removed.
    static func folded(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}
