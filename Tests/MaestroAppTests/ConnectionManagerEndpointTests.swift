import XCTest
import MaestroCore
@testable import CodexMaestro

final class ConnectionManagerEndpointTests: XCTestCase {
    @MainActor private func fixture() -> MaestroStore {
        let store = MaestroStore(demo: true)
        store.workspace = WorkspaceState()
        store.projects = [Project(id: "same", name: "Project same"), Project(id: "other", name: "Project other")]
        store.sessions = [Session(id: "same", title: "Session same", projectID: "same", cwd: ""), Session(id: "other", title: "Session other", projectID: nil, cwd: "")]
        return store
    }
    @MainActor func testAllFourDirectionsRenderInManagerAndTypedInspectorMembership() {
        let store = fixture()
        let combinations: [(LinkEndpoint, LinkEndpoint)] = [(.session("same"), .session("other")), (.project("same"), .project("other")), (.session("same"), .project("same")), (.project("same"), .session("same"))]
        let originalSessions = store.sessions
        store.workspace.drafts["same"] = "Existing task"
        for (source, target) in combinations { XCTAssertTrue(store.saveNodeLink(NodeLink(source: source, target: target, kind: .context))) }
        XCTAssertEqual(store.workspace.allNodeLinks.count, 4)
        for direction in ConnectionDirection.allCases {
            let matches = store.workspace.allNodeLinks.filter { direction.includes($0) }
            XCTAssertEqual(matches.count, direction == .all ? 4 : 1, "Every endpoint direction must have a manager filter")
        }
        let projectLinks = EndpointConnections.related(to: .project("same"), in: store.workspace.allNodeLinks)
        let sessionLinks = EndpointConnections.related(to: .session("same"), in: store.workspace.allNodeLinks)
        XCTAssertEqual(projectLinks.count, 3)
        XCTAssertEqual(sessionLinks.count, 3)
        XCTAssertFalse(projectLinks.contains { $0.source.kind == .session && $0.target.kind == .session })
        XCTAssertFalse(sessionLinks.contains { $0.source.kind == .project && $0.target.kind == .project })
        let summary = ProjectInspectorSummary(project: store.projects[0], sessions: store.sessions, nodeLinks: store.workspace.allNodeLinks)
        XCTAssertEqual(summary.incidentLinks, projectLinks)
        XCTAssertEqual(store.sessions, originalSessions)
        XCTAssertEqual(store.draft(for: "same"), "Existing task")
        XCTAssertTrue(store.sending.isEmpty)
    }
    @MainActor func testManagerDraftSeedsSelectedTypedEndpointAndRespectsDirectionFilter() {
        let store = fixture()
        let sessionDraft = ConnectionDraft.new(direction: .all, selected: .session("same"), projects: store.projects, sessions: store.sessions)
        XCTAssertEqual(sessionDraft.source, .session("same"))
        XCTAssertEqual(sessionDraft.target, .project("same"), "Equal raw IDs are distinct endpoints when their node types differ")
        let projectDraft = ConnectionDraft.new(direction: .projectSession, selected: .project("other"), projects: store.projects, sessions: store.sessions)
        XCTAssertEqual(projectDraft.source, .project("other"))
        XCTAssertEqual(projectDraft.target.kind, .session)
        let filtered = ConnectionDraft.new(direction: .sessionProject, selected: .project("other"), projects: store.projects, sessions: store.sessions)
        XCTAssertEqual(filtered.source.kind, .session)
        XCTAssertEqual(filtered.target.kind, .project)
        let unavailable = ConnectionDraft.new(direction: .all, selected: .project("unassigned"), projects: store.projects, sessions: store.sessions)
        XCTAssertNotEqual(unavailable.source, .project("unassigned"))
    }
    @MainActor func testEditingEndpointKindsMovesStorageBucketWithoutChangingIdentity() {
        let store = fixture()
        let sessionLink = NodeLink(source: .session("same"), target: .session("other"), kind: .review, note: "Retained note")
        XCTAssertTrue(store.saveNodeLink(sessionLink))
        var editor = ConnectionDraft(link: sessionLink)
        editor.target = .project("other")
        XCTAssertTrue(store.saveNodeLink(editor.link))
        XCTAssertTrue(store.workspace.links.isEmpty)
        XCTAssertEqual(store.workspace.nodeLinks, [editor.link])
        editor.source = .project("same")
        XCTAssertTrue(store.saveNodeLink(editor.link))
        XCTAssertTrue(store.workspace.nodeLinks.isEmpty)
        XCTAssertEqual(store.workspace.projectLinks.first?.id, sessionLink.id)
        XCTAssertEqual(store.workspace.projectLinks.first?.note, "Retained note")
        XCTAssertEqual(store.workspace.allNodeLinks.count, 1)
        XCTAssertTrue(store.deleteNodeLink(editor.link))
        XCTAssertTrue(store.workspace.allNodeLinks.isEmpty)
    }
    @MainActor func testFailedBucketChangingEditRestoresAllStorageArrays() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MaestroStore(persistence: WorkspacePersistence(url: directory.appendingPathComponent("workspace.json")))
        store.projects = [Project(id: "p", name: "P")]
        store.sessions = [Session(id: "a", title: "A", projectID: "p", cwd: ""), Session(id: "b", title: "B", projectID: "p", cwd: "")]
        let original = NodeLink(source: .session("a"), target: .session("b"), kind: .review)
        XCTAssertTrue(store.saveNodeLink(original))
        let before = store.workspace
        try FileManager.default.removeItem(at: directory)
        try Data("Blocked parent".utf8).write(to: directory)
        var editor = ConnectionDraft(link: original); editor.target = .project("p")
        XCTAssertFalse(store.saveNodeLink(editor.link))
        XCTAssertEqual(store.workspace.links, before.links)
        XCTAssertEqual(store.workspace.projectLinks, before.projectLinks)
        XCTAssertEqual(store.workspace.nodeLinks, before.nodeLinks)
        XCTAssertEqual(store.workspace.allNodeLinks, [original])
        XCTAssertFalse(store.deleteNodeLink(original))
        XCTAssertEqual(store.workspace.allNodeLinks, [original])
    }
}
