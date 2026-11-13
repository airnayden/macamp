// MusicBrainzInfoParsing — the pure, network-free parse seams for the info client.
//
// These statics map the MusicBrainz + Wikipedia JSON bodies into the value types
// ``MusicBrainzInfoClient`` returns. They are split out so `@testable` tests can
// lock the mapping against fixture JSON without performing any HTTP. This file
// MUST NOT import AppKit or UIKit (PlayerCore portability invariant).
import Foundation

// MARK: - Parsed value types

/// The relations/tags/date pulled from one MusicBrainz `inc=url-rels+tags` lookup.
struct MBInfoParsedDetail: Equatable {
    var wikipediaURLString: String?
    var tagNames: [String]
    var firstReleaseDate: String?
}

/// The text + image pulled from one Wikipedia REST `page/summary` body.
struct WikipediaSummary: Equatable {
    var extract: String?
    var imageURL: URL?
}

// MARK: - Query construction + request helpers

extension MusicBrainzInfoClient {
    /// Allowed characters when percent-encoding a Wikipedia page title into the
    /// summary path: the URL-path set minus `/`, so a slash inside a title is
    /// encoded rather than read as a path separator.
    static let titleAllowed: CharacterSet = {
        var set = CharacterSet.urlPathAllowed
        set.remove(charactersIn: "/")
        return set
    }()

    /// Composes the Lucene query: the entity's own field plus, for non-artist
    /// entities, an `artist:` clause when one is supplied. Phrase-quoted, blanks dropped.
    static func searchQuery(kind: MBInfoEntityKind, name: String, secondary: String?) -> String {
        guard let primary = nonBlank(name) else { return "" }
        var clauses = ["\(kind.searchField):\(quote(primary))"]
        if kind != .artist, let secondary = nonBlank(secondary) {
            clauses.append("artist:\(quote(secondary))")
        }
        return clauses.joined(separator: " AND ")
    }

    static func makeGET(_ url: URL, userAgent: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    static func quote(_ term: String) -> String {
        let escaped = term.replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    static func nonBlank(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

// MARK: - Response mapping (internal test seam)

extension MusicBrainzInfoClient {
    /// The first matching entity MBID from a `/ws/2/{entity}?query=…` search body,
    /// or `nil` when the body has no matches.
    static func firstSearchID(from data: Data, kind: MBInfoEntityKind) -> String? {
        guard let response = try? JSONDecoder().decode(MBInfoSearchResponse.self, from: data) else {
            return nil
        }
        let refs: [MBInfoEntityRef]? = switch kind {
        case .artist: response.artists
        case .releaseGroup: response.releaseGroups
        case .recording: response.recordings
        }
        guard let id = refs?.first?.id?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else {
            return nil
        }
        return id
    }

    /// Pulls the `type == "wikipedia"` URL relationship, the descriptive tags
    /// (highest-weighted first), and any first-release-date from a lookup body.
    /// A malformed body yields an empty detail, never an error.
    static func parseEntityDetail(from data: Data) -> MBInfoParsedDetail {
        guard let detail = try? JSONDecoder().decode(MBInfoEntityDetail.self, from: data) else {
            return MBInfoParsedDetail(wikipediaURLString: nil, tagNames: [], firstReleaseDate: nil)
        }
        let wiki = detail.relations?
            .first { $0.type == "wikipedia" }?
            .url?.resource
            ?? detail.relations?
            .first { $0.type == "wikidata" }?
            .url?.resource
        let tags = (detail.tags ?? [])
            .sorted { ($0.count ?? 0) > ($1.count ?? 0) }
            .compactMap { $0.name?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return MBInfoParsedDetail(
            wikipediaURLString: wiki,
            tagNames: tags,
            firstReleaseDate: nonBlank(detail.firstReleaseDate)
        )
    }

    /// The page title (the last path segment) of a Wikipedia article URL, e.g.
    /// `https://en.wikipedia.org/wiki/Pink_Floyd` → `Pink_Floyd`. `lastPathComponent`
    /// already percent-decodes, so an encoded title round-trips correctly.
    static func wikipediaTitle(fromURLString urlString: String) -> String? {
        guard let url = URL(string: urlString) else { return nil }
        if urlString.contains("wikidata.org") {
            let qid = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
            return qid.isEmpty || qid == "/" ? nil : "wikidata:\(qid)"
        }
        let last = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        return last.isEmpty || last == "/" ? nil : last
    }

    /// Maps a Wikipedia REST `page/summary` body to its plain-text `extract` plus a
    /// representative image (original image preferred, else the thumbnail). A
    /// malformed body yields an empty summary, never an error.
    static func parseWikipediaSummary(from data: Data) -> WikipediaSummary {
        guard let summary = try? JSONDecoder().decode(WikipediaSummaryResponse.self, from: data) else {
            return WikipediaSummary()
        }
        let extract = nonBlank(summary.extract)
        let source = summary.originalimage?.source ?? summary.thumbnail?.source
        let imageURL = nonBlank(source).flatMap { URL(string: $0) }
        return WikipediaSummary(extract: extract, imageURL: imageURL)
    }
}

// MARK: - MusicBrainz + Wikipedia JSON (the subset MacAMP consumes)

private struct MBInfoSearchResponse: Decodable {
    let artists: [MBInfoEntityRef]?
    let releaseGroups: [MBInfoEntityRef]?
    let recordings: [MBInfoEntityRef]?

    enum CodingKeys: String, CodingKey {
        case artists, recordings
        case releaseGroups = "release-groups"
    }
}

private struct MBInfoEntityRef: Decodable {
    let id: String?
}

private struct MBInfoEntityDetail: Decodable {
    let relations: [MBInfoRelation]?
    let tags: [MBInfoTag]?
    let firstReleaseDate: String?

    enum CodingKeys: String, CodingKey {
        case relations, tags
        case firstReleaseDate = "first-release-date"
    }
}

private struct MBInfoRelation: Decodable {
    let type: String?
    let url: MBInfoURL?
}

private struct MBInfoURL: Decodable {
    let resource: String?
}

private struct MBInfoTag: Decodable {
    let name: String?
    let count: Int?
}

private struct WikipediaSummaryResponse: Decodable {
    let extract: String?
    let thumbnail: WikipediaImageRef?
    let originalimage: WikipediaImageRef?
}

private struct WikipediaImageRef: Decodable {
    let source: String?
}

// MARK: - Wikidata → enwiki resolution

extension MusicBrainzInfoClient {
    static func parseWikidataEnwikiTitle(from data: Data, qid: String) -> String? {
        guard let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entities = response["entities"] as? [String: Any],
              let entity = entities[qid] as? [String: Any],
              let sitelinks = entity["sitelinks"] as? [String: Any],
              let enwiki = sitelinks["enwiki"] as? [String: Any],
              let title = enwiki["title"] as? String,
              !title.isEmpty
        else { return nil }
        return title
    }
}
