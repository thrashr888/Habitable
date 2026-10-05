import Foundation

/// Computes deterministic orthogonal paths between map cards without depending on SwiftUI.
enum MapConnectionRoute {
    private static let clearance = 10.0
    private static let epsilon = 0.001

    static func points(from source: MapCanvasTile, to target: MapCanvasTile,
                       avoiding placements: [MapCanvasTile], canvasWidth: Double) -> [CGPoint] {
        let obstacles = placements
            .filter { $0.id != source.id && $0.id != target.id }
            .map { Rect(minX: $0.x - clearance, minY: $0.y - clearance,
                        maxX: $0.x + $0.width + clearance, maxY: $0.y + $0.height + clearance) }
        let endpointCards = [source, target].map {
            Rect(minX: $0.x, minY: $0.y, maxX: $0.x + $0.width, maxY: $0.y + $0.height)
        }
        let blockers = obstacles + endpointCards

        let sourceCenter = CGPoint(x: source.x + source.width / 2, y: source.y + source.height / 2)
        let targetCenter = CGPoint(x: target.x + target.width / 2, y: target.y + target.height / 2)
        let dx = targetCenter.x - sourceCenter.x
        let dy = targetCenter.y - sourceCenter.y

        // Prefer the facing edges, while retaining every side as a fallback when cards are staggered.
        let sourceSides: [Side] = abs(dx) >= abs(dy)
            ? (dx >= 0 ? [.right, .bottom, .top, .left] : [.left, .bottom, .top, .right])
            : (dy >= 0 ? [.bottom, .right, .left, .top] : [.top, .right, .left, .bottom])
        let targetSides: [Side] = abs(dx) >= abs(dy)
            ? (dx >= 0 ? [.left, .top, .bottom, .right] : [.right, .top, .bottom, .left])
            : (dy >= 0 ? [.top, .left, .right, .bottom] : [.bottom, .left, .right, .top])

        let xs = unique([12, max(12, canvasWidth - 12)] + obstacles.flatMap { [$0.minX, $0.maxX] } + [source.x, source.x + source.width, target.x, target.x + target.width])
        let ys = unique(obstacles.flatMap { [$0.minY, $0.maxY] } + [source.y, source.y + source.height, target.y, target.y + target.height])
        var best: [CGPoint]?
        var bestCost = Double.infinity

        for (sourceRank, sourceSide) in sourceSides.enumerated() {
            let start = sourceSide.point(on: source)
            let lead = sourceSide.lead(from: start)
            for (targetRank, targetSide) in targetSides.enumerated() {
                let end = targetSide.point(on: target)
                let endLead = targetSide.lead(from: end)
                var candidates: [[CGPoint]] = []
                candidates.append([start, lead, endLead, end])
                candidates.append([start, lead, CGPoint(x: endLead.x, y: lead.y), endLead, end])
                candidates.append([start, lead, CGPoint(x: lead.x, y: endLead.y), endLead, end])
                for x in xs {
                    candidates.append([start, lead, CGPoint(x: x, y: lead.y), CGPoint(x: x, y: endLead.y), endLead, end])
                }
                for y in ys {
                    candidates.append([start, lead, CGPoint(x: lead.x, y: y), CGPoint(x: endLead.x, y: y), endLead, end])
                }
                for candidate in candidates {
                    let path = simplify(candidate)
                    guard isOrthogonal(path), isClear(path, obstacles: blockers) else { continue }
                    let length = zip(path, path.dropFirst()).reduce(0.0) { $0 + abs($1.0.x - $1.1.x) + abs($1.0.y - $1.1.y) }
                    let bends = max(0, path.count - 2)
                    let cost = length + Double(bends) * 0.01 + Double(sourceRank + targetRank) * 0.001
                    if cost < bestCost { bestCost = cost; best = path }
                }
            }
        }

        return best ?? []
    }

    private enum Side { case left, right, top, bottom
        func point(on tile: MapCanvasTile) -> CGPoint {
            switch self {
            case .left: CGPoint(x: tile.x, y: tile.y + tile.height / 2)
            case .right: CGPoint(x: tile.x + tile.width, y: tile.y + tile.height / 2)
            case .top: CGPoint(x: tile.x + tile.width / 2, y: tile.y)
            case .bottom: CGPoint(x: tile.x + tile.width / 2, y: tile.y + tile.height)
            }
        }
        func lead(from point: CGPoint) -> CGPoint {
            switch self {
            case .left: CGPoint(x: point.x - clearance, y: point.y)
            case .right: CGPoint(x: point.x + clearance, y: point.y)
            case .top: CGPoint(x: point.x, y: point.y - clearance)
            case .bottom: CGPoint(x: point.x, y: point.y + clearance)
            }
        }
    }

    private struct Rect {
        let minX: Double, minY: Double, maxX: Double, maxY: Double
        func blocks(_ a: CGPoint, _ b: CGPoint) -> Bool {
            if abs(a.y - b.y) < epsilon {
                let lo = min(a.x, b.x), hi = max(a.x, b.x)
                return a.y > minY + epsilon && a.y < maxY - epsilon && hi > minX + epsilon && lo < maxX - epsilon
            }
            if abs(a.x - b.x) < epsilon {
                let lo = min(a.y, b.y), hi = max(a.y, b.y)
                return a.x > minX + epsilon && a.x < maxX - epsilon && hi > minY + epsilon && lo < maxY - epsilon
            }
            return true
        }
    }

    private static func unique(_ values: [Double]) -> [Double] {
        Array(Set(values.filter(\.isFinite))).sorted()
    }
    private static func simplify(_ points: [CGPoint]) -> [CGPoint] {
        var result: [CGPoint] = []
        for point in points where result.last != point { result.append(point) }
        var index = 1
        while index + 1 < result.count {
            let a = result[index - 1], b = result[index], c = result[index + 1]
            if (abs(a.x - b.x) < epsilon && abs(b.x - c.x) < epsilon) ||
                (abs(a.y - b.y) < epsilon && abs(b.y - c.y) < epsilon) { result.remove(at: index) }
            else { index += 1 }
        }
        return result
    }
    private static func isOrthogonal(_ points: [CGPoint]) -> Bool {
        points.count >= 2 && zip(points, points.dropFirst()).allSatisfy { abs($0.x - $1.x) < epsilon || abs($0.y - $1.y) < epsilon }
    }
    private static func isClear(_ points: [CGPoint], obstacles: [Rect]) -> Bool {
        zip(points, points.dropFirst()).allSatisfy { a, b in obstacles.allSatisfy { !$0.blocks(a, b) } }
    }
}
