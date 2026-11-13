import Foundation
import Metadata
import Testing

@Suite("MetadataErrorTests")
struct MetadataErrorTests {
    private let url = URL(fileURLWithPath: "/music/song.flac")

    @Test("every case's description names the offending file")
    func descriptionsNameFile() {
        let cases: [MetadataError] = [
            .ioError(url: url, underlying: "disk gone"),
            .unsupportedFormat(url: url),
            .corruptedFile(url: url, reason: "bad atom"),
        ]
        for error in cases {
            #expect(error.description.contains("song.flac"))
            #expect(error.errorDescription == error.description)
        }
    }

    @Test("the underlying message is preserved in an ioError description")
    func ioErrorPreservesUnderlying() {
        let error = MetadataError.ioError(url: url, underlying: "permission denied")
        #expect(error.description.contains("permission denied"))
    }

    @Test("the url accessor returns the associated file for every case")
    func urlAccessor() {
        #expect(MetadataError.ioError(url: url, underlying: "x").url == url)
        #expect(MetadataError.unsupportedFormat(url: url).url == url)
        #expect(MetadataError.corruptedFile(url: url, reason: "x").url == url)
    }

    @Test("MetadataError is Equatable across cases and payloads")
    func equatable() {
        #expect(MetadataError.unsupportedFormat(url: url) == MetadataError.unsupportedFormat(url: url))
        #expect(MetadataError.unsupportedFormat(url: url) != MetadataError.ioError(url: url, underlying: "x"))
        #expect(
            MetadataError.corruptedFile(url: url, reason: "a")
                != MetadataError.corruptedFile(url: url, reason: "b")
        )
    }
}
