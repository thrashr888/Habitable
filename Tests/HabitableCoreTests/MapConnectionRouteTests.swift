import XCTest
@testable import HabitableCore

final class MapConnectionRouteTests: XCTestCase {
    private func tile(_ id: String, _ x: Double, _ y: Double, _ width: Double = 100, _ height: Double = 60) -> MapCanvasTile {
        MapCanvasTile(id: id, x: x, y: y, width: width, height: height)
    }

    private func assertOrthogonal(_ points: [CGPoint], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThanOrEqual(points.count, 2, file: file, line: line)
        for (a, b) in zip(points, points.dropFirst()) {
            XCTAssertTrue(a.x == b.x || a.y == b.y, "segment must be orthogonal: \(a) to \(b)", file: file, line: line)
        }
    }

    func testHorizontalRoutesPreserveDirectionAndUseNearbyEdges() {
        let left = tile("left", 20, 20), right = tile("right", 190, 20)
        let forward = MapConnectionRoute.points(from: left, to: right, avoiding: [left, right], canvasWidth: 400)
        let backward = MapConnectionRoute.points(from: right, to: left, avoiding: [left, right], canvasWidth: 400)
        assertOrthogonal(forward)
        assertOrthogonal(backward)
        XCTAssertEqual(forward.first, CGPoint(x: 120, y: 50))
        XCTAssertEqual(forward.last, CGPoint(x: 190, y: 50))
        XCTAssertEqual(backward.first, CGPoint(x: 190, y: 50))
        XCTAssertEqual(backward.last, CGPoint(x: 120, y: 50))
        XCTAssertLessThanOrEqual(forward.count, 3)
        XCTAssertLessThanOrEqual(backward.count, 3)
    }

    func testVerticalAdjacentTilesConnectDirectly() {
        let upper = tile("upper", 20, 20), lower = tile("lower", 20, 100)
        let route = MapConnectionRoute.points(from: upper, to: lower, avoiding: [upper, lower], canvasWidth: 300)
        assertOrthogonal(route)
        XCTAssertEqual(route.first, CGPoint(x: 70, y: 80))
        XCTAssertEqual(route.last, CGPoint(x: 70, y: 100))
        XCTAssertEqual(route.count, 2)
    }

    func testRouteGoesAroundInterveningCard() {
        let source = tile("source", 10, 30), target = tile("target", 310, 30)
        let blocker = tile("blocker", 145, 0, 100, 120)
        let route = MapConnectionRoute.points(from: source, to: target, avoiding: [source, target, blocker], canvasWidth: 450)
        assertOrthogonal(route)
        XCTAssertEqual(route.first, CGPoint(x: 110, y: 60))
        XCTAssertEqual(route.last, CGPoint(x: 310, y: 60))
        for (a, b) in zip(route, route.dropFirst()) {
            XCTAssertFalse(segment(a, b, intersects: blocker), "route crossed blocker: \(a) to \(b)")
        }
        XCTAssertGreaterThan(route.count, 2)
    }

    func testDifferentSourceAndTargetProduceReversedEndpoints() {
        let a = tile("a", 30, 20), b = tile("b", 180, 130)
        let route = MapConnectionRoute.points(from: a, to: b, avoiding: [a, b], canvasWidth: 400)
        assertOrthogonal(route)
        XCTAssertEqual(route.first, CGPoint(x: 130, y: 50))
        XCTAssertEqual(route.last, CGPoint(x: 180, y: 160))
        for card in [a, b] {
            for (start, end) in zip(route, route.dropFirst()) {
                XCTAssertFalse(segment(start, end, intersects: card), "route crossed endpoint card \(card.id)")
            }
        }
    }

    func testRoundedStraightRouteRemainsOneLineAndPreservesEndpoints() {
        let start = CGPoint(x: 2, y: 3), end = CGPoint(x: 20, y: 3)
        XCTAssertEqual(MapConnectionRoute.roundedSegments(for: [start, end]), [.move(to: start), .line(to: end)])
    }

    func testRoundedLeftAndRightTurnsUseQuadraticCorners() {
        for points in [[CGPoint(x: 0, y: 0), CGPoint(x: 20, y: 0), CGPoint(x: 20, y: 20)],
                       [CGPoint(x: 20, y: 0), CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 20)]] {
            let segments = MapConnectionRoute.roundedSegments(for: points, radius: 8)
            XCTAssertTrue(segments.contains { if case .quadCurve = $0 { return true }; return false })
            if case .move(let start) = segments.first { XCTAssertEqual(start, points[0]) }
            else { XCTFail("expected a move segment") }
            if case .line(let end) = segments.last { XCTAssertEqual(end, points[2]) }
            else { XCTFail("expected an exact terminal line") }
        }
    }

    func testShortSegmentClampsCornerRadiusAndNeverOvershoots() {
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: 6, y: 0), CGPoint(x: 6, y: 30)]
        let segments = MapConnectionRoute.roundedSegments(for: points, radius: 20)
        XCTAssertEqual(segments, [
            .move(to: points[0]), .line(to: CGPoint(x: 3, y: 0)),
            .quadCurve(control: points[1], to: CGPoint(x: 6, y: 3)), .line(to: points[2])
        ])
    }

    func testDuplicateCollinearAndReversingPointsStayFiniteAndOrdered() {
        let p0 = CGPoint(x: 0, y: 0), p1 = CGPoint(x: 10, y: 0), p2 = CGPoint(x: 0, y: 0)
        let segments = MapConnectionRoute.roundedSegments(for: [p0, p0, p1, CGPoint(x: 20, y: 0), p2])
        XCTAssertEqual(segments.first, .move(to: p0))
        XCTAssertEqual(segments.last, .line(to: p2))
        XCTAssertFalse(segments.isEmpty)
        for segment in segments {
            switch segment {
            case .move(let point), .line(let point): XCTAssertTrue(point.x.isFinite && point.y.isFinite)
            case .quadCurve(let control, let point): XCTAssertTrue(control.x.isFinite && control.y.isFinite && point.x.isFinite && point.y.isFinite)
            }
        }
        XCTAssertFalse(segments.contains { if case .quadCurve = $0 { return true }; return false }, "a 180 degree reversal must remain sharp")
    }

    private func segment(_ a: CGPoint, _ b: CGPoint, intersects tile: MapCanvasTile) -> Bool {
        if a.y == b.y {
            return a.y > tile.y && a.y < tile.y + tile.height && max(min(a.x, b.x), tile.x) < min(max(a.x, b.x), tile.x + tile.width)
        }
        return a.x > tile.x && a.x < tile.x + tile.width && max(min(a.y, b.y), tile.y) < min(max(a.y, b.y), tile.y + tile.height)
    }
}
