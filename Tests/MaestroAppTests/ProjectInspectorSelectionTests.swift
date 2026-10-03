import XCTest
import MaestroCore
@testable import CodexMaestro

private actor ProjectInspectorReadGate {
    private var read: CheckedContinuation<[TranscriptMessage], Never>?
    private var started: CheckedContinuation<Void, Never>?
    func transcript() async -> [TranscriptMessage] {
        await withCheckedContinuation { continuation in
            read = continuation; started?.resume(); started = nil
        }
    }
    func waitForRead() async {
        if read != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func complete() {
        read?.resume(returning: [TranscriptMessage(id: "old", role: "assistant", text: "Previous session")]); read = nil
    }
}

final class ProjectInspectorSelectionTests: XCTestCase {
    @MainActor func testUnassignedInspectorMatchesGroupingTotalsAndDirectionalLinkMembership() {
        let store = MaestroStore(demo: true)
        store.scope = "all"
        let statuses: [SessionStatus] = [.running, .waiting, .idle]
        store.sessions = statuses.enumerated().map { index, status in
            var session = Session(id: "unassigned-\(index)", title: "Fixture", projectID: nil, cwd: "")
            session.status = status; return session
        }
        var registered = Session(id: "registered", title: "Registered", projectID: "app", cwd: "")
        registered.status = .running
        store.sessions.append(registered)
        let outgoing = ProjectLink(source: "unassigned", target: "app", kind: .context)
        let incoming = ProjectLink(source: "runner", target: "unassigned", kind: .review)
        let unrelated = ProjectLink(source: "app", target: "runner", kind: .dependency)
        store.workspace.projectLinks = [outgoing, incoming, unrelated]
        let project = store.visibleProjects.first { $0.id == "unassigned" }!
        store.selectProjectNode(project)
        let summary = ProjectInspectorSummary(project: store.selectedNodeProject!, sessions: store.sessions, nodeLinks: store.workspace.allNodeLinks)
        XCTAssertEqual(summary.sessionCount, 3)
        XCTAssertEqual(summary.sessionCount, store.count(in: "unassigned"))
        XCTAssertEqual(summary.sessionCount, store.displayedSessions(in: project).count)
        XCTAssertEqual(summary.runningCount, 1, "Registered running sessions must not inflate the unassigned inspector")
        XCTAssertEqual(summary.incidentLinks, [NodeLink(outgoing), NodeLink(incoming)], "Both relationship directions count; unrelated project links do not")
        let registeredSummary = ProjectInspectorSummary(project: store.projects.first { $0.id == "app" }!, sessions: store.sessions, nodeLinks: store.workspace.allNodeLinks)
        XCTAssertEqual(registeredSummary.sessionCount, 1)
        XCTAssertEqual(registeredSummary.runningCount, 1)
        XCTAssertEqual(registeredSummary.incidentLinks, [NodeLink(outgoing), NodeLink(unrelated)])
    }
    @MainActor func testProjectNodeSelectionPreservesCatalogScopeAndSessionDrafts() {
        let store = MaestroStore(demo: true)
        store.selectedProjectID = "runner"; store.scope = "all"
        store.workspace.drafts["bridge"] = "Retained task"
        store.transcriptError = "Previous read failed"
        store.beginLink(from: .session("bridge"))
        store.selectProjectNode(store.projects.first { $0.id == "app" }!)
        XCTAssertEqual(store.selectedNodeProject?.id, "app")
        XCTAssertEqual(store.selectedProjectID, "runner", "Node selection must not change sidebar filtering")
        XCTAssertEqual(store.scope, "all")
        XCTAssertNil(store.selectedSessionID)
        XCTAssertTrue(store.transcript.isEmpty)
        XCTAssertNil(store.transcriptError)
        XCTAssertNil(store.linkingEndpoint)
        XCTAssertEqual(store.draft(for: "bridge"), "Retained task")
        store.selectProjectNode(store.projects.first { $0.id == "studio" }!)
        XCTAssertEqual(store.selectedNodeProject?.id, "studio", "Related project navigation must retain project-inspector mode")
        XCTAssertEqual(store.selectedProjectID, "runner")
        store.select(store.sessions.first { $0.id == "watch" }!)
        XCTAssertNil(store.selectedNodeProjectID)
        XCTAssertEqual(store.selectedSessionID, "watch")
    }
    @MainActor func testLateSessionTranscriptCannotPublishUnderProjectInspector() async {
        let gate = ProjectInspectorReadGate()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("project-inspector-\(UUID().uuidString)")
        let store = MaestroStore(persistence: WorkspacePersistence(url: directory.appendingPathComponent("workspace.json")), transcriptReader: { _ in await gate.transcript() })
        let project = Project(id: "p", name: "Fixture")
        store.projects = [project]
        store.sessions = [Session(id: "a", title: "A", projectID: "p", cwd: "")]
        store.selectSessionID("a")
        let oldRead = Task { await store.loadTranscript("a") }
        await gate.waitForRead()
        XCTAssertTrue(store.transcriptLoading)
        store.selectProjectNode(project)
        XCTAssertFalse(store.transcriptLoading)
        await gate.complete(); await oldRead.value
        XCTAssertEqual(store.selectedNodeProject?.id, "p")
        XCTAssertNil(store.selectedSessionID)
        XCTAssertTrue(store.transcript.isEmpty)
        XCTAssertNil(store.transcriptError)
    }
    @MainActor func testPreparedConnectionReturnsFromProjectInspectorToReceivingSessionWithAllProjectsVisible() async {
        let store = MaestroStore(demo: true)
        store.selectProjectNode(store.projects.first { $0.id == "app" }!)
        let link = NodeLink(source: .session("bridge"), target: .session("watch"), kind: .review)
        XCTAssertTrue(store.saveNodeLink(link))
        let config = ConnectionActionConfiguration(function: .handoff, executionSide: .target)
        let success = await store.prepareConnectionAction(link: link, config: config)
        XCTAssertTrue(success)
        XCTAssertNil(store.selectedNodeProjectID)
        XCTAssertEqual(store.selectedSessionID, "watch")
        XCTAssertNil(store.selectedProjectID)
        XCTAssertEqual(store.scope, "all")
        XCTAssertEqual(Set(store.visibleProjects.map(\.id)), Set(store.projects.map(\.id)))
        XCTAssertTrue(store.draft(for: "watch").contains("codex://threads/bridge"))
        XCTAssertEqual(store.workspace.connectionActions[link.id.uuidString], config)
        XCTAssertTrue(store.sending.isEmpty)
    }
}
