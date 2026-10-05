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

    private func segment(_ a: CGPoint, _ b: CGPoint, intersects tile: MapCanvasTile) -> Bool {
        if a.y == b.y {
            return a.y > tile.y && a.y < tile.y + tile.height && max(min(a.x, b.x), tile.x) < min(max(a.x, b.x), tile.x + tile.width)
        }
        return a.x > tile.x && a.x < tile.x + tile.width && max(min(a.y, b.y), tile.y) < min(max(a.y, b.y), tile.y + tile.height)
    }
}
