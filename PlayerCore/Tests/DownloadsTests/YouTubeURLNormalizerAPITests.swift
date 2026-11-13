// The non-table halves of `YouTubeURLNormalizer`: the free-text entry point, the
// playlist-id accessor, canonical URL rebuilding, and raw id validation.
import Foundation
import Services
import Testing

@Suite("YouTube URL normalizer API")
struct YouTubeURLNormalizerAPITests {
    static let videoID = "dQw4w9WgXcQ"

    @Test("free text is trimmed before parsing")
    func trimsSurroundingWhitespace() {
        let pasted = "  https://youtu.be/\(Self.videoID)\n"
        #expect(YouTubeURLNormalizer.canonicalVideoID(from: pasted) == Self.videoID)
    }

    @Test("free text that is not a URL is rejected", arguments: [
        "",
        "   ",
        "not a url at all",
        "dQw4w9WgXcQ",
        "youtube",
    ])
    func rejectsNonURLText(text: String) {
        #expect(YouTubeURLNormalizer.canonicalVideoID(from: text) == nil)
    }

    @Test("playlist id is readable even when the URL resolves to a single video")
    func playlistIDSurvivesPrecedence() throws {
        let url = try #require(
            URL(string: "https://www.youtube.com/watch?v=\(Self.videoID)&list=PLabcdefghijk")
        )
        #expect(YouTubeURLNormalizer.playlistID(from: url) == "PLabcdefghijk")
        #expect(!YouTubeURLNormalizer.isPlaylistURL(url))
    }

    @Test("playlist id is nil without a list item, and on foreign hosts")
    func playlistIDIsNilWhenAbsent() throws {
        let noList = try #require(URL(string: "https://www.youtube.com/watch?v=\(Self.videoID)"))
        let empty = try #require(URL(string: "https://www.youtube.com/playlist?list="))
        let foreign = try #require(URL(string: "https://vimeo.com/playlist?list=PLabcdefghijk"))
        #expect(YouTubeURLNormalizer.playlistID(from: noList) == nil)
        #expect(YouTubeURLNormalizer.playlistID(from: empty) == nil)
        #expect(YouTubeURLNormalizer.playlistID(from: foreign) == nil)
    }

    @Test("canonical URL rebuilds a noise-free watch link")
    func canonicalURLStripsNoise() throws {
        let pasted = try #require(
            URL(string: "https://music.youtube.com/watch?v=\(Self.videoID)&list=PLx&index=7&t=9s")
        )
        let videoID = try #require(YouTubeURLNormalizer.canonicalVideoID(from: pasted))
        let canonical = try #require(YouTubeURLNormalizer.canonicalURL(forVideoID: videoID))
        #expect(canonical.absoluteString == "https://www.youtube.com/watch?v=\(Self.videoID)")
        #expect(YouTubeURLNormalizer.canonicalVideoID(from: canonical) == Self.videoID)
        #expect(!YouTubeURLNormalizer.isPlaylistURL(canonical))
    }

    @Test("canonical URL rejects a malformed id")
    func canonicalURLRejectsMalformedID() {
        #expect(YouTubeURLNormalizer.canonicalURL(forVideoID: "tooshort") == nil)
    }

    @Test("isYouTubeURL recognizes the family without resolving a video")
    func recognizesFamilyIndependently() throws {
        let root = try #require(URL(string: "https://www.youtube.com/"))
        let foreign = try #require(URL(string: "https://vimeo.com/"))
        #expect(YouTubeURLNormalizer.isYouTubeURL(root))
        #expect(YouTubeURLNormalizer.canonicalVideoID(from: root) == nil)
        #expect(!YouTubeURLNormalizer.isYouTubeURL(foreign))
    }

    @Test("valid ids are exactly 11 base64url characters", arguments: [
        "dQw4w9WgXcQ",
        "___________",
        "-----------",
        "aA0_-zZ9bB1",
    ])
    func acceptsWellFormedIDs(candidate: String) {
        #expect(YouTubeURLNormalizer.isValidVideoID(candidate))
        #expect(candidate.count == YouTubeURLNormalizer.videoIDLength)
    }

    @Test("malformed ids are rejected", arguments: [
        "",
        "dQw4w9WgXc",
        "dQw4w9WgXcQQ",
        "dQw4w9WgXc+",
        "dQw4w9WgXc/",
        "dQw4w9WgXc ",
        "dQw4w9WgXcé",
        "dQw4w9WgXcЯ",
    ])
    func rejectsMalformedIDs(candidate: String) {
        #expect(!YouTubeURLNormalizer.isValidVideoID(candidate))
    }
}
