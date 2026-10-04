import XCTest
import Foundation
import CSQLite
@testable import MaestroCore

final class SessionMessagePreviewTests: XCTestCase {
    func testWhitespaceAndUnicodeAreNormalizedWithoutSplittingGraphemes() throws {
        let family = "👨‍👩‍👧‍👦"
        let preview = try XCTUnwrap(SessionMessagePreview(role: "assistant", text: " \n한글\t\t\(family)\u{00A0}완료\r\n "))
        XCTAssertEqual(preview.text, "한글 \(family) 완료")
        XCTAssertEqual(preview.displayText, "Codex: 한글 \(family) 완료")
        let long = try XCTUnwrap(SessionMessagePreview(role: "user", text: String(repeating: family, count: 200)))
        XCTAssertEqual(long.text, String(repeating: family, count: 159) + "…")
        XCTAssertEqual(long.text.count, 160)
        XCTAssertEqual(long.author, "사용자")
        XCTAssertEqual(SessionMessagePreview(role: "user", text: String(repeating: "가", count: 160))?.text.count, 160)
        XCTAssertFalse(SessionMessagePreview(role: "user", text: String(repeating: "가", count: 160))!.text.hasSuffix("…"))
        XCTAssertNil(SessionMessagePreview(role: "tool", text: "result"))
        XCTAssertNil(SessionMessagePreview(role: "user", text: " \t\n"))
    }

    func testLatestConversationUsesOrdinalAndKeepsInitialPreviewSeparate() throws {
        let fixture = try PreviewCatalogFixture()
        defer { fixture.remove() }
        try fixture.addThread("a")
        try fixture.addThread("b")
        try fixture.addMessage(thread: "a", ordinal: 1, type: "userMessage", json: ["content": [["text": "이전 질문"]]], timestamp: 999)
        try fixture.addMessage(thread: "a", ordinal: 2, type: "agentMessage", json: ["text": "마지막 답변"], timestamp: 1)
        try fixture.addMessage(thread: "a", ordinal: 3, type: "toolCall", json: ["text": "이 도구 결과는 표시하지 않음"])
        try fixture.addMessage(thread: "b", ordinal: 1, type: "agentMessage", json: ["text": "이전 답변"])
        try fixture.addMessage(thread: "b", ordinal: 2, type: "userMessage", json: ["content": [["text": "다음"], ["text": "질문"]]])
        let catalog = try CodexCatalog(home: fixture.directory).read()
        let a = try XCTUnwrap(catalog.sessions.first { $0.id == "a" })
        let b = try XCTUnwrap(catalog.sessions.first { $0.id == "b" })
        XCTAssertEqual(a.lastMessage?.displayText, "Codex: 마지막 답변")
        XCTAssertEqual(a.preview, "초기 요청")
        XCTAssertEqual(b.lastMessage?.displayText, "사용자: 다음 질문")
        XCTAssertEqual(try CodexCatalog(home: fixture.directory).transcript(threadID: "b").map(\.text), ["이전 답변", "다음\n질문"])
        let metadataOnly = try CodexCatalog(home: fixture.directory).read(includeArchived:true,includeMessagePreviews:false)
        XCTAssertEqual(Set(metadataOnly.sessions.map(\.id)),Set(catalog.sessions.map(\.id)))
        XCTAssertTrue(metadataOnly.sessions.allSatisfy { $0.lastMessage == nil })
        XCTAssertEqual(metadataOnly.sessions.first?.preview,"초기 요청")
    }

    func testUnreadableLatestItemsFallBackToTheLastTextWithoutACandidateLimit() throws {
        let fixture = try PreviewCatalogFixture()
        defer { fixture.remove() }
        try fixture.addThread("a")
        try fixture.addMessage(thread: "a", ordinal: 1, type: "agentMessage", json: ["text": "마지막 읽을 수 있는 응답"])
        for ordinal in 2...70 {
            try fixture.addMessage(thread: "a", ordinal: ordinal, type: "userMessage", json: ["content": [["type": "image", "url": "fixture://image"]]])
        }
        try fixture.addMessage(thread: "a", ordinal: 71, type: "agentMessage", json: ["text": " \n\t"])
        try fixture.addRawMessage(thread: "a", ordinal: 72, type: "agentMessage", raw: "malformed JSON")
        let session = try XCTUnwrap(CodexCatalog(home: fixture.directory).read().sessions.first)
        XCTAssertEqual(session.lastMessage?.text, "마지막 읽을 수 있는 응답")
    }

    func testThreadIDsAreBoundAndDoNotReadAnotherSession() throws {
        let fixture = try PreviewCatalogFixture()
        defer { fixture.remove() }
        let hostileID = "' OR 1=1 --"
        try fixture.addThread(hostileID)
        try fixture.addThread("other")
        try fixture.addMessage(thread: "other", ordinal: 100, type: "agentMessage", json: ["text": "다른 세션의 대화"])
        XCTAssertNil(try CodexCatalog(home: fixture.directory).read().sessions.first { $0.id == hostileID }?.lastMessage)
        try fixture.addMessage(thread: hostileID, ordinal: 1, type: "userMessage", json: ["text": "해당 세션의 질문"])
        XCTAssertEqual(try CodexCatalog(home: fixture.directory).read().sessions.first { $0.id == hostileID }?.lastMessage?.text, "해당 세션의 질문")
    }

    func testMissingOrInvalidHistoryDoesNotHideSessionMetadata() throws {
        let fixture = try PreviewCatalogFixture()
        defer { fixture.remove() }
        try fixture.addThread("a")
        try FileManager.default.removeItem(at: fixture.history)
        XCTAssertNil(try CodexCatalog(home: fixture.directory).read().sessions.first?.lastMessage)
        try Data("invalid database".utf8).write(to: fixture.history)
        let catalog = try CodexCatalog(home: fixture.directory).read()
        XCTAssertEqual(catalog.sessions.map(\.id), ["a"])
        XCTAssertEqual(catalog.sessions.first?.preview, "초기 요청")
        XCTAssertNil(catalog.sessions.first?.lastMessage)
    }

    func testCatalogPreviewReadLeavesBothDatabaseFilesUnchanged() throws {
        let fixture = try PreviewCatalogFixture()
        defer { fixture.remove() }
        try fixture.addThread("a")
        try fixture.addMessage(thread: "a", ordinal: 1, type: "agentMessage", json: ["text": "저장된 대화"])
        let stateBefore = try Data(contentsOf: fixture.state)
        let historyBefore = try Data(contentsOf: fixture.history)
        XCTAssertEqual(try CodexCatalog(home: fixture.directory).read().sessions.first?.lastMessage?.text, "저장된 대화")
        XCTAssertEqual(try Data(contentsOf: fixture.state), stateBefore)
        XCTAssertEqual(try Data(contentsOf: fixture.history), historyBefore)
    }

    func testRolloutSuppliesLegacyPreviewAndHistoryRemainsThePrimarySource() throws {
        let fixture = try PreviewCatalogFixture()
        defer { fixture.remove() }
        try fixture.addThread("legacy")
        let rollout = fixture.directory.appendingPathComponent("legacy.jsonl")
        try fixture.setRolloutPath(rollout.lastPathComponent, thread: "legacy")
        let line = try JSONSerialization.data(withJSONObject: ["type": "response_item", "payload": ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "원본의 마지막 대화"]]]])
        try line.write(to: rollout)
        let stateBefore = try Data(contentsOf: fixture.state)
        XCTAssertEqual(try CodexCatalog(home: fixture.directory).read().sessions.first?.lastMessage?.displayText, "Codex: 원본의 마지막 대화")
        XCTAssertEqual(try Data(contentsOf: rollout), line)
        XCTAssertEqual(try Data(contentsOf: fixture.state), stateBefore)
        try fixture.addMessage(thread: "legacy", ordinal: 1, type: "userMessage", json: ["text": "DB에 저장된 마지막 질문"])
        XCTAssertEqual(try CodexCatalog(home: fixture.directory).read().sessions.first?.lastMessage?.displayText, "사용자: DB에 저장된 마지막 질문")
        try FileManager.default.removeItem(at: fixture.history)
        XCTAssertEqual(try CodexCatalog(home: fixture.directory).read().sessions.first?.lastMessage?.text, "원본의 마지막 대화")
        try FileManager.default.removeItem(at: rollout)
        XCTAssertNil(try CodexCatalog(home: fixture.directory).read().sessions.first?.lastMessage)
    }
}

private struct PreviewCatalogFixture {
    let directory: URL
    var state: URL { directory.appendingPathComponent("state_5.sqlite") }
    var history: URL { directory.appendingPathComponent("thread_history_1.sqlite") }

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try execute(state, sql: "CREATE TABLE threads(id TEXT PRIMARY KEY, title TEXT, cwd TEXT, updated_at INTEGER, archived INTEGER, preview TEXT, rollout_path TEXT)")
        try execute(history, sql: "CREATE TABLE thread_items(thread_id TEXT, item_id TEXT PRIMARY KEY, item_type TEXT, rollout_ordinal INTEGER, created_at_ms INTEGER, item_json TEXT)")
        try execute(history, sql: "CREATE UNIQUE INDEX idx_thread_items_page ON thread_items(thread_id, rollout_ordinal)")
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
    func addThread(_ id: String) throws {
        try execute(state, sql: "INSERT INTO threads(id,title,cwd,updated_at,archived,preview) VALUES(?, ?, ?, 1, 0, ?)", bindings: [id, "세션 \(id)", "/fixture", "초기 요청"])
    }
    func setRolloutPath(_ path: String, thread: String) throws {
        try execute(state, sql: "UPDATE threads SET rollout_path=? WHERE id=?", bindings: [path, thread])
    }
    func addMessage(thread: String, ordinal: Int, type: String, json: [String: Any], timestamp: Int = 0) throws {
        let data = try JSONSerialization.data(withJSONObject: json)
        try addRawMessage(thread: thread, ordinal: ordinal, type: type, raw: String(decoding: data, as: UTF8.self), timestamp: timestamp)
    }
    func addRawMessage(thread: String, ordinal: Int, type: String, raw: String, timestamp: Int = 0) throws {
        try execute(history, sql: "INSERT INTO thread_items VALUES(?, ?, ?, ?, ?, ?)", bindings: [thread, UUID().uuidString, type, String(ordinal), String(timestamp), raw])
    }
    private func execute(_ url: URL, sql: String, bindings: [String] = []) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw MaestroError.message("Could not open fixture database") }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw MaestroError.message(String(cString: sqlite3_errmsg(db))) }
        defer { sqlite3_finalize(statement) }
        for (index, binding) in bindings.enumerated() {
            let result = binding.withCString { sqlite3_bind_text(statement, Int32(index + 1), $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            guard result == SQLITE_OK else { throw MaestroError.message(String(cString: sqlite3_errmsg(db))) }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw MaestroError.message(String(cString: sqlite3_errmsg(db))) }
    }
}
