import XCTest
import MaestroCore
@testable import CodexMaestro

final class TopologyLabelPlacementTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 920, height: 570)
    private func session(_ point: CGPoint) -> CGRect {
        CGRect(x: point.x - 120, y: point.y - 56, width: 240, height: 112)
    }
    private func project(_ point: CGPoint) -> CGRect {
        CGRect(x: point.x - 120, y: point.y - 29, width: 240, height: 58)
    }
    private func assertClear(_ frame: CGRect, nodes: [CGRect], labels: [CGRect] = [], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(bounds.contains(frame), file: file, line: line)
        for node in nodes + labels {
            XCTAssertFalse(node.insetBy(dx: -2, dy: -2).intersects(frame), "Label must have clearance from nodes and other labels", file: file, line: line)
        }
    }

    func testSameRowSessionCaptionWiderThan45PointGapFindsFreeSpace() throws {
        let a = CGPoint(x: 160, y: 184), b = CGPoint(x: 445, y: 184)
        let nodes = [session(a), session(b), project(CGPoint(x: 160, y: 68)), project(CGPoint(x: 445, y: 68))]
        let size = CGSize(width: 78, height: 19)
        let preferred = TopologyLinkGeometry(a: a, b: b).midpoint
        let oldFrame = CGRect(x: preferred.x - size.width / 2, y: preferred.y - size.height / 2, width: size.width, height: size.height)
        XCTAssertTrue(nodes.contains { $0.intersects(oldFrame) }, "Fixture must reproduce the midpoint collision")
        let frame = try XCTUnwrap(TopologyLabelPlacement.frame(preferred: preferred, size: size, obstacles: nodes, occupied: [], bounds: bounds))
        assertClear(frame, nodes: nodes)
        XCTAssertNotEqual(frame.midY, preferred.y)
    }

    func testSameRowProjectCaptionAvoidsBoth58PointHeaderCards() throws {
        let a = CGPoint(x: 160, y: 68), b = CGPoint(x: 445, y: 68)
        let nodes = [project(a), project(b), session(CGPoint(x: 160, y: 184)), session(CGPoint(x: 445, y: 184))]
        let frame = try XCTUnwrap(TopologyLabelPlacement.frame(preferred: TopologyLinkGeometry(a: a, b: b).midpoint,
            size: CGSize(width: 78, height: 19), obstacles: nodes, occupied: [], bounds: bounds))
        assertClear(frame, nodes: nodes)
    }

    func testCaptionAvoidsInterveningSyncCardWhenPreferredLocationIsObstructed() throws {
        let a = CGPoint(x: 160, y: 184), b = CGPoint(x: 730, y: 184)
        let nodes = [session(a), session(b), session(CGPoint(x: 445, y: 184))]
        // Keep the label-placement obstruction even though the new long-row path avoids it.
        let preferred = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        XCTAssertTrue(nodes[2].contains(preferred))
        XCTAssertFalse(nodes[2].contains(TopologyLinkGeometry(a: a, b: b).midpoint))
        let frame = try XCTUnwrap(TopologyLabelPlacement.frame(preferred: preferred, size: CGSize(width: 65, height: 19), obstacles: nodes, occupied: [], bounds: bounds))
        assertClear(frame, nodes: nodes)
    }

    func testReverseAndParallelCaptionsReserveSeparateRectanglesDeterministically() throws {
        let a = CGPoint(x: 160, y: 184), b = CGPoint(x: 445, y: 184)
        let nodes = [session(a), session(b)]
        var occupied: [CGRect] = []
        for (source, target) in [(a, b), (b, a), (a, b)] {
            let preferred = TopologyLinkGeometry(a: source, b: target).midpoint
            let frame = try XCTUnwrap(TopologyLabelPlacement.frame(preferred: preferred, size: CGSize(width: 78, height: 19), obstacles: nodes, occupied: occupied, bounds: bounds))
            assertClear(frame, nodes: nodes, labels: occupied)
            XCTAssertEqual(frame, TopologyLabelPlacement.frame(preferred: preferred, size: CGSize(width: 78, height: 19), obstacles: nodes, occupied: occupied, bounds: bounds))
            occupied.append(frame)
        }
        XCTAssertEqual(occupied.count, 3)
    }

    func testBlockedSearchReturnsNoCaptionInsteadOfCoveringNode() {
        XCTAssertNil(TopologyLabelPlacement.frame(preferred: CGPoint(x: 460, y: 285), size: CGSize(width: 78, height: 19),
            obstacles: [bounds], occupied: [], bounds: bounds))
    }

    func testPrefilterIncludesObstacleBeyondCandidateCenterSearchRadius() {
        let largeBounds = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let obstacles = [CGRect(x: 0, y: 0, width: 280, height: 1000),
            CGRect(x: 350, y: 0, width: 650, height: 1000)]
        // The second obstacle begins beyond preferred.x + 240. A center-only
        // prefilter misses it, then incorrectly places an 80pt label into a 70pt gap.
        XCTAssertNil(TopologyLabelPlacement.frame(preferred: CGPoint(x: 100, y: 100), size: CGSize(width: 80, height: 19),
            obstacles: obstacles, occupied: [], bounds: largeBounds))
    }
}
