import XCTest
import Foundation
import CSQLite
@testable import MaestroCore

final class ContextTopologyLoaderTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func database(_ path: URL, sql: String) throws {
        var db: OpaquePointer?; XCTAssertEqual(sqlite3_open(path.path, &db), SQLITE_OK); defer { sqlite3_close(db) }
        var error: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(db, sql, nil, nil, &error)
        let message = error.map { String(cString: $0) } ?? ""
        sqlite3_free(error); XCTAssertEqual(code, SQLITE_OK, message)
    }
    private func json(_ value: [String: Any]) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self) }
    private func fixture(_ dir: URL, id: String = "s", records: [String]) throws -> URL {
        let rollout = dir.appendingPathComponent(id + ".jsonl")
        try Data(records.joined(separator: "\n").utf8).write(to: rollout)
        try database(dir.appendingPathComponent("state_5.sqlite"), sql: "CREATE TABLE IF NOT EXISTS threads(id TEXT, rollout_path TEXT); INSERT INTO threads VALUES('\(id)', '\(rollout.path)');")
        return rollout
    }
    func testLoadsEveryRecordWithLazyExactBodyAndActualTelemetry() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        var records = try (0..<85).map { try json(["type": "response_item", "timestamp": "t\($0)", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": $0 == 80 ? String(repeating: "맥락🙂", count: 35000) : "message \($0)"]]]]) }
        records.append(try json(["type": "event_msg", "payload": ["type": "token_count", "info": ["last_token_usage": ["input_tokens": 200, "cached_input_tokens": 50], "total_token_usage": ["input_tokens": 900], "model_context_window": 100000]]]))
        let path = try fixture(dir, records: records)
        let loader = ContextTopologyLoader(home: dir)
        let map = try await loader.load(session: Session(id: "s", title: "S", projectID: nil, cwd: ""))
        XCTAssertEqual(map.nodes.filter { $0.kind == .message }.count, 85)
        XCTAssertEqual(map.coverage.first?.records, 86); XCTAssertEqual(map.coverage.first?.status, .complete)
        let huge = try XCTUnwrap(map.nodes.first { $0.kind == .message && $0.charCount > 100000 })
        XCTAssertLessThan(huge.fullText.count, 1500); XCTAssertEqual(huge.bodyReference?.path, path.path)
        let full = try await loader.loadBody(node: huge)
        XCTAssertEqual(full.count, huge.charCount); XCTAssertTrue(full.contains(String(repeating: "맥락🙂", count: 35000)))
        XCTAssertEqual(map.usage.first?.metrics["payload.info.last_token_usage.input_tokens"], 200)
        XCTAssertEqual(map.usage.first?.metrics["payload.info.total_token_usage.input_tokens"], 900)
        XCTAssertEqual(map.usage.first?.metrics["payload.info.model_context_window"], 100000)
        var bytes = try Data(contentsOf: path); bytes[Int(huge.bodyReference!.offset)] = 32; try bytes.write(to: path)
        do { _ = try await loader.loadBody(node: huge); XCTFail("Changed record must fail") } catch { }
    }
    func testReasoningIsSanitizedInPreviewAndDeferredBody() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        _ = try fixture(dir, records: [try json(["type": "response_item", "payload": ["type": "reasoning", "text": "PRIVATE_THOUGHT", "encrypted_content": "SECRET_CIPHER", "summary": [["type": "summary_text", "text": "Public summary"]]]]), try json(["type": "event_msg", "payload": ["type": "agent_reasoning", "text": "PRIVATE_THOUGHT", "encrypted_content": "SECRET_CIPHER"]]), try json(["type": "response_item", "payload": ["type": "message", "role": "assistant", "channel": "analysis", "content": [["text": "PRIVATE_THOUGHT"]]]])])
        let loader = ContextTopologyLoader(home: dir)
        let map = try await loader.load(session: Session(id: "s", title: "S", projectID: nil, cwd: ""))
        let records = map.nodes.filter { $0.bodyReference != nil }
        XCTAssertEqual(records.count, 3)
        for record in records {
            for text in [record.fullText, try await loader.loadBody(node: record)] {
                XCTAssertFalse(text.contains("PRIVATE_THOUGHT")); XCTAssertFalse(text.contains("SECRET_CIPHER"))
            }
        }
        XCTAssertTrue(records.contains { $0.fullText.contains("Public summary") })
    }
    func testMalformedRolloutPreservesPartialCoverageAndStreamsSQLiteFallback() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        _ = try fixture(dir, records: [try json(["type": "session_meta", "payload": ["id": "s"]]), "not-json"])
        let raw = try json(["type": "agentMessage", "text": "Recovered complete history"])
        try database(dir.appendingPathComponent("thread_history_1.sqlite"), sql: "CREATE TABLE thread_items(thread_id TEXT,item_id TEXT,item_json TEXT,rollout_ordinal INT); INSERT INTO thread_items VALUES('s','item', '\(raw)',0);")
        let loader = ContextTopologyLoader(home: dir); let map = try await loader.load(session: Session(id: "s", title: "S", projectID: nil, cwd: ""))
        XCTAssertEqual(map.coverage[0].status, .partial); XCTAssertFalse(map.coverage[0].issues.isEmpty)
        XCTAssertEqual(map.coverage[1].status, .complete)
        let recovered = try XCTUnwrap(map.nodes.first { $0.bodyReference?.itemID == "item" })
        let body = try await loader.loadBody(node: recovered); XCTAssertTrue(body.contains("Recovered complete history"))
    }
    func testProjectScopeIncludesArchivedMembersAndExcludesOtherProjects() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        _ = try fixture(dir, id: "a", records: [try json(["type": "turn_context", "payload": ["model": "modelA", "instructions": "/tmp/skills/foo/SKILL.md plugin://sample/tool"]])])
        _ = try fixture(dir, id: "b", records: [try json(["type": "response_item", "payload": ["type": "function_call", "name": "exec_command", "call_id": "call1", "arguments": "swift test"]])])
        var a = Session(id: "a", title: "Archived", projectID: "p", cwd: ""); a.isArchived = true
        let b = Session(id: "b", title: "Child", projectID: "p", cwd: "", parentID: "a")
        let c = Session(id: "c", title: "Other", projectID: "q", cwd: "")
        let map = try await ContextTopologyLoader(home: dir).load(project: Project(id: "p", name: "P", roots: ["/P"]), sessions: [a,b,c])
        XCTAssertEqual(Set(map.sessions.map(\.id)), ["a", "b"])
        XCTAssertTrue(map.nodes.contains { $0.kind == .skill && $0.title == "/tmp/skills/foo/SKILL.md" })
        XCTAssertTrue(map.nodes.contains { $0.kind == .plugin && $0.title == "plugin://sample/tool" })
        XCTAssertTrue(map.nodes.contains { $0.kind == .tool && $0.title == "exec_command" })
        XCTAssertTrue(map.edges.contains { $0.relation == "하위 세션" })
        XCTAssertFalse(map.nodes.contains { $0.sessionID == "c" })
    }
    func testMissingEvidenceAndCurrentAncestorInstructionsRemainExplicit() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let cwd = dir.appendingPathComponent("workspace/sub")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        try Data("Parent guidance".utf8).write(to: dir.appendingPathComponent("AGENTS.md"))
        let map = try await ContextTopologyLoader(home: dir).load(session: Session(id: "missing", title: "Missing", projectID: nil, cwd: cwd.path))
        XCTAssertTrue(map.coverage.contains { $0.status == .missing }); XCTAssertTrue(map.coverage.contains { $0.status == .error })
        let instruction = try XCTUnwrap(map.nodes.first { $0.kind == .instruction })
        XCTAssertTrue(instruction.summary.contains("현재 디스크")); XCTAssertEqual(instruction.fullText, "Parent guidance")
        XCTAssertTrue(map.boundaries.contains { $0.contains("전체를 증명하지") })
    }
    func testToolChildrenNormalizeRepeatedCallsAndClassifyInstructionsAndUsage() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let call = try json(["type": "response_item", "payload": ["type": "function_call", "call_id": "c", "name": "mcp__server__tool", "arguments": "first"]])
        let result = try json(["type": "response_item", "payload": ["type": "function_call_output", "call_id": "c", "output": "done"]])
        _ = try fixture(dir, records: [call, result, "bad-json", try json(["type": "response_item", "payload": ["type": "message", "role": "developer", "content": [["text": "guidance"]]]]), try json(["type": "event_msg", "payload": ["type": "token_usage_record", "input_tokens": 123]])])
        let native = try json(["type": "mcpToolCall", "id": "native", "server": "nativeServer", "tool": "query", "status": "completed"])
        try database(dir.appendingPathComponent("thread_history_1.sqlite"), sql: "CREATE TABLE thread_items(thread_id TEXT,item_id TEXT,item_json TEXT,rollout_ordinal INT); INSERT INTO thread_items VALUES('s','c','\(call)',0); INSERT INTO thread_items VALUES('s','r','\(result)',1); INSERT INTO thread_items VALUES('s','native','\(native)',2);")
        let map = try await ContextTopologyLoader(home: dir).load(session: Session(id: "s", title: "S", projectID: nil, cwd: ""))
        XCTAssertEqual(map.nodes.filter { $0.kind == .toolCall }.count, 2)
        XCTAssertEqual(map.nodes.filter { $0.kind == .toolResult }.count, 1)
        let callGroup = try XCTUnwrap(map.nodes.first { $0.id == "session:s:group:toolCall" })
        let resultGroup = try XCTUnwrap(map.nodes.first { $0.id == "session:s:group:toolResult" })
        XCTAssertEqual(callGroup.recordCount, 2)
        XCTAssertEqual(resultGroup.recordCount, 1)
        XCTAssertEqual(callGroup.charCount, map.nodes.filter { $0.kind == .toolCall }.reduce(0) { $0 + $1.charCount })
        XCTAssertEqual(resultGroup.charCount, map.nodes.filter { $0.kind == .toolResult }.reduce(0) { $0 + $1.charCount })
        let tool = try XCTUnwrap(map.nodes.first { $0.kind == .tool && $0.title == "mcp__server__tool" })
        XCTAssertEqual(tool.recordCount, 1); XCTAssertGreaterThan(tool.charCount, 0)
        XCTAssertEqual(tool.charCount, map.nodes.filter { $0.parentID == tool.id }.reduce(0) { $0 + $1.charCount })
        XCTAssertEqual(map.nodes.filter { $0.parentID == tool.id }.count, 2)
        XCTAssertTrue(map.nodes.contains { $0.kind == .tool && $0.title == "nativeServer.query" })
        XCTAssertTrue(map.nodes.contains { $0.kind == .instruction && $0.fullText.contains("guidance") })
        XCTAssertTrue(map.nodes.contains { $0.kind == .usage })
        let ids = Set(map.nodes.map(\.id)); XCTAssertTrue(map.edges.allSatisfy { ids.contains($0.source) && ids.contains($0.target) })
    }
    func testProjectHierarchyAndEmptyProjectRootInstructions() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        try Data("Empty project guidance".utf8).write(to: dir.appendingPathComponent("AGENTS.md"))
        let loader = ContextTopologyLoader(home: dir)
        let project = Project(id: "p", name: "P", roots: [dir.path])
        let empty = try await loader.load(project: project, sessions: [])
        XCTAssertTrue(empty.nodes.contains { $0.kind == .instruction && $0.parentID == "project:p" })
        _ = try fixture(dir, records: [try json(["type": "session_meta", "payload": ["id": "s"]])])
        let member = Session(id: "s", title: "S", projectID: "p", cwd: dir.path)
        let map = try await loader.load(project: project, sessions: [member])
        XCTAssertTrue(map.nodes.contains { $0.kind == .session && $0.parentID == "project:p" })
        XCTAssertTrue(map.edges.contains { $0.source == "project:p" && $0.relation == "현재 상위 경로 지침" })
    }

    func testDeferredSQLiteBodyUsesThreadAndItemIdentityAndSharedInstructionEdges() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let wrong = try json(["type": "agentMessage", "text": "Other thread body"])
        let right = try json(["type": "agentMessage", "text": "Selected thread body"])
        try database(dir.appendingPathComponent("thread_history_1.sqlite"), sql: "CREATE TABLE thread_items(thread_id TEXT,item_id TEXT,item_json TEXT,rollout_ordinal INT); INSERT INTO thread_items VALUES('other','shared','\(wrong)',0); INSERT INTO thread_items VALUES('selected','shared','\(right)',0);")
        try Data("Shared instructions".utf8).write(to: dir.appendingPathComponent("AGENTS.md"))
        let selected = Session(id: "selected", title: "Selected", projectID: "p", cwd: dir.path)
        let other = Session(id: "other", title: "Other", projectID: "p", cwd: dir.path)
        let loader = ContextTopologyLoader(home: dir)
        let map = try await loader.load(project: Project(id: "p", name: "P", roots: [dir.path]), sessions: [selected, other])
        let node = try XCTUnwrap(map.nodes.first { $0.sessionID == "selected" && $0.bodyReference?.itemID == "shared" })
        XCTAssertEqual(node.bodyReference?.sessionID, "selected")
        let body = try await loader.loadBody(node: node)
        XCTAssertTrue(body.contains("Selected thread body")); XCTAssertFalse(body.contains("Other thread body"))
        let instructionID = "instruction:" + dir.appendingPathComponent("AGENTS.md").path
        XCTAssertEqual(map.nodes.filter { $0.id == instructionID }.count, 1)
        XCTAssertTrue(map.edges.contains { $0.source == "session:selected" && $0.target == instructionID })
        XCTAssertTrue(map.edges.contains { $0.source == "session:other" && $0.target == instructionID })
    }

    func testOnlyRecognizedTelemetryContributesUsage() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let records = [
            try json(["type": "event_msg", "payload": ["type": "token_count", "info": ["last_token_usage": ["input_tokens": 40, "cached_input_tokens": 10], "total_token_usage": ["input_tokens": 140], "model_context_window": 2000]]]),
            try json(["type": "response_item", "payload": ["type": "function_call", "call_id": "c", "name": "mcp__tool", "arguments": ["max_output_tokens": 500, "input_tokens": 888]]]),
            try json(["type": "response_item", "payload": ["type": "function_call_output", "call_id": "c", "output": ["token_count": 999, "input_tokens": 777, "context_window": 100000]]]),
            try json(["type": "session_meta", "payload": ["input_tokens": 444, "model_context_window": 999999]]),
            try json(["type": "event_msg", "payload": ["type": "token_usage_record", "usage": ["input_tokens": 60, "cached_input_tokens": 15, "output_tokens": 20], "arguments": ["input_tokens": 666, "max_output_tokens": 900]]])
        ]
        _ = try fixture(dir, records: records)
        let map = try await ContextTopologyLoader(home: dir).load(session: Session(id: "s", title: "S", projectID: nil, cwd: ""))
        XCTAssertEqual(map.usage.count, 2)
        XCTAssertEqual(map.usage[0].metrics["payload.info.last_token_usage.input_tokens"], 40)
        XCTAssertEqual(map.usage[0].metrics["payload.info.model_context_window"], 2000)
        XCTAssertEqual(map.usage[1].metrics["payload.usage.input_tokens"], 60)
        XCTAssertEqual(map.usage[1].metrics["payload.usage.cached_input_tokens"], 15)
        XCTAssertFalse(map.usage.flatMap { $0.metrics.values }.contains(500))
        XCTAssertFalse(map.usage.flatMap { $0.metrics.values }.contains(888))
        XCTAssertFalse(map.usage.flatMap { $0.metrics.values }.contains(777))
        XCTAssertFalse(map.usage.flatMap { $0.metrics.values }.contains(666))
        XCTAssertTrue(map.nodes.contains { $0.kind == .toolCall && $0.fullText.contains("500") })
        XCTAssertTrue(map.nodes.contains { $0.kind == .toolResult && $0.fullText.contains("999") })
    }

    func testPathHeavyRecordedOutputKeepsAllEvidenceAndLinearReferenceDiscovery() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        // Many slash-rich paths without a SKILL.md suffix reproduced the former regex cost.
        let heavy = String(repeating: "/alpha/beta/gamma/delta/epsilon/zeta/source.swift\n", count: 25000)
        let cited = "/tmp/skills/foo/SKILL.md plugin://sample/tool plugin://sample/tool:42:7 /tmp/source.swift /tmp/line.swift:42 /tmp/column.swift:42:7\n/Users/example/folder with spaces/skills/bar/SKILL.md"
        _ = try fixture(dir, records: [try json(["type": "response_item", "payload": ["type": "function_call_output", "call_id": "heavy", "output": heavy + cited]])])
        let loader = ContextTopologyLoader(home: dir)
        let map = try await loader.load(session: Session(id: "s", title: "S", projectID: nil, cwd: ""))
        let node = try XCTUnwrap(map.nodes.first { $0.kind == .toolResult })
        let body = try await loader.loadBody(node: node)
        XCTAssertGreaterThan(node.charCount, 1000000); XCTAssertEqual(body.count, node.charCount)
        XCTAssertTrue(body.contains("folder with spaces"))
        XCTAssertTrue(map.nodes.contains { $0.kind == .file && $0.title == "/alpha/beta/gamma/delta/epsilon/zeta/source.swift" })
        XCTAssertTrue(map.nodes.contains { $0.kind == .file && $0.title == "/tmp/source.swift" })
        XCTAssertTrue(map.nodes.contains { $0.kind == .file && $0.title == "/tmp/line.swift" })
        XCTAssertTrue(map.nodes.contains { $0.kind == .file && $0.title == "/tmp/column.swift" })
        XCTAssertTrue(map.nodes.contains { $0.kind == .plugin && $0.title == "plugin://sample/tool:42:7" })
        XCTAssertTrue(map.nodes.contains { $0.kind == .skill && $0.title == "/tmp/skills/foo/SKILL.md" })
        XCTAssertTrue(map.nodes.contains { $0.kind == .skill && $0.title == "/Users/example/folder with spaces/skills/bar/SKILL.md" })
        XCTAssertTrue(map.nodes.contains { $0.kind == .plugin && $0.title == "plugin://sample/tool" })
        XCTAssertEqual(map.coverage.first?.records, 1)
    }

}
