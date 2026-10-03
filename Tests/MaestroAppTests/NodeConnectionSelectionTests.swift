import XCTest
import MaestroCore
@testable import CodexMaestro

final class NodeConnectionSelectionTests: XCTestCase {
    @MainActor func testConnectionIconThenTargetClickCreatesAllEndpointCombinationsWithoutSending() throws {
        let store = MaestroStore(demo: true)
        let cases: [(LinkEndpoint, LinkEndpoint)] = [
            (.project("app"), .project("runner")), (.session("design"), .project("runner")),
            (.project("runner"), .session("design")), (.session("design"), .session("watch"))
        ]
        for (source, target) in cases {
            store.beginLink(from: source)
            store.selectEndpoint(target)
            let link = try XCTUnwrap(store.workspace.allNodeLinks.first { $0.source == source && $0.target == target && $0.kind == .context })
            XCTAssertEqual(store.actionSheetTarget?.id, link.id)
            XCTAssertNil(store.linkingEndpoint)
            XCTAssertTrue(store.workspace.drafts.isEmpty)
            XCTAssertTrue(store.workspace.connectionActions.isEmpty)
            XCTAssertTrue(store.sending.isEmpty)
            store.actionSheetTarget = nil
        }
        let existingLinks = store.workspace.allNodeLinks
        store.beginLink(from: .session("design"))
        store.selectEndpoint(.project("missing"))
        XCTAssertEqual(store.linkingEndpoint, .session("design"))
        XCTAssertNil(store.actionSheetTarget)
        XCTAssertEqual(store.workspace.allNodeLinks, existingLinks)
        store.cancelLink()
        XCTAssertNil(store.linkingEndpoint)
    }

    @MainActor func testMixedConnectionsPreserveSessionMembershipDraftsAndExecutionState() {
        let store = MaestroStore(demo: true)
        let sessions = store.sessions
        store.workspace.drafts["design"] = "original"
        store.selectEndpoint(.session("design"))
        XCTAssertTrue(store.saveNodeLink(NodeLink(source: .session("design"), target: .project("runner"), kind: .dependency)))
        XCTAssertTrue(store.saveNodeLink(NodeLink(source: .project("studio"), target: .session("design"), kind: .review)))
        XCTAssertEqual(store.sessions, sessions)
        XCTAssertEqual(store.workspace.drafts, ["design": "original"])
        XCTAssertEqual(store.selectedSessionID, "design")
        XCTAssertTrue(store.sending.isEmpty)
        XCTAssertFalse(store.events.contains { $0.text.contains("프롬프트 전달") })
    }

    @MainActor func testRelatedEmptyProjectsRemainVisibleAndFiltersDoNotLeakOtherProjectNodes() {
        let store = MaestroStore(demo: true)
        store.projects.append(Project(id: "empty", name: "Empty"))
        store.scope = "recent"
        XCTAssertTrue(store.saveNodeLink(NodeLink(source: .session("design"), target: .project("empty"), kind: .context)))
        XCTAssertTrue(store.visibleProjects.contains { $0.id == "empty" })
        store.selectedProjectID = "runner"
        XCTAssertEqual(store.visibleProjects.map(\.id), ["runner"])
        store.selectedProjectID = "empty"
        XCTAssertTrue(store.filteredSessions.isEmpty)
        XCTAssertEqual(store.visibleProjects.map(\.id), ["empty"])
        XCTAssertFalse(store.endpointExists(.project("unassigned")))
    }
}
