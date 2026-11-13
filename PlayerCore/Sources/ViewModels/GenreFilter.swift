// GenreFilter — the shared selection state for the library genre-filter picker
// (Task 14), consumed verbatim by the macOS chip bar and the iOS scope bar.
//
// `.all` clears the filter (the browser keeps using the shared all-tracks
// window); `.genre` / `.untagged` route the list through a
// ``GenreBrowserViewModel`` paginating `TrackRepository.tracksByGenre`. The enum
// lives in PlayerCore so its option-building + query-argument contract is
// unit-tested under `swift test`; only the localized chip labels live in the app
// shells (the genre name itself is non-translatable display text).
import Foundation
import Persistence

/// A library genre-filter selection: every genre, one named genre, or the
/// untagged ("(no genre)") bucket.
public enum GenreFilter: Hashable, Sendable, Identifiable {
    case all
    case genre(String)
    case untagged

    public var id: String {
        switch self {
        case .all: "__macamp.genre.all__"
        case .untagged: "__macamp.genre.untagged__"
        case let .genre(name): name
        }
    }

    /// The argument to pass to `TrackRepository.tracksByGenre(genre:)`:
    /// `nil` for every track, `""` for the untagged bucket, else the genre name.
    public var queryArgument: String? {
        switch self {
        case .all: nil
        case .untagged: ""
        case let .genre(name): name
        }
    }

    public var isAll: Bool {
        self == .all
    }
}

public extension GenreFilter {
    /// Builds the ordered picker options from a repository facet query: "All
    /// Genres" first, then each distinct genre, then the untagged bucket — and
    /// only when the library actually contains an untagged track.
    static func options(from facets: LibraryGenreFacets) -> [GenreFilter] {
        var result: [GenreFilter] = [.all]
        result.append(contentsOf: facets.genres.map(GenreFilter.genre))
        if facets.includesUntagged {
            result.append(.untagged)
        }
        return result
    }
}
