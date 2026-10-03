import XCTest
import MaestroCore
@testable import CodexMaestro

final class TopologyDesignTests: XCTestCase {
    @MainActor func testProjectNodeSelectionKeeps601SessionGraphScopeAndSavedCoordinates() {
        let store = PerformanceFixture.store(catalog: PerformanceFixture.catalog())
        let original = store.filteredSessions
        store.workspace.positions["stress-session-0"] = NodePosition(x: 425, y: 831)
        store.selectSessionID("stress-session-0")
        store.selectProjectNode(store.projects[1])
        XCTAssertEqual(store.selectedNodeProjectID, store.projects[1].id)
        XCTAssertNil(store.selectedSessionID)
        XCTAssertNil(store.selectedProjectID, "Project node selection controls the inspector, not the sidebar scope")
        XCTAssertEqual(store.filteredSessions, original)
        XCTAssertEqual(store.position(for: "stress-session-0", fallback: .zero), CGPoint(x: 425, y: 831))
        store.select(store.sessions[0])
        XCTAssertNil(store.selectedNodeProjectID)
        XCTAssertEqual(store.selectedSessionID, "stress-session-0")
    }
}
