import XCTest
import Foundation
import CSQLite
@testable import MaestroCore

final class CoreTests: XCTestCase {
    func testFramesSurviveFragmentationAndCoalescing() throws {
        let first = try IPCFrameDecoder.encode(["type": "response", "text": "한글 👋"])
        let second = try IPCFrameDecoder.encode(["value": 42])
        let wire = first + second
        var parser = IPCFrameDecoder(); var result: [[String: Any]] = []
        for byte in wire { result += try parser.append(Data([byte])) }
        XCTAssertEqual(result.count, 2); XCTAssertEqual(result[0]["text"] as? String, "한글 👋")
        XCTAssertEqual(result[1]["value"] as? Int, 42)
        var combined = IPCFrameDecoder(); XCTAssertEqual(try combined.append(wire).count, 2)
    }
    func testMalformedFramesFailClosed() {
        for bytes: [UInt8] in [[0,0,0,0], [255,255,255,255], [2,0,0,0,91,93]] {
            var parser = IPCFrameDecoder(); XCTAssertThrowsError(try parser.append(Data(bytes)))
        }
    }
    func testMalformedFrameRejectsAnOtherwiseValidBatch() throws {
        let valid = try IPCFrameDecoder.encode(["type": "response", "resultType": "success"])
        let nonObject = Data([2, 0, 0, 0, 91, 93]) // JSON [] in a complete frame.
        for invalid in [nonObject, Data([0, 0, 0, 0])] {
            var decoder = IPCFrameDecoder()
            XCTAssertThrowsError(try decoder.append(valid + invalid), "A valid prefix must not make a malformed batch acceptable")
        }
    }
    func testLiveStatusPatchesAndWaitingFlags() {
        var session = LiveSession(snapshot: ["title": "test", "threadRuntimeStatus": ["type": "active", "activeFlags": []]], owner: "desktop", revision: 2)
        XCTAssertEqual(session.status, .running)
        session.apply(patches: [["op": "replace", "path": ["threadRuntimeStatus", "activeFlags"], "value": ["waitingOnApproval"]]])
        XCTAssertEqual(session.status, .waiting)
        session.apply(patches: [["op": "replace", "path": ["threadRuntimeStatus"], "value": ["type": "idle"]]])
        XCTAssertEqual(session.status, .idle)
        session.apply(patches: [["op": "remove", "path": ["threadRuntimeStatus"]]])
        XCTAssertEqual(session.status, .unknown)
    }
    func testDirectedLinksAndPersistenceRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let persistence = WorkspacePersistence(url: dir.appendingPathComponent("workspace.json"))
        var state = try persistence.load()
        try state.addLink(SessionLink(source: "a", target: "b", kind: .context, note: "맥락"))
        XCTAssertThrowsError(try state.addLink(SessionLink(source: "a", target: "a", kind: .review)))
        XCTAssertThrowsError(try state.addLink(SessionLink(source: "a", target: "b", kind: .context)))
        try state.addLink(SessionLink(source: "b", target: "a", kind: .review))
        state.positions["a"] = NodePosition(x: 100, y: 200); state.drafts["b"] = "초안"
        try persistence.save(state)
        let read = try persistence.load()
        XCTAssertEqual(read.links, state.links); XCTAssertEqual(read.positions, state.positions); XCTAssertEqual(read.drafts, state.drafts)
        let permissions = try FileManager.default.attributesOfItem(atPath: persistence.url.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
        try Data("bad json".utf8).write(to: persistence.url)
        XCTAssertThrowsError(try persistence.load())
        XCTAssertEqual(try String(contentsOf: persistence.url, encoding: .utf8), "bad json")
    }
    func testCatalogReadsAllSessionsAndExplicitProjectMembershipWithoutWriting() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("state_5.sqlite")
        var db: OpaquePointer?; XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        let sql = """
        CREATE TABLE projects(id TEXT, name TEXT, position INT);
        CREATE TABLE project_roots(project_id TEXT, path TEXT, position INT);
        CREATE TABLE threads(id TEXT,title TEXT,name TEXT,cwd TEXT,updated_at INT,archived INT,project_id TEXT,source TEXT);
        INSERT INTO projects VALUES('p','Product',0),('q','Nested',1);
        INSERT INTO project_roots VALUES('p','/repo',0),('q','/repo/nested',0);
        INSERT INTO threads VALUES('a','Original','Renamed','/repo/nested',123,0,'p','cli');
        INSERT INTO threads VALUES('b','Fallback',NULL,'/repo/nested/child',124,0,NULL,'cli');
        INSERT INTO threads VALUES('c','Archived',NULL,'/repo',125,1,'p','cli');
        INSERT INTO threads VALUES('d','Outside',NULL,'/repository',126,0,NULL,'cli');
        """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK); sqlite3_close(db)
        let before = try Data(contentsOf: dbURL)
        let result = try CodexCatalog(home: dir).read()
        XCTAssertEqual(result.projects.count, 2); XCTAssertEqual(result.sessions.count, 3)
        XCTAssertEqual(result.sessions.first { $0.id == "a" }?.title, "Renamed")
        XCTAssertEqual(result.sessions.first { $0.id == "a" }?.projectID, "p")
        XCTAssertEqual(result.sessions.first { $0.id == "b" }?.projectID, "q")
        XCTAssertNil(result.sessions.first { $0.id == "d" }?.projectID)
        XCTAssertTrue(result.sessions.allSatisfy { $0.status == .unknown && !$0.isLive })
        XCTAssertEqual(try Data(contentsOf: dbURL), before)
    }
    @MainActor func testTurnPayloadPreservesPromptAndDoesNotOverrideSessionPolicy() {
        let prompt = "한글 `$(secret)`\n\"quoted\" 🐸"
        let params = DesktopBridge.turnParameters(threadID: "target", prompt: prompt, messageID: "nonce")
        let turn = params["turnStart"] as! [String: Any]
        let request = turn["request"] as! [String: Any]
        XCTAssertEqual(request["threadId"] as? String, "target")
        XCTAssertEqual((request["input"] as? [[String: Any]])?.first?["text"] as? String, prompt)
        XCTAssertNil(request["model"]); XCTAssertNil(request["approvalPolicy"]); XCTAssertNil(request["sandboxPolicy"])
        XCTAssertEqual(request["clientUserMessageId"] as? String, "nonce")
    }
    func testTranscriptUsesChronologicalTextMessagesAndBoundThreadID() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dir.appendingPathComponent("thread_history_1.sqlite").path, &db), SQLITE_OK)
        let sql = """
        CREATE TABLE thread_items(thread_id TEXT, item_id TEXT, item_type TEXT, rollout_ordinal INT, item_json TEXT);
        INSERT INTO thread_items VALUES('a','u','userMessage',1,'{"type":"userMessage","content":[{"type":"text","text":"질문"}]}');
        INSERT INTO thread_items VALUES('a','tool','commandExecution',2,'{"type":"commandExecution","text":"hidden tool output"}');
        INSERT INTO thread_items VALUES('a','r','agentMessage',3,'{"type":"agentMessage","text":"답변"}');
        INSERT INTO thread_items VALUES('b','other','agentMessage',4,'{"type":"agentMessage","text":"other session"}');
        """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK); sqlite3_close(db)
        let reader = CodexCatalog(home: dir)
        let messages = try reader.transcript(threadID: "a")
        XCTAssertEqual(messages.map(\.text), ["질문", "답변"])
        XCTAssertEqual(messages.map(\.role), ["user", "assistant"])
        XCTAssertTrue(try reader.transcript(threadID: "' OR 1=1 --").isEmpty)
        XCTAssertEqual(try reader.transcript(threadID: "a", limit: 1).map(\.text), ["답변"])
    }
}
