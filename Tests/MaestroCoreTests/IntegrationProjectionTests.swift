import XCTest
import Foundation
import CSQLite
@testable import MaestroCore

final class IntegrationProjectionTests: XCTestCase {
    func testIndexedFlagsRespectReplacementInsertionAndRemovalOrder() {
        var session = LiveSession(snapshot: ["threadRuntimeStatus": ["type": "active", "activeFlags": ["waitingOnApproval"]]], owner: "desktop", revision: 1)
        XCTAssertTrue(session.apply(patches: [["op": "replace", "path": ["threadRuntimeStatus", "activeFlags", 0], "value": "waitingOnUserInput"]]))
        XCTAssertTrue(session.apply(patches: [["op": "remove", "path": ["threadRuntimeStatus", "activeFlags", 0]]]))
        XCTAssertEqual(session.status, .running, "Replacing one flag must not append a stale waiting flag")
        XCTAssertTrue(session.apply(patches: [["op": "add", "path": ["threadRuntimeStatus", "activeFlags", 0], "value": "waitingOnApproval"]]))
        XCTAssertEqual(session.status, .waiting)
    }

    func testInvalidProjectionPatchDoesNotPartiallyApplyEarlierPatches() {
        var session = LiveSession(snapshot: ["title": "original", "threadRuntimeStatus": ["type": "idle"]], owner: "desktop", revision: 1)
        XCTAssertFalse(session.apply(patches: [
            ["op": "replace", "path": ["title"], "value": "changed"],
            ["op": "remove", "path": ["threadRuntimeStatus", "activeFlags", 9]]
        ]))
        XCTAssertEqual(session.title, "original")
        XCTAssertEqual(session.status, .idle)
        XCTAssertFalse(session.apply(patches: [["op": "replace", "path": [], "value": [:]]]))
    }

    func testUnrelatedConversationPatchesLeaveProjectionUnchanged() {
        var session = LiveSession(snapshot: ["title": "original", "threadRuntimeStatus": ["type": "active", "activeFlags": []]], owner: "desktop", revision: 1)
        XCTAssertTrue(session.apply(patches: [["op": "add", "path": ["turns", 0, "text"], "value": "token"]]))
        XCTAssertEqual(session.title, "original")
        XCTAssertEqual(session.status, .running)
    }

    func testProjectFallbackRanksOnlyMatchingRootsAndUsesPathBoundaries() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state_9.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let sql = """
        CREATE TABLE projects(id TEXT, name TEXT, position INT);
        CREATE TABLE project_roots(project_id TEXT, path TEXT, position INT);
        CREATE TABLE threads(id TEXT, title TEXT, cwd TEXT, updated_at INT, archived INT, project_id TEXT);
        INSERT INTO projects VALUES('wide','Wide',0),('nested','Nested',1),('root','Root',2);
        INSERT INTO project_roots VALUES('wide','/repo',0),('wide','/a/completely/unrelated/very/long/path',1),('nested','/repo/nested/',0),('root','/',0);
        INSERT INTO threads VALUES('nested-session','Nested','/repo/nested/child',1,0,NULL),('outside','Outside','/repository',2,0,NULL),('explicit','Explicit','/repo/nested/child',3,0,'wide');
        """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        let before = try Data(contentsOf: url)
        let catalog = try CodexCatalog(home: directory).read()
        XCTAssertEqual(catalog.sessions.first { $0.id == "nested-session" }?.projectID, "nested")
        XCTAssertEqual(catalog.sessions.first { $0.id == "outside" }?.projectID, "root")
        XCTAssertEqual(catalog.sessions.first { $0.id == "explicit" }?.projectID, "wide")
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertTrue(try CodexCatalog(home: directory).transcript(threadID: "a", limit: -1).isEmpty)
    }
}
