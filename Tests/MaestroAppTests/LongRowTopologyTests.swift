import XCTest
import MaestroCore
@testable import CodexMaestro

final class LongRowTopologyTests: XCTestCase {
    private func geometry(_ endpoint: LinkEndpoint, x: CGFloat, y: CGFloat) -> TopologyNodeGeometry {
        TopologyNodeGeometry(endpoint: endpoint, point: CGPoint(x: x, y: y))
    }
    private func point(_ curve: TopologyLinkGeometry, at t: CGFloat) -> CGPoint {
        let u = 1 - t
        return CGPoint(x: u * u * u * curve.from.x + 3 * u * u * t * curve.control1.x + 3 * u * t * t * curve.control2.x + t * t * t * curve.to.x,
            y: u * u * u * curve.from.y + 3 * u * u * t * curve.control1.y + 3 * u * t * t * curve.control2.y + t * t * t * curve.to.y)
    }

    func testNonAdjacentSessionsInBothDirectionsAvoidWatchAndProjectHeaders() {
        let design = geometry(.session("design"), x: 160, y: 184)
        let models = geometry(.session("models"), x: 730, y: 184)
        let watch = geometry(.session("watch"), x: 445, y: 184)
        let headers = [geometry(.project("app"), x: 160, y: 68),
            geometry(.project("runner"), x: 445, y: 68), geometry(.project("studio"), x: 730, y: 68)]
        let obstacles = [watch.frame] + headers.map(\.frame)
        for (source, target) in [(design, models), (models, design)] {
            let curve = TopologyLinkGeometry(source: source, target: target)
            XCTAssertEqual(curve.from, CGPoint(x: source.point.x, y: source.frame.minY))
            XCTAssertEqual(curve.to, CGPoint(x: target.point.x, y: target.frame.minY))
            XCTAssertEqual(curve.control1.y, 110)
            XCTAssertEqual(curve.control2.y, 110)
            XCTAssertGreaterThan(curve.control1.y, headers[1].frame.maxY)
            XCTAssertLessThan(curve.control1.y, watch.frame.minY)
            for step in 1..<1000 {
                let location = point(curve, at: CGFloat(step) / 1000)
                XCTAssertLessThan(location.y, watch.frame.minY)
                XCTAssertGreaterThan(location.y, headers[1].frame.maxY)
                XCTAssertFalse(obstacles.contains { $0.contains(location) })
            }
            XCTAssertLessThan(curve.control2.y, curve.to.y, "Arrow tangent points down into the target's top edge")
        }
    }

    func testNonAdjacentProjectsInBothDirectionsAvoidMiddleHeader() {
        let a = geometry(.project("a"), x: 160, y: 68)
        let b = geometry(.project("b"), x: 730, y: 68)
        let middle = geometry(.project("middle"), x: 445, y: 68)
        for (source, target) in [(a, b), (b, a)] {
            let curve = TopologyLinkGeometry(source: source, target: target)
            XCTAssertEqual(curve.from.y, 39)
            XCTAssertEqual(curve.to.y, 39)
            XCTAssertEqual(curve.control1.y, 21)
            XCTAssertEqual(curve.control2.y, 21)
            for step in 1..<1000 {
                let location = point(curve, at: CGFloat(step) / 1000)
                XCTAssertGreaterThan(location.y, 0)
                XCTAssertLessThan(location.y, middle.frame.minY)
                XCTAssertFalse(middle.frame.contains(location))
            }
        }
    }

    func testSmallSessionPlacementOffsetsKeepLongCorridorClearInBothDirections() {
        let watch = geometry(.session("watch"), x: 445, y: 184)
        let headers = [geometry(.project("app"), x: 160, y: 68),
            geometry(.project("runner"), x: 445, y: 68), geometry(.project("studio"), x: 730, y: 68)]
        let obstacles = [watch.frame] + headers.map(\.frame)
        for movedEndpoint in ["design", "models"] {
            for dx in [CGFloat(-20), 20] {
                for dy in [CGFloat(-18), -12, 12, 18] {
                    let design = geometry(.session("design"), x: 160 + (movedEndpoint == "design" ? dx : 0),
                        y: 184 + (movedEndpoint == "design" ? dy : 0))
                    let models = geometry(.session("models"), x: 730 + (movedEndpoint == "models" ? dx : 0),
                        y: 184 + (movedEndpoint == "models" ? dy : 0))
                    for (source, target) in [(design, models), (models, design)] {
                        let curve = TopologyLinkGeometry(source: source, target: target)
                        let scenario = "\(movedEndpoint) offset (\(dx), \(dy)), \(source.endpoint.id) to \(target.endpoint.id)"
                        XCTAssertEqual(curve.from, CGPoint(x: source.point.x, y: source.frame.minY), scenario)
                        XCTAssertEqual(curve.to, CGPoint(x: target.point.x, y: target.frame.minY), scenario)
                        let corridor = min(source.frame.minY, target.frame.minY) - TopologyLinkGeometry.longRowClearance
                        XCTAssertEqual(curve.control1, CGPoint(x: curve.from.x, y: corridor), scenario)
                        XCTAssertEqual(curve.control2, CGPoint(x: curve.to.x, y: corridor), scenario)
                        for step in 1..<1000 {
                            let location = point(curve, at: CGFloat(step) / 1000)
                            XCTAssertFalse(obstacles.contains { $0.contains(location) }, "\(scenario), sample \(step)")
                        }
                        XCTAssertEqual(curve.control2.x, curve.to.x, scenario)
                        XCTAssertLessThan(curve.control2.y, curve.to.y, "\(scenario): arrow enters target top edge downward")
                    }
                }
            }
        }
    }

    func testAdjacentSameRowRelationKeepsSideAnchorsAndMixedTopsUseTypedHeights() {
        let session = geometry(.session("s"), x: 160, y: 184)
        let adjacent = geometry(.session("adjacent"), x: 445, y: 184)
        let side = TopologyLinkGeometry(source: session, target: adjacent)
        XCTAssertEqual(side.from, CGPoint(x: session.frame.maxX, y: session.point.y))
        XCTAssertEqual(side.to, CGPoint(x: adjacent.frame.minX, y: adjacent.point.y))
        let project = geometry(.project("p"), x: 730, y: 184)
        let mixed = TopologyLinkGeometry(source: session, target: project)
        XCTAssertEqual(mixed.from.y, session.frame.minY)
        XCTAssertEqual(mixed.to.y, project.frame.minY)
        XCTAssertEqual(mixed.control1.y, min(session.frame.minY, project.frame.minY) - 18)
        XCTAssertEqual(mixed.control1.y, mixed.control2.y)
    }
}
