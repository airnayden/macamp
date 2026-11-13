import Foundation

/// Loads the committed libbs2b 3.1.0 reference impulse responses.
///
/// The CSVs live under `tools/fixtures/bs2b/vectors/` and are located by path via
/// `#filePath`, so the suite reads the SAME artifacts the generator produced rather
/// than a second copy. Tests NEVER invoke the generator — see that directory's
/// README for provenance.
enum CrossfeedFixtures {
    struct ImpulseResponse {
        var outLeft: [Double]
        var outRight: [Double]
    }

    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("tools/fixtures/bs2b/vectors", isDirectory: true)

    static func impulseResponse(preset: String) throws -> ImpulseResponse {
        let url = directory.appendingPathComponent("\(preset)-44100.csv")
        let text = try String(contentsOf: url, encoding: .utf8)

        var outLeft: [Double] = []
        var outRight: [Double] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("#") || line.hasPrefix("n,") { continue }
            let columns = line.split(separator: ",")
            guard columns.count == 3,
                  let left = Double(columns[1]),
                  let right = Double(columns[2])
            else {
                throw CocoaError(.fileReadCorruptFile)
            }
            outLeft.append(left)
            outRight.append(right)
        }
        return ImpulseResponse(outLeft: outLeft, outRight: outRight)
    }
}
