import Foundation
@testable import Metadata
import Testing

@Suite("MusicBrainzInfoClientTests")
struct MusicBrainzInfoClientTests {
    // MARK: - Search-ID extraction

    @Test("the first artist MBID is pulled from an artist search body")
    func firstArtistID() {
        let json = #"{"artists":[{"id":"mbid-artist-1","name":"Pink Floyd"},{"id":"mbid-artist-2"}]}"#
        #expect(MusicBrainzInfoClient.firstSearchID(from: Data(json.utf8), kind: .artist) == "mbid-artist-1")
    }

    @Test("the first release-group MBID is pulled from a release-group search body")
    func firstReleaseGroupID() {
        let json = #"{"release-groups":[{"id":"mbid-rg-1","title":"The Wall"}]}"#
        #expect(MusicBrainzInfoClient.firstSearchID(from: Data(json.utf8), kind: .releaseGroup) == "mbid-rg-1")
    }

    @Test("the first recording MBID is pulled from a recording search body")
    func firstRecordingID() {
        let json = #"{"recordings":[{"id":"mbid-rec-1","title":"Money"}]}"#
        #expect(MusicBrainzInfoClient.firstSearchID(from: Data(json.utf8), kind: .recording) == "mbid-rec-1")
    }

    @Test("an empty or mismatched search body is no match (nil)")
    func searchIDEmpty() {
        #expect(MusicBrainzInfoClient.firstSearchID(from: Data(#"{"artists":[]}"#.utf8), kind: .artist) == nil)
        #expect(MusicBrainzInfoClient.firstSearchID(from: Data(#"{"recordings":[]}"#.utf8), kind: .artist) == nil)
        #expect(MusicBrainzInfoClient.firstSearchID(from: Data("not json".utf8), kind: .artist) == nil)
    }

    // MARK: - Entity-detail mapping

    @Test("the wikipedia relation URL, weighted tags, and release date are parsed")
    func parsesEntityDetail() {
        let detail = MusicBrainzInfoClient.parseEntityDetail(from: Data(Self.artistDetailJSON.utf8))
        #expect(detail.wikipediaURLString == "https://en.wikipedia.org/wiki/Pink_Floyd")
        #expect(detail.tagNames == ["progressive rock", "rock"])
        #expect(detail.firstReleaseDate == "1973-03-01")
    }

    @Test("a body without a wikipedia relation yields a nil URL but keeps tags")
    func parsesDetailNoWiki() {
        let json = #"{"relations":[{"type":"discogs","url":{"resource":"https://discogs.com/x"}}],"tags":[{"name":"jazz","count":2}]}"#
        let detail = MusicBrainzInfoClient.parseEntityDetail(from: Data(json.utf8))
        #expect(detail.wikipediaURLString == nil)
        #expect(detail.tagNames == ["jazz"])
    }

    @Test("a malformed detail body is an empty detail, never an error")
    func parsesDetailMalformed() {
        let detail = MusicBrainzInfoClient.parseEntityDetail(from: Data("not json".utf8))
        #expect(detail.wikipediaURLString == nil)
        #expect(detail.tagNames.isEmpty)
        #expect(detail.firstReleaseDate == nil)
    }

    // MARK: - Wikipedia title parsing

    @Test("the page title is the last path component of a wikipedia URL")
    func wikipediaTitleParsing() {
        #expect(
            MusicBrainzInfoClient.wikipediaTitle(fromURLString: "https://en.wikipedia.org/wiki/Pink_Floyd")
                == "Pink_Floyd"
        )
    }

    @Test("a percent-encoded wikipedia title is decoded by lastPathComponent")
    func wikipediaTitlePercentEncoded() {
        #expect(
            MusicBrainzInfoClient.wikipediaTitle(fromURLString: "https://en.wikipedia.org/wiki/Beyonc%C3%A9")
                == "Beyoncé"
        )
    }

    @Test("an unusable wikipedia URL string is nil")
    func wikipediaTitleEmpty() {
        #expect(MusicBrainzInfoClient.wikipediaTitle(fromURLString: "") == nil)
    }

    // MARK: - Wikipedia summary mapping

    @Test("the extract and the original image are pulled from a summary body")
    func parsesWikipediaSummary() {
        let summary = MusicBrainzInfoClient.parseWikipediaSummary(from: Data(Self.summaryJSON.utf8))
        #expect(summary.extract == "Pink Floyd were an English rock band formed in London in 1965.")
        #expect(summary.imageURL?.absoluteString == "https://upload.wikimedia.org/orig.jpg")
    }

    @Test("the thumbnail is used when no original image is present")
    func summaryThumbnailFallback() {
        let json = #"{"extract":"A summary.","thumbnail":{"source":"https://upload.wikimedia.org/thumb.jpg"}}"#
        let summary = MusicBrainzInfoClient.parseWikipediaSummary(from: Data(json.utf8))
        #expect(summary.imageURL?.absoluteString == "https://upload.wikimedia.org/thumb.jpg")
    }

    @Test("a malformed summary body is an empty summary, never an error")
    func summaryMalformed() {
        let summary = MusicBrainzInfoClient.parseWikipediaSummary(from: Data("not json".utf8))
        #expect(summary.extract == nil)
        #expect(summary.imageURL == nil)
    }

    // MARK: - Query construction

    @Test("an artist query carries only the artist field")
    func artistQuery() {
        let query = MusicBrainzInfoClient.searchQuery(kind: .artist, name: "Pink Floyd", secondary: nil)
        #expect(query == #"artist:"Pink Floyd""#)
    }

    @Test("an album query carries the release-group field plus the artist clause")
    func albumQuery() {
        let query = MusicBrainzInfoClient.searchQuery(kind: .releaseGroup, name: "The Wall", secondary: "Pink Floyd")
        #expect(query == #"releasegroup:"The Wall" AND artist:"Pink Floyd""#)
    }

    @Test("a query with no usable primary term is empty")
    func emptyQuery() {
        #expect(MusicBrainzInfoClient.searchQuery(kind: .recording, name: "  ", secondary: "X").isEmpty)
    }

    // MARK: - MockInfoFetcher

    @Test("the mock returns its canned values and records each query")
    func mockReturnsAndRecords() async throws {
        let mock = MockInfoFetcher(
            artist: ArtistInfo(biography: "bio", tags: ["rock"]),
            album: AlbumInfo(description: "story"),
            track: TrackInfo(description: "desc")
        )
        let artist = try await mock.fetchArtistInfo(name: "A", mbid: "id-a")
        let album = try await mock.fetchAlbumInfo(title: "Al", artist: "A", mbid: nil)
        let track = try await mock.fetchTrackInfo(title: "T", artist: "A", mbid: nil)
        #expect(artist?.biography == "bio")
        #expect(album?.description == "story")
        #expect(track?.description == "desc")
        #expect(mock.queries.count == 3)
        #expect(mock.queries.first?.kind == "artist")
        #expect(mock.queries.first?.mbid == "id-a")
    }

    // MARK: - Fixtures

    private static let artistDetailJSON = #"""
    {
      "id": "mbid-artist-1",
      "relations": [
        { "type": "discogs", "url": { "resource": "https://www.discogs.com/artist/45467" } },
        { "type": "wikipedia", "url": { "resource": "https://en.wikipedia.org/wiki/Pink_Floyd" } }
      ],
      "tags": [
        { "name": "rock", "count": 3 },
        { "name": "progressive rock", "count": 9 }
      ],
      "first-release-date": "1973-03-01"
    }
    """#

    private static let summaryJSON = #"""
    {
      "title": "Pink Floyd",
      "extract": "Pink Floyd were an English rock band formed in London in 1965.",
      "thumbnail": { "source": "https://upload.wikimedia.org/thumb.jpg" },
      "originalimage": { "source": "https://upload.wikimedia.org/orig.jpg" }
    }
    """#
}
