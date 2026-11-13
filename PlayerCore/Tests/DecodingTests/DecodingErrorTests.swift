import Decoding
import Foundation
import Testing

@Suite("DecodingErrorTests")
struct DecodingErrorTests {
    private let url = URL(fileURLWithPath: "/music/song.flac")

    @Test("every case's description names the offending file")
    func descriptionsNameFile() {
        let cases: [DecodingError] = [
            .ioError(url: url, underlying: "disk gone"),
            .unsupportedFormat(url: url),
            .corruptedFile(url: url, reason: "bad frame"),
            .truncated(url: url),
            .unsupportedSampleRate(url: url, detail: "DSD128 (5644800 Hz)"),
        ]
        for error in cases {
            #expect(error.description.contains("song.flac"))
            #expect(error.errorDescription == error.description)
        }
    }

    @Test("every case resolves a distinct localized message through the String Catalog")
    func everyCaseHasALocalizedMessage() {
        let messages = [
            DecodingError.ioError(url: url, underlying: "x"),
            .unsupportedFormat(url: url),
            .corruptedFile(url: url, reason: "x"),
            .truncated(url: url),
            .unsupportedSampleRate(url: url, detail: "DSD128 (5644800 Hz)"),
        ].map { String(localized: $0.message) }

        #expect(Set(messages).count == messages.count)
        for message in messages {
            #expect(!message.isEmpty)
            // A user-facing message never leaks the file path the diagnostic carries.
            #expect(!message.contains("/music/song.flac"))
        }
    }

    @Test("the underlying message is preserved in an ioError description")
    func ioErrorPreservesUnderlying() {
        let error = DecodingError.ioError(url: url, underlying: "permission denied")
        #expect(error.description.contains("permission denied"))
    }

    @Test("the url accessor returns the associated file for every case")
    func urlAccessor() {
        #expect(DecodingError.ioError(url: url, underlying: "x").url == url)
        #expect(DecodingError.unsupportedFormat(url: url).url == url)
        #expect(DecodingError.corruptedFile(url: url, reason: "x").url == url)
        #expect(DecodingError.truncated(url: url).url == url)
        #expect(DecodingError.unsupportedSampleRate(url: url, detail: "x").url == url)
    }

    @Test("DecodingError is Equatable across cases and payloads")
    func equatable() {
        #expect(DecodingError.truncated(url: url) == DecodingError.truncated(url: url))
        #expect(DecodingError.unsupportedFormat(url: url) != DecodingError.truncated(url: url))
        #expect(
            DecodingError.corruptedFile(url: url, reason: "a")
                != DecodingError.corruptedFile(url: url, reason: "b")
        )
    }
}
