// YouTubeSearchLinkTests — the encoding contract of the one URL a suggestion opens.
//
// The assertions are on the ABSOLUTE STRING, not on a round-trip through
// `URLComponents`, because a round-trip would pass for an encoding that is legal but
// wrong (a literal `+` decodes back to `+` locally and is read as a SPACE by the
// endpoint). What the endpoint receives is the only thing that matters here.
import Foundation
import Testing
import ViewModels

@Suite("YouTube search link")
struct YouTubeSearchLinkTests {
    private static let prefix = "https://www.youtube.com/results?search_query="

    private func query(_ title: String, _ artist: String?) throws -> String {
        let url = try #require(YouTubeSearchLink.url(title: title, artist: artist))
        let absolute = url.absoluteString
        #expect(absolute.hasPrefix(Self.prefix))
        return String(absolute.dropFirst(Self.prefix.count))
    }

    @Test("spaces become %20 and the apostrophe survives verbatim")
    func spacesAreEncodedAndApostrophesAreNot() throws {
        #expect(try query("November Rain", "Guns N' Roses") == "November%20Rain%20Guns%20N'%20Roses")
    }

    @Test("an ampersand is escaped so it cannot start a second query parameter")
    func ampersandIsEscaped() throws {
        let encoded = try query("Scenes From An Italian Restaurant", "Simon & Garfunkel")
        #expect(encoded.contains("Simon%20%26%20Garfunkel"))
        #expect(!encoded.contains("&"))
    }

    @Test("a plus is escaped, because a literal one is read as a space")
    func plusIsEscaped() throws {
        // The exact failure `queryItems` would have shipped: `+` is in
        // `urlQueryAllowed`, so the stock encoder leaves it alone and the endpoint
        // searches for a space instead.
        let encoded = try query("Everything Everything +", nil)
        #expect(encoded == "Everything%20Everything%20%2B")
    }

    @Test("diacritics are encoded as UTF-8, not stripped or folded")
    func diacriticsAreEncodedAsUTF8() throws {
        #expect(try query("Jóga", "Björk") == "J%C3%B3ga%20Bj%C3%B6rk")
    }

    @Test("CJK is encoded as UTF-8 percent triples")
    func cjkIsEncodedAsUTF8() throws {
        #expect(try query("Lemon", "米津玄師") == "Lemon%20%E7%B1%B3%E6%B4%A5%E7%8E%84%E5%B8%AB")
    }

    @Test("a miss with no artist searches for the title alone")
    func nilArtistSearchesTheTitleAlone() throws {
        #expect(try query("Riders On The Storm", nil) == "Riders%20On%20The%20Storm")
    }

    @Test("a blank artist is dropped rather than encoded as a trailing space")
    func blankArtistIsDropped() throws {
        #expect(try query("Riders On The Storm", "   ") == "Riders%20On%20The%20Storm")
        #expect(
            YouTubeSearchLink.url(title: "Riders On The Storm", artist: "")
                == YouTubeSearchLink.url(title: "Riders On The Storm", artist: nil)
        )
    }

    @Test("nothing to search for produces no link at all")
    func anEmptyTitleProducesNoURL() {
        #expect(YouTubeSearchLink.url(title: "", artist: nil) == nil)
        #expect(YouTubeSearchLink.url(title: "  \n ", artist: "  ") == nil)
    }

    @Test("the title is trimmed, so a padded miss does not search for its padding")
    func termsAreTrimmed() throws {
        #expect(try query("  November Rain  ", "  Guns N' Roses ") == "November%20Rain%20Guns%20N'%20Roses")
    }
}
