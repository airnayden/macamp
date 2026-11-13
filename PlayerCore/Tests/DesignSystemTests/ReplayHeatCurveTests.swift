// Locks the geometry of the replay-heat curve (plan todo 12).
//
// `ReplayHeatGeometry.path(for:in:)` is a pure static precisely so the SHAPE can be
// asserted instead of eyeballed: these tests pin the exact element stream for a
// hand-computable input, prove the smoothing scheme's element counts at the shipped
// 100-bucket width, and prove that every "nothing to show" input yields a genuinely
// EMPTY path rather than a degenerate baseline sliver (which would paint a hairline
// across the scrubber of every never-replayed track).
import CoreGraphics
@testable import DesignSystem
import SwiftUI
import Testing

@Suite("ReplayHeatCurveTests")
struct ReplayHeatCurveTests {
    private static let rect = CGRect(x: 0, y: 0, width: 100, height: 20)

    // MARK: Nothing to draw

    @Test("empty input renders nothing")
    func emptyInputRendersNothing() {
        #expect(ReplayHeatGeometry.path(for: [], in: Self.rect).isEmpty)
        #expect(!ReplayHeatGeometry.hasContent([]))
    }

    @Test("an all-zero row renders nothing — a never-replayed track draws no hairline")
    func allZeroRowRendersNothing() {
        let buckets = [Float](repeating: 0, count: ReplayHeatGeometry.bucketCount)
        #expect(!ReplayHeatGeometry.hasContent(buckets))
        #expect(ReplayHeatGeometry.path(for: buckets, in: Self.rect).isEmpty)
    }

    @Test("a single bucket renders nothing — one point spans no curve")
    func singleBucketRendersNothing() {
        #expect(!ReplayHeatGeometry.hasContent([1]))
        #expect(ReplayHeatGeometry.path(for: [1], in: Self.rect).isEmpty)
    }

    @Test("a non-finite-only row renders nothing")
    func nonFiniteOnlyRowRendersNothing() {
        #expect(!ReplayHeatGeometry.hasContent([.nan, .infinity, .nan]))
    }

    @Test("a zero-area rect renders nothing")
    func zeroAreaRectRendersNothing() {
        let buckets: [Float] = [0, 1, 0.5, 0]
        #expect(ReplayHeatGeometry.path(for: buckets, in: CGRect(x: 0, y: 0, width: 0, height: 20)).isEmpty)
        #expect(ReplayHeatGeometry.path(for: buckets, in: CGRect(x: 0, y: 0, width: 100, height: 0)).isEmpty)
    }

    // MARK: Golden geometry

    @Test("the element stream is exactly the quadratic-midpoint scheme (golden)")
    func elementStreamIsGolden() {
        let path = ReplayHeatGeometry.path(for: [0, 1, 0.5, 0], in: Self.rect)
        // Sample points sit at column midpoints (12.5 / 37.5 / 62.5 / 87.5) with
        // y = 20 − intensity·20, so the interior control points are the buckets
        // themselves and every `to:` is the midpoint of two neighbours.
        #expect(pathElements(path) == [
            "M 0.000,20.000",
            "L 12.500,20.000",
            "L 25.000,10.000",
            "Q 50.000,5.000 c 37.500,0.000",
            "Q 75.000,15.000 c 62.500,10.000",
            "L 87.500,20.000",
            "L 100.000,20.000",
            "L 100.000,20.000",
            "L 0.000,20.000",
            "Z",
        ])
    }

    @Test("the same input always yields the same path")
    func generationIsDeterministic() {
        let buckets = (0 ..< ReplayHeatGeometry.bucketCount).map { Float($0 % 7) / 6 }
        let first = ReplayHeatGeometry.path(for: buckets, in: Self.rect)
        let second = ReplayHeatGeometry.path(for: buckets, in: Self.rect)
        #expect(pathElements(first) == pathElements(second))
        #expect(!pathElements(first).isEmpty)
    }

    @Test("100 buckets produce one quadratic per interior span")
    func bucketCountProducesExpectedElementCounts() {
        var buckets = [Float](repeating: 0.25, count: ReplayHeatGeometry.bucketCount)
        buckets[42] = 1
        let elements = pathElements(ReplayHeatGeometry.path(for: buckets, in: Self.rect))

        #expect(elements.count(where: { $0.hasPrefix("M") }) == 1)
        #expect(elements.count(where: { $0.hasPrefix("Q") }) == ReplayHeatGeometry.bucketCount - 2)
        #expect(elements.count(where: { $0.hasPrefix("L") }) == 6)
        #expect(elements.count(where: { $0 == "Z" }) == 1)
    }

    // MARK: Sampling

    @Test("intensities map 0 to the baseline and 1 to the top of the rect")
    func intensitiesMapAcrossTheFullHeight() {
        let points = ReplayHeatGeometry.points(for: [0, 1], in: Self.rect)
        #expect(points.count == 2)
        #expect(points[0].y == Self.rect.maxY)
        #expect(points[1].y == Self.rect.minY)
        #expect(points[0].x == 25)
        #expect(points[1].x == 75)
    }

    @Test("out-of-range clamps to the edges; non-finite reads as zero, never as a peak")
    func outOfRangeIntensitiesAreClamped() {
        let points = ReplayHeatGeometry.points(for: [-4, 9, .nan, .infinity], in: Self.rect)
        #expect(points.allSatisfy { $0.y >= Self.rect.minY && $0.y <= Self.rect.maxY })
        #expect(points[0].y == Self.rect.maxY)
        #expect(points[1].y == Self.rect.minY)
        // A corrupt bucket must not paint a full-height spike, so `nan`/`inf`
        // collapse to the baseline rather than clamping up to 1.
        #expect(points[2].y == Self.rect.maxY)
        #expect(points[3].y == Self.rect.maxY)
    }

    @Test("the filled area spans the full width of its rect")
    func filledAreaSpansFullWidth() {
        let bounds = ReplayHeatGeometry.path(for: [0.2, 1, 0.4], in: Self.rect).boundingRect
        #expect(bounds.minX == Self.rect.minX)
        #expect(bounds.maxX == Self.rect.maxX)
    }
}

// MARK: - Element dump

private extension ReplayHeatCurveTests {
    /// A stable, readable rendering of a `Path`'s element stream, so a golden
    /// assertion names the segment that broke instead of printing an opaque blob.
    func pathElements(_ path: Path) -> [String] {
        var elements: [String] = []
        // `Path.forEach` is SwiftUI's element visitor, not `Sequence.forEach` —
        // `preferForLoop` would rewrite it into a `for … in path` that cannot compile.
        // swiftformat:disable:next preferForLoop
        path.forEach { element in
            switch element {
            case let .move(to: point):
                elements.append("M \(format(point))")
            case let .line(to: point):
                elements.append("L \(format(point))")
            case let .quadCurve(to: point, control: control):
                elements.append("Q \(format(point)) c \(format(control))")
            case let .curve(to: point, control1: first, control2: second):
                elements.append("C \(format(point)) c \(format(first)) \(format(second))")
            case .closeSubpath:
                elements.append("Z")
            }
        }
        return elements
    }

    func format(_ point: CGPoint) -> String {
        String(format: "%.3f,%.3f", point.x, point.y)
    }
}
