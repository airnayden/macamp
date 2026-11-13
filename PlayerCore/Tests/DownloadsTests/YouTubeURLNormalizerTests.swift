// Table-driven coverage of `YouTubeURLNormalizer` — the pure classifier every
// downloader path routes through. One table drives BOTH assertions per row (canonical
// id and playlist classification), so a case can never be added to one and forgotten
// in the other.
import Foundation
import Services
import Testing

/// One row of the classification table.
struct YouTubeURLCase: CustomStringConvertible {
    let name: String
    let url: String
    let expectedID: String?
    let isPlaylist: Bool

    var description: String {
        name
    }

    /// The parsed URL. Every row's string is a valid URL by construction; a row that
    /// exercises unparsable text belongs in the string-API tests instead.
    var parsed: URL? {
        URL(string: url)
    }
}

@Suite("YouTube URL normalization")
struct YouTubeURLNormalizerTests {
    /// The one video every accepted family in this table points at.
    static let videoID = "dQw4w9WgXcQ"

    static let cases: [YouTubeURLCase] = acceptedCases + playlistCases + rejectedCases

    // MARK: Accepted single-video shapes

    static let acceptedCases: [YouTubeURLCase] = [
        YouTubeURLCase(
            name: "family: watch?v=",
            url: "https://www.youtube.com/watch?v=\(videoID)",
            expectedID: videoID,
            isPlaylist: false
        ),
        YouTubeURLCase(
            name: "family: youtu.be short link",
            url: "https://youtu.be/\(videoID)",
            expectedID: videoID,
            isPlaylist: false
        ),
        YouTubeURLCase(
            name: "family: shorts",
            url: "https://www.youtube.com/shorts/\(videoID)",
            expectedID: videoID,
            isPlaylist: false
        ),
        YouTubeURLCase(
            name: "family: music.youtube.com/watch?v=",
            url: "https://music.youtube.com/watch?v=\(videoID)",
            expectedID: videoID,
            isPlaylist: false
        ),
        YouTubeURLCase(
            name: "host: bare youtube.com",
            url: "https://youtube.com/watch?v=\(videoID)",
            expectedID: videoID,
            isPlaylist: false
        ),
        YouTubeURLCase(
            name: "host: mobile m.youtube.com",
            url: "https://m.youtube.com/watch?v=\(videoID)",
            expectedID: videoID,
            isPlaylist: false
        ),
        YouTubeURLCase(
            name: "host: www.music.youtube.com",
            url: "https://www.music.youtube.com/watch?v=\(videoID)",
            expectedID: videoID,
            isPlaylist: false
        ),
        YouTubeURLCase(
            name: "scheme: http is accepted",
            url: "http://www.youtube.com/watch?v=\(videoID)",
            expectedID: videoID,
            isPlaylist: false
        ),
        YouTubeURLCase(
            name: "noise: &t= and &si= are stripped",
            url: "https://www.youtube.com/watch?v=\(videoID)&t=42s&si=Ab_cD-1234",
            expectedID: videoID,
            isPlaylist: false
        ),
        // The rule this whole design exists to protect: YouTube's most common share
        // format must resolve to ONE video, never a 500-item confirmation sheet.
        YouTubeURLCase(
            name: "PRECEDENCE: v= AND list= together is a SINGLE VIDEO",
            url: "https://www.youtube.com/watch?v=\(videoID)&list=PLabcdefghijk&index=3",
            expectedID: videoID,
            isPlaylist: false
        ),
        YouTubeURLCase(
            name: "PRECEDENCE: youtu.be with ?list= is a SINGLE VIDEO",
            url: "https://youtu.be/\(videoID)?list=PLabcdefghijk",
            expectedID: videoID,
            isPlaylist: false
        ),
        YouTubeURLCase(
            name: "PRECEDENCE: shorts with ?list= is a SINGLE VIDEO",
            url: "https://www.youtube.com/shorts/\(videoID)?list=PLabcdefghijk",
            expectedID: videoID,
            isPlaylist: false
        ),
    ]

    // MARK: Playlist shapes (list= WITHOUT a video reference)

    static let playlistCases: [YouTubeURLCase] = [
        YouTubeURLCase(
            name: "PRECEDENCE: playlist?list= without v= EXPANDS",
            url: "https://www.youtube.com/playlist?list=PLabcdefghijk",
            expectedID: nil,
            isPlaylist: true
        ),
        YouTubeURLCase(
            name: "PRECEDENCE: bare watch?list= without v= EXPANDS",
            url: "https://www.youtube.com/watch?list=PLabcdefghijk",
            expectedID: nil,
            isPlaylist: true
        ),
        YouTubeURLCase(
            name: "PRECEDENCE: music.youtube.com/playlist?list= EXPANDS",
            url: "https://music.youtube.com/playlist?list=OLAK5uy_abcdefg",
            expectedID: nil,
            isPlaylist: true
        ),
    ]

    // MARK: Rejected shapes (neither a video nor a playlist)

    static let rejectedCases: [YouTubeURLCase] = [
        YouTubeURLCase(
            name: "PRECEDENCE: malformed v= with list= is NEITHER (never expands)",
            url: "https://www.youtube.com/watch?v=tooshort&list=PLabcdefghijk",
            expectedID: nil,
            isPlaylist: false
        ),
        YouTubeURLCase(
            name: "junk: non-YouTube host",
            url: "https://vimeo.com/watch?v=\(videoID)",
            expectedID: nil,
            isPlaylist: false
        ),
        YouTubeURLCase(
            name: "junk: lookalike host",
            url: "https://notyoutube.com/watch?v=\(videoID)",
            expectedID: nil,
            isPlaylist: false
        ),
        YouTubeURLCase(
            name: "junk: lookalike host with list=",
            url: "https://notyoutube.com/playlist?list=PLabcdefghijk",
            expectedID: nil,
            isPlaylist: false
        ),
        YouTubeURLCase(
            name: "junk: non-http scheme",
            url: "file:///watch?v=\(videoID)",
            expectedID: nil,
            isPlaylist: false
        ),
        YouTubeURLCase(
            name: "junk: id too short",
            url: "https://youtu.be/abc",
            expectedID: nil,
            isPlaylist: false
        ),
        YouTubeURLCase(
            name: "junk: id too long",
            url: "https://youtu.be/\(videoID)extra",
            expectedID: nil,
            isPlaylist: false
        ),
        YouTubeURLCase(
            name: "junk: id outside the base64url alphabet",
            url: "https://youtu.be/dQw4w9WgXc+",
            expectedID: nil,
            isPlaylist: false
        ),
        YouTubeURLCase(
            name: "junk: youtube.com root",
            url: "https://www.youtube.com/",
            expectedID: nil,
            isPlaylist: false
        ),
        // Deliberate scope boundary: only the four named families are accepted.
        YouTubeURLCase(
            name: "scope: /embed/ is NOT an accepted family",
            url: "https://www.youtube.com/embed/\(videoID)",
            expectedID: nil,
            isPlaylist: false
        ),
    ]

    @Test("canonical video id", arguments: cases)
    func canonicalVideoID(testCase: YouTubeURLCase) throws {
        let url = try #require(testCase.parsed)
        #expect(YouTubeURLNormalizer.canonicalVideoID(from: url) == testCase.expectedID)
    }

    @Test("playlist classification", arguments: cases)
    func playlistClassification(testCase: YouTubeURLCase) throws {
        let url = try #require(testCase.parsed)
        #expect(YouTubeURLNormalizer.isPlaylistURL(url) == testCase.isPlaylist)
    }

    @Test("a URL is never both a video and a playlist", arguments: cases)
    func classificationsAreMutuallyExclusive(testCase: YouTubeURLCase) throws {
        let url = try #require(testCase.parsed)
        let hasID = YouTubeURLNormalizer.canonicalVideoID(from: url) != nil
        #expect(!(hasID && YouTubeURLNormalizer.isPlaylistURL(url)))
    }

    @Test("all four accepted families collapse to one canonical id")
    func familiesAgreeOnOneID() throws {
        let families = [
            "https://www.youtube.com/watch?v=\(Self.videoID)",
            "https://youtu.be/\(Self.videoID)",
            "https://www.youtube.com/shorts/\(Self.videoID)",
            "https://music.youtube.com/watch?v=\(Self.videoID)",
        ]
        let resolved = try families.map { string -> String in
            let url = try #require(URL(string: string))
            return try #require(YouTubeURLNormalizer.canonicalVideoID(from: url))
        }
        #expect(Set(resolved) == [Self.videoID])
    }
}
