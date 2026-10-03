import XCTest
import MaestroCore
@testable import CodexMaestro

final class MixedTopologyTests: XCTestCase {
    private func geometry(_ endpoint: LinkEndpoint, x: CGFloat, y: CGFloat) -> TopologyNodeGeometry {
        TopologyNodeGeometry(endpoint: endpoint, point: CGPoint(x: x, y: y))
    }

    func testFourEndpointCombinationsPreserveDirectionAndNamespaces() {
        let project = LinkEndpoint.project("shared"), session = LinkEndpoint.session("shared")
        let otherProject = LinkEndpoint.project("other"), otherSession = LinkEndpoint.session("other")
        let nodes = [project: geometry(project, x: 160, y: 68), session: geometry(session, x: 160, y: 184),
            otherProject: geometry(otherProject, x: 445, y: 68), otherSession: geometry(otherSession, x: 445, y: 184)]
        let links = [NodeLink(source: project, target: otherProject, kind: .context),
            NodeLink(source: session, target: otherSession, kind: .dependency),
            NodeLink(source: project, target: otherSession, kind: .review),
            NodeLink(source: session, target: otherProject, kind: .context),
            NodeLink(source: project, target: session, kind: .review)]
        let edges = TopologyNodeProjection.edges(links: links, nodes: nodes)
        XCTAssertEqual(edges.map(\.link), links)
        XCTAssertEqual(edges.map { $0.source.endpoint }, links.map(\.source))
        XCTAssertEqual(edges.map { $0.target.endpoint }, links.map(\.target))
        XCTAssertEqual(edges.last?.source.point, CGPoint(x: 160, y: 68))
        XCTAssertEqual(edges.last?.target.point, CGPoint(x: 160, y: 184))
        XCTAssertFalse(edges[0].touches(session), "Same string ID in project namespace is not a dragged session")
        XCTAssertTrue(edges[4].touches(session))
    }

    func testMixedHighlightingFindsIncomingAndOutgoingTypedNeighbors() {
        let selected = LinkEndpoint.project("shared")
        let links = [NodeLink(source: selected, target: .session("shared"), kind: .context),
            NodeLink(source: selected, target: .session("shared"), kind: .review),
            NodeLink(source: .session("incoming"), target: selected, kind: .review),
            NodeLink(source: selected, target: .project("peer"), kind: .dependency),
            NodeLink(source: .session("shared"), target: .session("unrelated"), kind: .review)]
        XCTAssertEqual(TopologyRelatedNodes.endpoints(selected: selected, links: links), [.session("shared"), .session("incoming"), .project("peer")])
        XCTAssertEqual(TopologyRelatedNodes.endpoints(selected: .session("shared"), links: links), [.project("shared"), .session("unrelated")])
        XCTAssertTrue(TopologyRelatedNodes.endpoints(selected: nil, links: links).isEmpty)
        XCTAssertTrue(TopologyRelatedNodes.endpoints(selected: .session("missing"), links: links).isEmpty)
    }

    func testMixedSameColumnArrowsUseProjectAndSessionSideBoundariesInBothDirections() {
        let project = geometry(.project("p"), x: 160, y: 68)
        let session = geometry(.session("s"), x: 160, y: 184)
        XCTAssertEqual(project.frame.height, 58)
        XCTAssertEqual(session.frame.height, 112)
        let down = TopologyLinkGeometry(source: project, target: session)
        XCTAssertEqual(down.from.x, project.frame.maxX)
        XCTAssertEqual(down.to.x, session.frame.maxX)
        XCTAssertGreaterThan(down.from.y, project.frame.minY)
        XCTAssertLessThan(down.from.y, project.frame.maxY)
        XCTAssertGreaterThan(down.to.y, session.frame.minY)
        XCTAssertLessThan(down.to.y, session.frame.maxY)
        let up = TopologyLinkGeometry(source: session, target: project)
        XCTAssertEqual(up.from.x, session.frame.maxX)
        XCTAssertEqual(up.to.x, project.frame.maxX)
        XCTAssertGreaterThan(up.to.y, project.frame.minY)
        XCTAssertLessThan(up.to.y, project.frame.maxY)
        XCTAssertGreaterThan(down.control2.x, down.to.x)
        XCTAssertGreaterThan(up.control2.x, up.to.x, "Arrow tangent points into the target's side in either direction")
    }

    func testLongMixedEdgeAndReverseStayOutsideInterveningDesignAndBridgeCards() {
        let project = geometry(.project("app"), x: 160, y: 68)
        let test = geometry(.session("test"), x: 160, y: 456)
        let bodies = [geometry(.session("design"), x: 160, y: 184).frame,
            geometry(.session("bridge"), x: 160, y: 320).frame]
        for (source, target) in [(project, test), (test, project)] {
            let curve = TopologyLinkGeometry(source: source, target: target)
            let rightBoundary = bodies.map(\.maxX).max()!
            XCTAssertEqual(curve.from.x, source.frame.maxX)
            XCTAssertEqual(curve.to.x, target.frame.maxX)
            // The cubic convex hull stays on or beyond the common right edge.
            // Both inner controls are strictly outside, so all interior points are outside.
            XCTAssertGreaterThan(curve.control1.x, rightBoundary)
            XCTAssertGreaterThan(curve.control2.x, rightBoundary)
            for step in 1..<1000 {
                let t = CGFloat(step) / 1000, u = 1 - t
                let point = CGPoint(x: u * u * u * curve.from.x + 3 * u * u * t * curve.control1.x + 3 * u * t * t * curve.control2.x + t * t * t * curve.to.x,
                    y: u * u * u * curve.from.y + 3 * u * u * t * curve.control1.y + 3 * u * t * t * curve.control2.y + t * t * t * curve.to.y)
                XCTAssertGreaterThan(point.x, rightBoundary)
                XCTAssertLessThan(point.x, 325, "The side rail stays in the default 45pt column gap")
                XCTAssertFalse(bodies.contains { $0.contains(point) })
            }
            XCTAssertGreaterThan(curve.control2.x, curve.to.x)
        }
    }

    func testDraggingSessionWithSharedProjectIDMovesOnlyTypedIncidentEdges() {
        let project = LinkEndpoint.project("shared"), session = LinkEndpoint.session("shared")
        let target = LinkEndpoint.project("target")
        let nodes = [project: geometry(project, x: 160, y: 68), session: geometry(session, x: 160, y: 184), target: geometry(target, x: 445, y: 68)]
        let links = [NodeLink(source: project, target: target, kind: .context),
            NodeLink(source: session, target: target, kind: .review)]
        let moved = TopologyNodeProjection.moving(nodes: nodes, dragged: session, offset: CGSize(width: 35, height: 20), basePoint: CGPoint(x: 170, y: 190))
        XCTAssertEqual(moved[project]?.point, nodes[project]?.point)
        XCTAssertEqual(moved[session]?.point, CGPoint(x: 205, y: 210))
        let edges = TopologyNodeProjection.edges(links: links, nodes: moved)
        XCTAssertEqual(edges.filter { $0.touches(session) }.map(\.link.id), [links[1].id])
        XCTAssertEqual(edges.filter { !$0.touches(session) }.map(\.link.id), [links[0].id])
        XCTAssertEqual(nodes[session]?.point, CGPoint(x: 160, y: 184), "Projection must leave canonical saved positions unchanged")
    }

    func testMixedCaptionAvoidsBothCardSizesAndFilteredEndpointIsOmitted() throws {
        let project = geometry(.project("p"), x: 160, y: 68)
        let session = geometry(.session("s"), x: 445, y: 184)
        let nodes = [project.endpoint: project, session.endpoint: session]
        let visible = NodeLink(source: project.endpoint, target: session.endpoint, kind: .review)
        let filtered = NodeLink(source: project.endpoint, target: .session("hidden"), kind: .context)
        XCTAssertEqual(TopologyNodeProjection.edges(links: [visible, filtered], nodes: nodes).map(\.link.id), [visible.id])
        let frame = try XCTUnwrap(TopologyLabelPlacement.frame(preferred: TopologyLinkGeometry(source: project, target: session).midpoint,
            size: CGSize(width: 78, height: 19), obstacles: [project.frame, session.frame], occupied: [], bounds: CGRect(x: 0, y: 0, width: 920, height: 570)))
        XCTAssertFalse(frame.intersects(project.frame.insetBy(dx: -2, dy: -2)))
        XCTAssertFalse(frame.intersects(session.frame.insetBy(dx: -2, dy: -2)))
    }
}
