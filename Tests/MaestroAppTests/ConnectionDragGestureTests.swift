import XCTest
import Observation
import MaestroCore
@testable import CodexMaestro

private final class DragInvalidationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); defer { lock.unlock() }; count += 1 }
}

final class ConnectionDragGestureTests: XCTestCase {
    private func node(_ endpoint: LinkEndpoint, x: CGFloat, y: CGFloat) -> TopologyNodeGeometry {
        TopologyNodeGeometry(endpoint: endpoint, point: CGPoint(x: x, y: y))
    }

    func testGestureCapturesMovementEligibilityUntilReset() {
        var gesture = TopologyGestureSession()
        for canMove in [true, false] {
            XCTAssertNil(gesture.mode)
            gesture.begin(canMove: canMove)
            let captured: TopologyGestureMode = canMove ? .position : .ignored
            XCTAssertEqual(gesture.mode, captured)
            gesture.begin(canMove: !canMove)
            XCTAssertEqual(gesture.mode, captured, "Eligibility changes cannot convert an active gesture")
            gesture.clear()
            XCTAssertNil(gesture.mode)
        }
    }

    func testConnectionControlUsesTypedCardBounds() {
        for endpoint in [LinkEndpoint.project("p"), .session("s")] {
            let item = node(endpoint, x: 445, y: 184)
            XCTAssertTrue(item.isConnectionControl(at: CGPoint(x: item.frame.maxX - 24, y: item.frame.maxY - 20)))
            XCTAssertFalse(item.isConnectionControl(at: item.point))
            XCTAssertFalse(item.isConnectionControl(at: CGPoint(x: item.frame.maxX + 1, y: item.frame.maxY - 20)))
        }
    }

    func testRectangleOverlapSupportsAllFourKindsWithoutPointerInsideTarget() {
        for sourceKind in [LinkEndpoint.project("source"), .session("source")] {
            for targetKind in [LinkEndpoint.project("target"), .session("target")] {
                let source = node(sourceKind, x: 160, y: 184)
                let target = node(targetKind, x: 445, y: 184)
                let moved = node(sourceKind, x: 270, y: 184)
                XCTAssertFalse(target.frame.contains(moved.point), "Item overlap is independent of pointer containment")
                XCTAssertEqual(TopologyConnectionHitTest.target(overlapping: moved, nodes: [source, target],
                    eligible: [sourceKind, targetKind]), targetKind)
            }
        }
    }

    func testOverlapRejectsGrazingSelfUnavailableAndSyntheticProject() {
        let source = node(.session("source"), x: 160, y: 184)
        let target = node(.session("target"), x: 445, y: 184)
        let grazing = node(source.endpoint, x: 225, y: 184) // Only 20pt of a 240pt card intersects.
        XCTAssertNil(TopologyConnectionHitTest.target(overlapping: grazing, nodes: [source, target], eligible: [source.endpoint, target.endpoint]))
        XCTAssertNil(TopologyConnectionHitTest.target(overlapping: source, nodes: [source], eligible: [source.endpoint]))
        let moved = node(source.endpoint, x: 445, y: 184)
        XCTAssertNil(TopologyConnectionHitTest.target(overlapping: moved, nodes: [target], eligible: [source.endpoint]))
        XCTAssertNil(TopologyConnectionHitTest.target(overlapping: moved, nodes: [target], eligible: [target.endpoint]))
        let synthetic = node(.project("unassigned"), x: 445, y: 184)
        XCTAssertNil(TopologyConnectionHitTest.target(overlapping: moved, nodes: [synthetic], eligible: [source.endpoint, synthetic.endpoint]))
    }

    func testOverlapUsesNearestCenterAndFrontmostTieBreakWithTypedIDs() {
        let moved = node(.session("source"), x: 445, y: 184)
        let nearest = node(.project("same"), x: 445, y: 184)
        let farther = node(.session("same"), x: 465, y: 184)
        let eligible: Set<LinkEndpoint> = [moved.endpoint, nearest.endpoint, farther.endpoint]
        XCTAssertEqual(TopologyConnectionHitTest.target(overlapping: moved, nodes: [nearest, farther], eligible: eligible), nearest.endpoint)
        let front = node(farther.endpoint, x: 445, y: 184)
        XCTAssertEqual(TopologyConnectionHitTest.target(overlapping: moved, nodes: [nearest, front], eligible: eligible), front.endpoint)
    }

    @MainActor func testTypedProjectMovementKeepsCanonicalOriginAndUnrelatedNodes() {
        let project = node(.project("same"), x: 160, y: 68)
        let session = node(.session("same"), x: 160, y: 184)
        let nodes = [project.endpoint: project, session.endpoint: session]
        let drag = TopologyDragState()
        drag.endpoint = project.endpoint; drag.basePoint = project.point
        drag.offset = CGSize(width: 40, height: 70)
        let moved = TopologyNodeProjection.moving(nodes: nodes, dragged: drag.endpoint, offset: drag.offset, basePoint: drag.basePoint)
        XCTAssertEqual(moved[project.endpoint]?.point, CGPoint(x: 200, y: 138))
        XCTAssertEqual(moved[session.endpoint]?.point, session.point)
        XCTAssertEqual(nodes[project.endpoint]?.point, project.point)
        drag.clear()
        XCTAssertNil(drag.endpoint); XCTAssertNil(drag.basePoint)
    }

    @MainActor func testEmptyReleaseAndCancellationCannotCompleteConnection() {
        let source = node(.project("source"), x: 160, y: 68)
        let target = node(.session("target"), x: 445, y: 184)
        let state = TopologyConnectionDragState()
        state.begin(source: source.endpoint)
        state.update(pointer: target.point, targets: [source, target], eligible: [source.endpoint, target.endpoint])
        XCTAssertEqual(state.completedTarget(from: source.endpoint), target.endpoint)
        state.update(pointer: CGPoint(x: 900, y: 550), targets: [source, target], eligible: [source.endpoint, target.endpoint])
        XCTAssertNil(state.completedTarget(from: source.endpoint))
        state.cancel()
        state.update(pointer: target.point, targets: [source, target], eligible: [source.endpoint, target.endpoint])
        XCTAssertNil(state.completedTarget(from: source.endpoint))
        XCTAssertNil(state.source)
        XCTAssertNil(state.target)
        XCTAssertTrue(state.cancelled)
        state.clear()
        XCTAssertFalse(state.cancelled)
    }

    @MainActor func test601SessionItemUpdatesInvalidateOnlyMovementNotLayoutOrStableTargetCue() {
        let store = PerformanceFixture.store(catalog: PerformanceFixture.catalog())
        let source = node(.session("stress-session-0"), x: 160, y: 184)
        let target = node(.project("stress-project-1"), x: 445, y: 68)
        let state = TopologyConnectionDragState()
        state.begin(source: source.endpoint)
        state.update(pointer: target.point, targets: [source, target], eligible: [source.endpoint, target.endpoint])
        let drag = TopologyDragState()
        drag.endpoint = source.endpoint; drag.basePoint = source.point
        let layout = DragInvalidationCounter(), cue = DragInvalidationCounter(), movement = DragInvalidationCounter()
        withObservationTracking {
            _ = store.filteredSessions
            _ = store.workspace.positions
            _ = store.orderedProjects(for: store.filteredSessions)
        } onChange: { layout.increment() }
        withObservationTracking { _ = state.target; _ = state.source } onChange: { cue.increment() }
        withObservationTracking { _ = drag.offset } onChange: { movement.increment() }
        for index in 1...120 {
            let point = CGPoint(x: target.point.x + CGFloat(index % 5), y: target.point.y + CGFloat(index % 3))
            drag.offset = CGSize(width: point.x - source.point.x, height: point.y - source.point.y)
            state.update(pointer: point,
                targets: [source, target], eligible: [source.endpoint, target.endpoint])
        }
        XCTAssertEqual(layout.value, 0)
        XCTAssertEqual(cue.value, 0, "Staying inside the same typed target must not invalidate card cues")
        XCTAssertEqual(movement.value, 1, "Observation fires once until the movement consumer registers its next evaluation")
        XCTAssertTrue(store.workspace.positions.isEmpty)
        state.cancel()
        XCTAssertEqual(cue.value, 1)
        XCTAssertEqual(layout.value, 0)
    }

}
