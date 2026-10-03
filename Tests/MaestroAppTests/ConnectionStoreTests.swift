import XCTest
import MaestroCore
@testable import CodexMaestro

final class ConnectionStoreTests: XCTestCase {
    @MainActor func testTypedConnectionCompletionValidatesEndpointsAndReusesExistingIdentity() throws {
        let store = MaestroStore(demo: true)
        store.beginLink(from: .session("design"))
        XCTAssertFalse(store.completeConnectionDrag(from: .session("design"), to: .session("missing")))
        XCTAssertEqual(store.linkingEndpoint, .session("design"))
        let existing = try XCTUnwrap(store.workspace.allNodeLinks.first { $0.source == .session("design") && $0.target == .session("bridge") && $0.kind == .context })
        let links = store.workspace.allNodeLinks
        XCTAssertFalse(store.saveNodeLink(NodeLink(source: existing.source, target: existing.target, kind: existing.kind)), "A duplicate new link must still be rejected")
        XCTAssertEqual(store.workspace.allNodeLinks, links)
        XCTAssertTrue(store.completeConnectionDrag(from: existing.source, to: existing.target), "The icon completion path reuses an existing relation")
        XCTAssertEqual(store.actionSheetTarget?.id, existing.id)
        XCTAssertEqual(store.workspace.allNodeLinks, links)
        XCTAssertNil(store.linkingEndpoint)
        store.sessions.removeAll { $0.id == "design" }
        store.beginLink(from: .session("design"))
        XCTAssertFalse(store.completeConnectionDrag(from: .session("design"), to: .session("watch")), "A removed source cannot form a new link")
        XCTAssertEqual(store.linkingEndpoint, .session("design"))
        store.beginLink(from: .session("bridge"))
        XCTAssertTrue(store.completeConnectionDrag(from: .session("bridge"), to: .session("watch")))
        XCTAssertNil(store.linkingEndpoint)
        XCTAssertTrue(store.workspace.allNodeLinks.contains { $0.source == .session("bridge") && $0.target == .session("watch") && $0.kind == .context })
        XCTAssertTrue(store.sending.isEmpty)
    }
    @MainActor func testProjectCRUDRejectsUnavailableEndpointsAndDuplicates() {
        let store = MaestroStore(demo: true)
        let link = ProjectLink(source: "app", target: "runner", kind: .dependency, note: "shared release")
        XCTAssertTrue(store.saveNodeLink(NodeLink(link)))
        XCTAssertEqual(store.workspace.projectLinks, [link])
        XCTAssertFalse(store.saveNodeLink(NodeLink(ProjectLink(source: "app", target: "runner", kind: .dependency))))
        XCTAssertFalse(store.saveNodeLink(NodeLink(ProjectLink(source: "missing", target: "runner", kind: .review))))
        XCTAssertEqual(store.workspace.projectLinks, [link])
        var changed = link; changed.note = "revised"; changed.kind = .review
        XCTAssertTrue(store.saveNodeLink(NodeLink(changed)))
        XCTAssertEqual(store.workspace.projectLinks, [changed])
        XCTAssertTrue(store.deleteNodeLink(NodeLink(changed)))
        XCTAssertTrue(store.workspace.projectLinks.isEmpty)
        XCTAssertEqual(store.workspace.links.count, 3, "Project changes must not mutate session links")
    }
    @MainActor func testSessionCRUDRejectsUnavailableEndpointAndPreservesIdentity() {
        let store = MaestroStore(demo: true)
        let before = store.workspace.links
        let link = SessionLink(source: "design", target: "watch", kind: .review, note: "cross project")
        XCTAssertTrue(store.saveNodeLink(NodeLink(link)))
        XCTAssertEqual(store.workspace.links.count, before.count + 1)
        var changed = link; changed.target = "sync"; changed.note = "revised"
        XCTAssertTrue(store.saveNodeLink(NodeLink(changed)))
        XCTAssertEqual(store.workspace.links.last, changed)
        XCTAssertFalse(store.saveNodeLink(NodeLink(SessionLink(source: "design", target: "unavailable", kind: .context))))
        XCTAssertEqual(store.workspace.links.last, changed)
        XCTAssertTrue(store.deleteNodeLink(NodeLink(changed)))
        XCTAssertEqual(store.workspace.links, before)
    }
    @MainActor func testProjectRelationDoesNotReassignSessionOrSendPrompt() {
        let store = MaestroStore(demo: true)
        let original = store.sessions
        store.workspace.drafts["bridge"] = "retained draft"
        XCTAssertTrue(store.saveNodeLink(NodeLink(ProjectLink(source: "app", target: "runner", kind: .context))))
        XCTAssertEqual(store.sessions, original)
        XCTAssertEqual(store.workspace.drafts["bridge"], "retained draft")
        XCTAssertTrue(store.sending.isEmpty)
        XCTAssertFalse(store.events.contains { $0.text.contains("프롬프트 전달") })
    }
    @MainActor func testFailedWritesRollBackConnectionAddsUpdatesAndDeletes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = WorkspacePersistence(url: directory.appendingPathComponent("workspace.json"))
        let store = MaestroStore(persistence: persistence)
        store.projects = [Project(id: "p", name: "P"), Project(id: "q", name: "Q")]
        store.sessions = [Session(id: "a", title: "A", projectID: "p", cwd: ""), Session(id: "b", title: "B", projectID: "q", cwd: "")]
        let project = ProjectLink(source: "p", target: "q", kind: .context)
        let session = SessionLink(source: "a", target: "b", kind: .context)
        XCTAssertTrue(store.saveNodeLink(NodeLink(project))); XCTAssertTrue(store.saveNodeLink(NodeLink(session)))
        // Replace the parent with a file, forcing subsequent writes to fail deterministically.
        try FileManager.default.removeItem(at: directory)
        try Data("blocking parent".utf8).write(to: directory)
        var changedProject = project; changedProject.note = "unsaved"
        XCTAssertFalse(store.saveNodeLink(NodeLink(changedProject)))
        XCTAssertFalse(store.saveNodeLink(NodeLink(ProjectLink(source: "q", target: "p", kind: .review))))
        XCTAssertFalse(store.deleteNodeLink(NodeLink(project)))
        XCTAssertEqual(store.workspace.projectLinks, [project])
        var changedSession = session; changedSession.note = "unsaved"
        XCTAssertFalse(store.saveNodeLink(NodeLink(changedSession)))
        XCTAssertFalse(store.saveNodeLink(NodeLink(SessionLink(source: "b", target: "a", kind: .review))))
        XCTAssertFalse(store.deleteNodeLink(NodeLink(session)))
        XCTAssertEqual(store.workspace.links, [session])
        XCTAssertNotNil(store.error)
        XCTAssertEqual(try Data(contentsOf: directory), Data("blocking parent".utf8))
        store.beginLink(from: .session("a"))
        XCTAssertFalse(store.saveNodeLink(NodeLink(source: .session("a"), target: .session("b"), kind: .review)))
        XCTAssertEqual(store.workspace.links, [session])
        XCTAssertEqual(store.linkingEndpoint, .session("a"))
        store.cancelLink()
        XCTAssertNil(store.linkingEndpoint)
    }
    @MainActor func testCorruptWorkspaceBlocksWritesAndPreservesSourceBytes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = WorkspacePersistence(url: directory.appendingPathComponent("workspace.json"))
        let corrupt = Data("bad source bytes".utf8)
        try corrupt.write(to: persistence.url)
        let store = MaestroStore(persistence: persistence)
        store.projects = [Project(id: "p", name: "P"), Project(id: "q", name: "Q")]
        store.sessions = [Session(id: "a", title: "A", projectID: "p", cwd: ""), Session(id: "b", title: "B", projectID: "q", cwd: "")]
        XCTAssertFalse(store.saveNodeLink(NodeLink(ProjectLink(source: "p", target: "q", kind: .context))))
        XCTAssertFalse(store.saveNodeLink(NodeLink(SessionLink(source: "a", target: "b", kind: .review))))
        XCTAssertTrue(store.workspace.projectLinks.isEmpty)
        XCTAssertTrue(store.workspace.links.isEmpty)
        XCTAssertEqual(try Data(contentsOf: persistence.url), corrupt)
        XCTAssertNotNil(store.error)
    }
    @MainActor func testConnectionPreparationFailedSavePreservesWorkspaceSelectionAndNotice() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MaestroStore(persistence: WorkspacePersistence(url: directory.appendingPathComponent("workspace.json")), catalog: CodexCatalog(home: directory))
        store.projects = [Project(id: "p", name: "P"), Project(id: "q", name: "Q")]
        store.sessions = [Session(id: "a", title: "A", projectID: "p", cwd: "", preview: "fixture context"), Session(id: "b", title: "B", projectID: "q", cwd: "")]
        let link = NodeLink(source: .session("a"), target: .session("b"), kind: .context)
        XCTAssertTrue(store.saveNodeLink(link))
        store.selectedSessionID = "a"; store.selectedProjectID = "p"; store.scope = "recent"; store.search = "original search"
        store.notice = "Existing notice"
        store.workspace.drafts = ["a": "other draft", "b": ""]
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let before = try encoder.encode(store.workspace)
        let events = store.events.count
        try FileManager.default.removeItem(at: directory)
        try Data("blocking parent".utf8).write(to: directory)
        let success = await store.prepareConnectionAction(link: link, config: ConnectionActionConfiguration(function: .handoff, executionSide: .target), preparedPrompt: "Prepared action")
        XCTAssertFalse(success)
        XCTAssertEqual(try encoder.encode(store.workspace), before, "Draft and configuration mutations must both roll back after a real save failure")
        XCTAssertEqual(store.selectedSessionID, "a"); XCTAssertEqual(store.selectedProjectID, "p")
        XCTAssertEqual(store.scope, "recent"); XCTAssertEqual(store.search, "original search")
        XCTAssertEqual(store.notice, "Existing notice"); XCTAssertEqual(store.events.count, events)
        XCTAssertNil(store.selectedNodeProjectID)
        XCTAssertTrue(store.error?.contains("작업공간 저장 실패") ?? false, "The fixture must reach persistence, not an earlier validation or conflicting-draft guard")
        XCTAssertEqual(try Data(contentsOf: directory), Data("blocking parent".utf8))
        XCTAssertTrue(store.sending.isEmpty)
    }
    @MainActor func testDemoPreparationRejectsConflictingDraftAndKeepsAllProjectScopeOnSuccess() async {
        let store = MaestroStore(demo: true)
        let link = NodeLink(source: .session("design"), target: .session("watch"), kind: .review, note: "Check this")
        XCTAssertTrue(store.saveNodeLink(link))
        let config = ConnectionActionConfiguration(function: .handoff, executionSide: .target)
        store.selectedSessionID = "design"; store.selectedProjectID = "app"
        store.workspace.drafts["watch"] = "Existing task"
        let before = store.workspace.drafts
        let conflict = await store.prepareConnectionAction(link: link, config: config)
        XCTAssertFalse(conflict)
        XCTAssertEqual(store.workspace.drafts, before)
        XCTAssertEqual(store.selectedSessionID, "design"); XCTAssertEqual(store.selectedProjectID, "app")
        XCTAssertNil(store.notice); XCTAssertTrue(store.error?.contains("기존 초안") ?? false)
        store.workspace.drafts["watch"] = ""
        let success = await store.prepareConnectionAction(link: link, config: config)
        XCTAssertTrue(success)
        XCTAssertTrue(store.draft(for: "watch").contains("codex://threads/design"))
        XCTAssertTrue(store.draft(for: "watch").contains("Check this"))
        XCTAssertEqual(store.selectedSessionID, "watch"); XCTAssertNil(store.selectedProjectID)
        XCTAssertEqual(store.scope, "all")
        XCTAssertNotNil(store.notice); XCTAssertTrue(store.sending.isEmpty)
        let draftBeforeFailure = store.workspace.drafts
        let unavailable = await store.prepareConnectionAction(link: NodeLink(source: .session("missing"), target: .session("watch"), kind: .context), config: config)
        XCTAssertFalse(unavailable)
        XCTAssertEqual(store.workspace.drafts, draftBeforeFailure)
        XCTAssertNotNil(store.error)
    }
}
