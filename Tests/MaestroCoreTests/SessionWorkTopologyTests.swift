import XCTest
import Foundation
import CSQLite
import Darwin
@testable import MaestroCore

final class SessionWorkTopologyTests: XCTestCase {
    private func diagnostics(_ loader: SessionWorkTopologyLoader) async throws -> SessionWorkReadDiagnostics {
        let value = await loader.diagnostics(sessionID: "s")
        return try XCTUnwrap(value)
    }
    func testNativeLifecycleUsesExactIDsAndExplicitOutcome() async throws {
        let f = try WorkFixture(); defer { f.remove() }
        try f.write([
            f.event("task_started", ["turn_id": "t"]),
            f.response(["type": "function_call", "call_id": "wrapper", "name": "functions.exec", "arguments": "code", "status": "completed"]),
            f.event("item_started", ["item": ["type": "CommandExecution", "id": "cmd", "call_id": "command-call", "command": ["swift", "test"], "status": "inProgress", "aggregated_output": "", "exit_code": NSNull()]]),
            f.event("item_completed", ["item": ["type": "CommandExecution", "id": "cmd", "command": ["swift", "test"], "status": "completed", "aggregated_output": "test failed", "exit_code": 1]]),
            f.response(["type": "commandExecution", "id": "cmd", "call_id": "command-call", "command": "swift test", "status": "completed", "exit_code": 1]),
            f.event("item_completed", ["item": ["type": "McpToolCall", "id": "mcp", "server": "swift", "tool": "references", "arguments": ["symbol": "Session"], "status": "completed", "result": ["Ok": ["isError": true, "content": []]]]]),
            f.event("item_completed", ["item": ["type": "McpToolCall", "id": "missing", "server": "swift", "tool": "symbols", "status": "completed"]])
        ])
        let loader = SessionWorkTopologyLoader(home: f.home)
        let graph = try await loader.load(session: f.session)
        let command = try XCTUnwrap(graph.nodes.first { $0.kind == .command })
        XCTAssertEqual(graph.nodes.filter { $0.kind == .command }.count, 1)
        XCTAssertEqual(command.status, .failed)
        XCTAssertEqual(command.turnID, "t")
        XCTAssertTrue(command.source.contains("갱신"))
        XCTAssertEqual(graph.nodes.first { $0.callID == "wrapper" }?.status, .waiting)
        XCTAssertEqual(graph.nodes.first { $0.kind == .mcp && $0.callID == "mcp" }?.status, .failed)
        XCTAssertEqual(graph.nodes.first { $0.kind == .mcp && $0.callID == "missing" }?.status, .waiting)
        XCTAssertFalse(graph.edges.contains { $0.kind == .dependsOn })
        XCTAssertTrue(graph.edges.contains { $0.kind == .resultOf && $0.target == command.id })
        XCTAssertEqual(graph.edges.filter { $0.kind == .resultOf && $0.target == command.id }.count, 1)
        let ids = Set(graph.nodes.map(\.id))
        XCTAssertTrue(graph.edges.allSatisfy { ids.contains($0.source) && ids.contains($0.target) })
    }

    func testHybridMCPCallIDsMergeDirectAndNativeSuccessFailureWithoutPendingDuplicates() async throws {
        let f = try WorkFixture(); defer { f.remove() }
        try f.write([f.event("task_started", ["turn_id": "t"]),
            f.response(["type": "function_call", "id": "fc_success", "call_id": "call_success", "name": "js", "namespace": "mcp__cua_repl", "arguments": "{\"code\":\"public fixture\",\"title\":\"fixture\"}"]),
            f.event("item_completed", ["turn_id": "t", "item": ["type": "McpToolCall", "id": "call_success", "server": "cua_repl", "tool": "js", "status": "completed", "result": ["isError": false, "content": [["type": "text", "text": "public output"]]]]]),
            f.response(["type": "function_call_output", "id": "fco_success", "call_id": "call_success", "output": [["type": "text", "text": "public output"]]]),
            f.response(["type": "function_call", "id": "fc_failure", "call_id": "call_failure", "name": "mcp__cua_repl__js", "arguments": "{}"]),
            f.event("item_completed", ["turn_id": "t", "item": ["type": "McpToolCall", "item_id": "call_failure", "server_name": "cua_repl", "tool_name": "js", "status": "completed", "result": ["isError": true, "content": [["type": "text", "text": "public error"]]]]]),
            f.response(["type": "function_call_output", "id": "fco_failure", "call_id": "call_failure", "output": [["type": "text", "text": "public error"]]])
        ])
        let loader = SessionWorkTopologyLoader(home: f.home)
        let graph = try await loader.load(session: f.session)
        let calls = graph.nodes.filter { [.toolCall, .mcp].contains($0.kind) }
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(Set(calls.map(\.kind)), [.mcp])
        XCTAssertEqual(calls.first { $0.callID == "call_success" }?.status, .succeeded)
        XCTAssertEqual(calls.first { $0.callID == "call_failure" }?.status, .failed)
        XCTAssertTrue(calls.allSatisfy { $0.title == "cua_repl.js" && $0.turnID == "t" && !$0.status.isActive })
        XCTAssertTrue(calls.allSatisfy { $0.source.contains("갱신") })
        XCTAssertEqual(Set(graph.edges.filter { $0.kind == .resultOf }.map(\.target)), Set(calls.map(\.id)))
        let body = try await loader.loadBody(node: XCTUnwrap(calls.first))
        XCTAssertTrue(body.contains("McpToolCall"))
        XCTAssertFalse(body.contains("fc_success"))
    }

    func testNativeFirstHybridAndIncrementalCompletionKeepOneStableNodeAndStructuredBody() async throws {
        let f = try WorkFixture(); defer { f.remove() }
        try f.write([f.event("task_started", ["turn_id": "t"]),
            f.response(["type": "function_call", "id": "fc_initial", "call_id": "call_incremental", "name": "js", "namespace": "mcp__cua_repl", "arguments": "{}"])
        ])
        let loader = SessionWorkTopologyLoader(home: f.home)
        let before = try await loader.load(session: f.session)
        let initial = try XCTUnwrap(before.nodes.first { $0.callID == "call_incremental" })
        XCTAssertEqual(initial.status, .waiting)
        XCTAssertEqual(initial.title, "mcp__cua_repl.js")
        try f.append(f.event("item_completed", ["turn_id": "t", "item": ["type": "McpToolCall", "id": "call_incremental", "server": "cua_repl", "tool": "js", "status": "completed", "result": ["isError": false, "content": []]]]))
        try f.append(f.event("item_started", ["turn_id": "t", "item": ["type": "McpToolCall", "id": "call_reverse", "server": "cua_repl", "tool": "js", "status": "inProgress"]]))
        try f.append(f.response(["type": "function_call", "id": "fc_reverse", "call_id": "call_reverse", "name": "js", "namespace": "mcp__cua_repl", "arguments": "{}"]))
        let after = try await loader.load(session: f.session)
        let completed = try XCTUnwrap(after.nodes.first { $0.callID == "call_incremental" && $0.kind == .mcp })
        XCTAssertEqual(completed.id, initial.id)
        XCTAssertEqual(completed.status, .succeeded)
        let reverse = try XCTUnwrap(after.nodes.first { $0.callID == "call_reverse" })
        XCTAssertEqual(reverse.kind, .mcp)
        XCTAssertEqual(reverse.title, "cua_repl.js")
        XCTAssertEqual(reverse.status, .running)
        let reverseBody = try await loader.loadBody(node: reverse)
        XCTAssertTrue(reverseBody.contains("McpToolCall"))
        XCTAssertFalse(reverseBody.contains("fc_reverse"))
        XCTAssertEqual(after.nodes.filter { [.toolCall, .mcp].contains($0.kind) }.count, 2)
        let appended = try await diagnostics(loader)
        XCTAssertEqual(appended.parsedRecords, 3)
        try f.append(f.event("item_completed", ["turn_id": "t", "item": ["type": "McpToolCall", "id": "call_reverse", "server": "cua_repl", "tool": "js", "status": "completed", "result": ["isError": true, "content": []]]]))
        try f.append(f.response(["type": "function_call", "id": "fc_reverse_duplicate", "call_id": "call_reverse", "name": "js", "namespace": "mcp__cua_repl", "arguments": "{}"]))
        let finished = try await loader.load(session: f.session)
        XCTAssertEqual(finished.nodes.filter { $0.callID == "call_reverse" && $0.kind == .mcp }.count, 1)
        XCTAssertEqual(finished.nodes.first { $0.callID == "call_reverse" && $0.kind == .mcp }?.status, .failed)
    }

    func testLateGenericAliasesKeepOriginalTurnAndObservationSpecificBody() async throws {
        let f = try WorkFixture(); defer { f.remove() }
        let firstTime = "2026-10-04T01:00:00Z"
        let lateTime = "2026-10-04T01:00:20Z"
        try f.write([
            f.event("task_started", ["turn_id": "original"], timestamp: firstTime),
            f.event("item_started", ["item": ["type": "McpToolCall", "id": "native_call", "server": "cua_repl", "tool": "js", "status": "inProgress"]], timestamp: firstTime),
            f.response(["type": "function_call", "id": "fc_plain", "call_id": "plain_call", "name": "tool", "arguments": "{}"]),
            f.event("task_complete", ["turn_id": "original"]),
            f.event("task_started", ["turn_id": "receiver"]),
            ["type": "response_item", "timestamp": lateTime, "payload": ["type": "function_call", "id": "fc_late_native", "call_id": "native_call", "turn_id": "receiver", "name": "js", "namespace": "mcp__cua_repl", "arguments": "{\"late\":true}"]],
            ["type": "response_item", "timestamp": lateTime, "payload": ["type": "function_call", "id": "fc_late_plain", "call_id": "plain_call", "turn_id": "receiver", "name": "tool", "arguments": "{\"late\":true}"]]
        ])
        let loader = SessionWorkTopologyLoader(home: f.home)
        let graph = try await loader.load(session: f.session)
        let calls = graph.nodes.filter { [.toolCall, .mcp].contains($0.kind) }
        XCTAssertEqual(calls.count, 2)
        XCTAssertTrue(calls.allSatisfy { $0.turnID == "original" })
        XCTAssertFalse(graph.edges.contains { $0.kind == .calls && $0.source == "turn:s:receiver" })
        XCTAssertFalse(graph.edges.contains { $0.kind == .belongsToTurn && $0.target == "turn:s:receiver" && calls.map(\.id).contains($0.source) })
        XCTAssertEqual(Set(graph.edges.filter { $0.kind == .receivedInTurn && $0.target == "turn:s:receiver" }.map(\.source)), Set(calls.map(\.id)))
        let native = try XCTUnwrap(calls.first { $0.callID == "native_call" })
        XCTAssertEqual(native.kind, .mcp)
        XCTAssertEqual(native.title, "cua_repl.js")
        XCTAssertEqual(native.status, .running)
        let canonicalBody = try await loader.loadBody(node: native)
        XCTAssertTrue(canonicalBody.contains("McpToolCall"))
        XCTAssertFalse(canonicalBody.contains("fc_late_native"))
        let lateObservation = try XCTUnwrap(native.statusHistory.last)
        XCTAssertEqual(lateObservation.timestamp, ISO8601DateFormatter().date(from: lateTime))
        var lateNode = native
        lateNode.bodyReference = lateObservation.bodyReference
        let lateBody = try await loader.loadBody(node: lateNode)
        XCTAssertTrue(lateBody.contains("fc_late_native"))
        XCTAssertTrue(lateBody.contains("receiver"))
    }

    func testNativeStartedEmptyOutputRemainsRunningAndReplayUsesOriginalRecord() async throws {
        let f = try WorkFixture(); defer { f.remove() }
        let start = "2026-10-04T01:00:00Z"
        let finish = "2026-10-04T01:00:10Z"
        try f.write([
            f.event("task_started", ["turn_id": "t"], timestamp: start),
            f.event("item_started", ["item": ["type": "CommandExecution", "id": "c", "status": "inProgress", "aggregated_output": "", "exit_code": NSNull()]], timestamp: start)
        ])
        let loader = SessionWorkTopologyLoader(home: f.home)
        let first = try await loader.load(session: f.session)
        XCTAssertEqual(first.nodes.first { $0.kind == .command }?.status, .running)
        XCTAssertFalse(first.nodes.contains { $0.kind == .toolResult })
        try f.append(f.event("item_completed", ["item": ["type": "CommandExecution", "id": "c", "status": "completed", "aggregated_output": "done", "exit_code": 0]], timestamp: finish))
        let graph = try await loader.load(session: f.session)
        var command = try XCTUnwrap(graph.nodes.first { $0.kind == .command })
        XCTAssertEqual(command.status, .succeeded)
        let cutoff = Date(timeIntervalSince1970: 1_791_075_605)
        // Derive the midpoint from known record dates so the fixture remains independent of wall time.
        let midpoint = try XCTUnwrap(command.timestamp).addingTimeInterval(5)
        XCTAssertEqual(command.status(at: midpoint), .running)
        XCTAssertEqual(command.status(at: cutoff.addingTimeInterval(-10_000_000)), .unknown)
        let observation = try XCTUnwrap(command.observation(at: midpoint))
        command.bodyReference = observation.bodyReference
        let body = try await loader.loadBody(node: command)
        XCTAssertTrue(body.contains("inProgress"))
        XCTAssertFalse(body.contains("done"))
    }

    func testLateResultsStayWithOriginalCallAndDuplicateReceiptsDoNotOverwriteDistinctOutputs() async throws {
        let f = try WorkFixture(); defer { f.remove() }
        try f.write([
            f.event("task_started", ["turn_id": "a"]),
            f.response(["type": "function_call", "call_id": "one", "name": "tool", "arguments": "{}"]),
            f.response(["type": "function_call", "call_id": "two", "name": "tool", "arguments": "{}"]),
            f.event("task_complete", ["turn_id": "a"]),
            f.event("task_started", ["turn_id": "b"]),
            f.response(["type": "function_call_output", "call_id": "one", "turn_id": "b", "output": "same result"]),
            f.response(["type": "function_call_output", "call_id": "one", "turn_id": "b", "output": "same result"]),
            f.response(["type": "function_call_output", "call_id": "one", "turn_id": "b", "output": "later chunk"]),
            f.response(["type": "function_call_output", "call_id": "two", "output": "same result"]),
            f.event("user_message", ["message": "new prompt", "turn_id": "b"])
        ])
        let graph = try await SessionWorkTopologyLoader(home: f.home).load(session: f.session)
        XCTAssertEqual(graph.currentTurnID, "b")
        let receipts = graph.nodes.filter { $0.kind == .toolResult }
        XCTAssertEqual(receipts.count, 3)
        XCTAssertTrue(receipts.allSatisfy { $0.turnID == "a" })
        XCTAssertEqual(graph.edges.filter { $0.kind == .resultOf }.count, 3)
        XCTAssertTrue(graph.edges.contains { $0.kind == .receivedInTurn && $0.target == "turn:s:b" })
        let implicitLate = try XCTUnwrap(receipts.first { $0.callID == "two" })
        XCTAssertTrue(graph.edges.contains { $0.source == implicitLate.id && $0.kind == .receivedInTurn && $0.target == "turn:s:b" && $0.evidence.contains("시작·종료 구간") })
        XCTAssertEqual(graph.turns.first { $0.id == "a" }?.status, .ended)
        XCTAssertEqual(graph.turns.first { $0.id == "b" }?.promptNodeID, graph.nodes.first { $0.kind == .prompt }?.id)
    }

    func testReversedSpawnResultAndCatalogPathsRecoverOnlyExplicitParticipation() async throws {
        let f = try WorkFixture(); defer { f.remove() }
        try f.addChild("child", path: "/root/check")
        try f.addChild("historical", path: "/root/old")
        let child = Session(id: "child", title: "current child", projectID: nil, cwd: "/fixture", parentID: "s")
        let old = Session(id: "historical", title: "old child", projectID: nil, cwd: "/fixture", parentID: "s")
        try f.write([
            f.event("task_started", ["turn_id": "t"]),
            f.response(["type": "function_call_output", "call_id": "spawn", "output": "{\"agent_id\":\"child\"}"]),
            f.response(["type": "function_call", "call_id": "spawn", "name": "collaboration.spawn_agent", "arguments": "{\"message\":\"check\"}"]),
            f.response(["type": "function_call", "call_id": "send", "name": "collaboration.send_message", "arguments": "{\"target\":\"/root/check\",\"message\":\"continue\"}"])
        ])
        let graph = try await SessionWorkTopologyLoader(home: f.home).load(session: f.session, catalog: [child, old])
        XCTAssertTrue(graph.edges.contains { $0.kind == .spawnedSession })
        XCTAssertTrue(graph.edges.contains { $0.kind == .sentToSession })
        XCTAssertEqual(graph.nodes.first { $0.relatedSessionID == "child" && $0.kind == .subsession }?.turnID, "t")
        XCTAssertNil(graph.nodes.first { $0.relatedSessionID == "historical" }?.turnID)
        XCTAssertTrue(graph.edges.contains { $0.kind == .historicalAssociation && $0.target.contains("historical") })
        XCTAssertEqual(graph.nodes.first { $0.relatedSessionID == "child" && $0.kind == .subsession }?.status, .unknown)
    }

    func testTelemetryRetainsScopesSubsetsUnknownsAndResetSegments() async throws {
        let f = try WorkFixture(); defer { f.remove() }
        try f.write([
            f.event("task_started", ["turn_id": "t"]),
            f.event("token_count", ["turn_id": "t", "info": ["total_token_usage": ["input_tokens": 100, "cached_input_tokens": 80, "output_tokens": 20, "reasoning_output_tokens": 8], "last_token_usage": ["input_tokens": 70, "cached_input_tokens": 50, "output_tokens": 5, "reasoning_output_tokens": 2], "model_context_window": 200]]),
            f.event("token_count", ["info": ["total_token_usage": ["input_tokens": 3, "output_tokens": 2]]]),
            f.event("token_usage_record", ["scope": "turn", "turn_id": "t", "input_tokens": 7, "output_tokens": 3, "includes_subsessions": false]),
            f.event("token_usage_record", ["input_tokens": 8, "output_tokens": 4])
        ])
        let graph = try await SessionWorkTopologyLoader(home: f.home).load(session: f.session)
        let total = try XCTUnwrap(graph.usage.first { $0.input == 100 })
        XCTAssertEqual(total.total, 120)
        XCTAssertEqual(total.cachedInput, 80)
        XCTAssertEqual(total.reasoningOutput, 8)
        XCTAssertNil(total.turnID)
        XCTAssertNil(total.includesSubsessions)
        XCTAssertEqual(total.lastRequestRatio, 0.35)
        XCTAssertTrue(total.scope.contains("세션 누적"))
        let last = try XCTUnwrap(graph.usage.first { $0.input == 70 })
        XCTAssertTrue(last.scope.contains("마지막 요청"))
        XCTAssertEqual(last.turnID, "t")
        XCTAssertEqual(graph.usage.first { $0.input == 7 }?.turnID, "t")
        XCTAssertEqual(graph.usage.first { $0.input == 7 }?.includesSubsessions, false)
        XCTAssertNil(graph.usage.first { $0.input == 8 }?.turnID)
        XCTAssertTrue(graph.usage.first { $0.input == 3 }?.scope.contains("구간 1") == true)
        XCTAssertTrue(graph.coverage.flatMap(\.issues).contains { $0.contains("누적 계측 감소") })
    }

    func testNativeRequestTurnAndThreadCountersRetainExactOwnerAndScopes() async throws {
        let f = try WorkFixture(); defer { f.remove() }
        try f.write([
            ["type": "token_usage_record", "payload": ["thread_id": "s", "session_id": "runtime-session", "turn_id": "t", "usage": ["input_tokens": 10, "cached_input_tokens": 7, "output_tokens": 4, "reasoning_output_tokens": 2], "turn_token_usage": ["input_tokens": 30, "output_tokens": 12], "thread_token_usage": ["input_tokens": 100, "output_tokens": 40]]],
            ["type": "token_usage_record", "payload": ["thread_id": "other-owner", "turn_id": "child-turn", "usage": ["input_tokens": 5, "output_tokens": 2], "turn_token_usage": ["input_tokens": 15, "output_tokens": 6], "thread_token_usage": ["input_tokens": 50, "output_tokens": 20]]]
        ])
        let graph = try await SessionWorkTopologyLoader(home: f.home).load(session: f.session)
        XCTAssertEqual(graph.usage.count, 6)
        let own = graph.usage.filter { $0.sessionID == "s" }
        XCTAssertEqual(own.count, 3)
        XCTAssertEqual(own.first { $0.id.hasSuffix(":request") }?.total, 14)
        XCTAssertEqual(own.first { $0.id.hasSuffix(":turn") }?.total, 42)
        XCTAssertEqual(own.first { $0.id.hasSuffix(":turn") }?.turnID, "t")
        XCTAssertNil(own.first { $0.id.hasSuffix(":thread") }?.turnID)
        XCTAssertEqual(own.first { $0.id.hasSuffix(":thread") }?.total, 140)
        XCTAssertTrue(own.allSatisfy { $0.includesSubsessions == nil && $0.modelContextWindow == nil })
        let child = graph.usage.filter { $0.sessionID == "other-owner" }
        XCTAssertEqual(child.count, 3)
        XCTAssertEqual(child.first { $0.id.hasSuffix(":turn") }?.turnID, "child-turn")
        XCTAssertFalse(graph.turns.contains { $0.id == "child-turn" })
        let ids = Set(graph.nodes.map(\.id))
        XCTAssertTrue(graph.edges.allSatisfy { ids.contains($0.source) && ids.contains($0.target) })
    }

    func testInvalidTelemetryRemainsUnknownWithCoverageEvidence() async throws {
        let f = try WorkFixture(); defer { f.remove() }
        try f.write([
            f.event("token_count", ["info": ["total_token_usage": ["input_tokens": 10, "cached_input_tokens": 11, "output_tokens": 2, "reasoning_output_tokens": 3], "last_token_usage": ["input_tokens": -1, "output_tokens": true], "model_context_window": 10.5]]),
            f.event("token_usage_record", ["input_tokens": true, "output_tokens": -4, "cached_input_tokens": "5"])
        ])
        let graph = try await SessionWorkTopologyLoader(home: f.home).load(session: f.session)
        let total = try XCTUnwrap(graph.usage.first { $0.input == 10 })
        XCTAssertEqual(total.total, 12)
        XCTAssertNil(total.cachedInput)
        XCTAssertNil(total.reasoningOutput)
        XCTAssertNil(total.lastRequestRatio)
        XCTAssertNil(total.modelContextWindow)
        XCTAssertTrue(graph.usage.last?.input == nil && graph.usage.last?.output == nil)
        XCTAssertGreaterThanOrEqual(graph.coverage.flatMap(\.issues).filter { $0.contains("계측") || $0.contains("초과") }.count, 6)
        XCTAssertTrue(graph.coverage.contains { $0.status == .partial })
    }

    func testCompleteNewlineBoundaryAndAppendOnlyPolling() async throws {
        let f = try WorkFixture(); defer { f.remove() }
        let prompt = try f.data(f.event("user_message", ["message": "request", "turn_id": "t"]))
        try f.write([f.event("task_started", ["turn_id": "t"])])
        try f.appendData(prompt.prefix(prompt.count / 2))
        let loader = SessionWorkTopologyLoader(home: f.home)
        let first = try await loader.load(session: f.session)
        XCTAssertFalse(first.nodes.contains { $0.kind == .prompt })
        XCTAssertTrue(first.coverage.flatMap(\.issues).contains { $0.contains("미완결") })
        let firstDiagnostics = try await diagnostics(loader)
        try f.appendData(prompt.suffix(prompt.count - prompt.count / 2) + Data([10]))
        let second = try await loader.load(session: f.session)
        XCTAssertEqual(second.nodes.filter { $0.kind == .prompt }.count, 1)
        let append = try await diagnostics(loader)
        XCTAssertEqual(append.parsedRecords, 1)
        XCTAssertEqual(append.completeOffset, UInt64(try Data(contentsOf: f.rollout).count))
        XCTAssertEqual(append.generation, firstDiagnostics.generation)
        _ = try await loader.load(session: f.session)
        let warm = try await diagnostics(loader)
        XCTAssertEqual(warm.parsedRecords, 0)
        XCTAssertEqual(warm.lastReadBytes, 0)
    }

    func testRotationTruncationAndSourceLossInvalidateReferencesButPreserveLastSafeMetrics() async throws {
        let f = try WorkFixture(); defer { f.remove() }
        let oldRecord = f.event("token_usage_record", ["input_tokens": 10, "output_tokens": 2])
        try f.write([oldRecord, f.event("vendor_unknown", ["value": "preserved"] )])
        let loader = SessionWorkTopologyLoader(home: f.home)
        let first = try await loader.load(session: f.session)
        let oldNode = try XCTUnwrap(first.nodes.first { $0.kind == .usage })
        let oldGeneration = try await diagnostics(loader).generation
        try f.write([oldRecord], atomic: true)
        let second = try await loader.load(session: f.session)
        XCTAssertEqual(second.nodes.filter { $0.kind == .usage }.count, 1)
        let newDiagnostics = try await diagnostics(loader)
        XCTAssertGreaterThan(newDiagnostics.generation, oldGeneration)
        do { _ = try await loader.loadBody(node: oldNode); XCTFail("Expected obsolete generation rejection") } catch { }
        try f.write([f.event("token_usage_record", ["input_tokens": 1])])
        let truncated = try await loader.load(session: f.session)
        XCTAssertEqual(truncated.usage.first?.input, 1)
        try FileManager.default.removeItem(at: f.rollout)
        let missing = try await loader.load(session: f.session)
        XCTAssertEqual(missing.usage.first?.input, 1)
        XCTAssertTrue(missing.sourceIsStale)
        try FileManager.default.removeItem(at: f.state)
        let noMetadata = try await loader.load(session: f.session)
        XCTAssertEqual(noMetadata.usage.first?.input, 1)
        XCTAssertTrue(noMetadata.sourceIsStale)
    }

    func testUnknownRecordsAndPrivateReasoningArePreservedWithoutPrivateText() async throws {
        let f = try WorkFixture(); defer { f.remove() }
        try f.write([
            f.event("vendor_unknown", ["opaque": ["nested": "public"]]),
            f.response(["type": "reasoning", "id": "private", "content": "SECRET_REASONS", "encrypted_content": "SECRET_CIPHER"]),
            f.response(["type": "message", "role": "assistant", "channel": "analysis", "content": [["type": "output_text", "text": "SECRET_ANALYSIS"]]]),
            f.event("wrapper_unknown", ["nested": ["type": "reasoning", "text": "SECRET_NESTED"], "public": "kept"])
        ])
        try f.appendData(Data("{\"type\":\"reasoning\",SECRET_MALFORMED\n".utf8))
        let loader = SessionWorkTopologyLoader(home: f.home)
        let graph = try await loader.load(session: f.session)
        XCTAssertEqual(graph.nodes.filter { $0.kind == .other }.count, 5)
        XCTAssertTrue(graph.coverage.flatMap(\.issues).contains { $0.contains("vendor_unknown") })
        for node in graph.nodes where node.bodyReference != nil {
            XCTAssertFalse(node.bodyPreview.contains("SECRET"))
            XCTAssertFalse(node.summary.contains("SECRET"))
            let body = try await loader.loadBody(node: node)
            XCTAssertFalse(body.contains("SECRET"))
        }
        let unknown = try XCTUnwrap(graph.nodes.first { $0.title == "vendor_unknown" })
        let unknownBody = try await loader.loadBody(node: unknown)
        XCTAssertTrue(unknownBody.contains("public"))
    }

    func testMixedPublicMessageBlocksCannotExposeNestedPrivateText() async throws {
        let f = try WorkFixture(); defer { f.remove() }
        try f.write([
            f.response(["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "public response"], ["type": "reasoning", "text": "SECRET_REASONING"], ["type": "analysis", "text": "SECRET_ANALYSIS"]], "analysis": "SECRET_FIELD"])
        ])
        let loader = SessionWorkTopologyLoader(home: f.home)
        let graph = try await loader.load(session: f.session)
        let message = try XCTUnwrap(graph.nodes.first { $0.kind == .message })
        XCTAssertEqual(message.summary, "public response")
        XCTAssertEqual(message.bodyPreview, "public response")
        let body = try await loader.loadBody(node: message)
        XCTAssertFalse(body.contains("SECRET"))
        XCTAssertTrue(body.contains("public response"))
    }

    func testCatalogAcceptsLowercaseAndLegacySubAgentWithoutDatabaseWrites() throws {
        let f = try WorkFixture(); defer { f.remove() }
        try f.addChild("lower", path: "/root/lower")
        try f.addChild("legacy", path: "/root/legacy", key: "subAgent")
        let before = try Data(contentsOf: f.state)
        let catalog = try CodexCatalog(home: f.home).read()
        XCTAssertEqual(catalog.sessions.first { $0.id == "lower" }?.parentID, "s")
        XCTAssertEqual(catalog.sessions.first { $0.id == "legacy" }?.parentID, "s")
        XCTAssertEqual(try Data(contentsOf: f.state), before)
    }

    func testSameSizeMiddleMutationCreatesNewGeneration() async throws {
        let f = try WorkFixture(); defer { f.remove() }
        let padding = String(repeating: "padding", count: 900)
        try f.write([
            f.event("vendor_padding", ["value": padding]),
            f.event("user_message", ["message": "old request", "turn_id": "t"]),
            f.event("vendor_padding", ["value": padding])
        ])
        let loader = SessionWorkTopologyLoader(home: f.home)
        let original = try await loader.load(session: f.session)
        let oldNode = try XCTUnwrap(original.nodes.first { $0.kind == .prompt })
        let before = try await diagnostics(loader)
        var contents = try String(contentsOf: f.rollout, encoding: .utf8)
        contents = contents.replacingOccurrences(of: "old request", with: "new request")
        try Data(contents.utf8).write(to: f.rollout)
        // A deterministic mtime change avoids filesystem timestamp-granularity assumptions.
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_791_000_001)], ofItemAtPath: f.rollout.path)
        let changed = try await loader.load(session: f.session)
        let after = try await diagnostics(loader)
        XCTAssertGreaterThan(after.generation, before.generation)
        XCTAssertEqual(changed.nodes.first { $0.kind == .prompt }?.bodyPreview, "new request")
        do { _ = try await loader.loadBody(node: oldNode); XCTFail("Expected obsolete same-inode source rejection") } catch { }
    }

    func testCanonicalTaskPathSpawnAndPublicAgentMessageUseRecordedAddressing() async throws {
        let f = try WorkFixture(); defer { f.remove() }
        try f.addChild("child", path: "/root/check")
        try f.write([
            f.event("task_started", ["turn_id": "work"]),
            f.response(["type": "function_call", "call_id": "spawn", "name": "spawn_agent", "arguments": "{\"task_name\":\"check\"}"]),
            f.response(["type": "function_call_output", "call_id": "spawn", "output": "{\"task_name\":\"/root/check\"}"]),
            ["type": "inter_agent_communication_metadata", "payload": ["trigger_turn": false]],
            f.response(["type": "agent_message", "id": "report", "author": "/root/check", "recipient": "/root", "content": [["type": "text", "text": "public report"]], "internal_chat_message_metadata_passthrough": ["turn_id": "report-turn"]])
        ])
        let graph = try await SessionWorkTopologyLoader(home: f.home).load(session: f.session)
        XCTAssertTrue(graph.edges.contains { $0.kind == .spawnedSession })
        let report = try XCTUnwrap(graph.nodes.first { $0.id == "item:s:report" })
        XCTAssertEqual(report.turnID, "report-turn")
        XCTAssertEqual(report.bodyPreview, "public report")
        XCTAssertEqual(report.relatedSessionID, "child")
        XCTAssertTrue(graph.edges.contains { $0.source == report.id && $0.kind == .reportedBy })
        XCTAssertEqual(graph.currentTurnID, "work")
        XCTAssertFalse(graph.coverage.flatMap(\.issues).contains { $0.contains("알 수 없는 타입 inter_agent") })
    }

    func testDelayedChildCatalogMappingResolvesWithoutReparsingRollout() async throws {
        let f = try WorkFixture(); defer { f.remove() }
        try f.write([
            f.event("task_started", ["turn_id": "t"]),
            f.response(["type": "function_call", "call_id": "spawn", "name": "spawn_agent", "arguments": "{}"]),
            f.response(["type": "function_call_output", "call_id": "spawn", "output": "{\"task_name\":\"/root/later\"}"])
        ])
        let loader = SessionWorkTopologyLoader(home: f.home)
        let before = try await loader.load(session: f.session)
        XCTAssertFalse(before.edges.contains { $0.kind == .spawnedSession })
        try f.addChild("later", path: "/root/later")
        let after = try await loader.load(session: f.session)
        let warm = try await diagnostics(loader)
        XCTAssertEqual(warm.parsedRecords, 0)
        XCTAssertTrue(after.edges.contains { $0.kind == .spawnedSession })
        XCTAssertEqual(after.nodes.first { $0.kind == .subsession }?.relatedSessionID, "later")
    }

    func testNativeRepeatedResultHistoryUsesLatestObservationTimestamp() async throws {
        let f = try WorkFixture(); defer { f.remove() }
        let t0 = "2026-10-04T01:00:00Z"
        let t1 = "2026-10-04T01:00:10Z"
        let t2 = "2026-10-04T01:00:20Z"
        let t3 = "2026-10-04T01:00:30Z"
        try f.write([
            f.event("task_started", ["turn_id": "t"], timestamp: t0),
            f.event("item_started", ["item": ["type": "CommandExecution", "id": "c", "status": "inProgress", "aggregated_output": ""]], timestamp: t0),
            f.event("item_completed", ["item": ["type": "CommandExecution", "id": "c", "status": "completed", "exit_code": 1]], timestamp: t1),
            f.event("item_completed", ["item": ["type": "CommandExecution", "id": "c", "status": "completed", "exit_code": 0]], timestamp: t2),
            f.event("item_completed", ["item": ["type": "CommandExecution", "id": "c", "status": "completed"]], timestamp: t3)
        ])
        let graph = try await SessionWorkTopologyLoader(home: f.home).load(session: f.session)
        let call = try XCTUnwrap(graph.nodes.first { $0.kind == .command })
        let start = try XCTUnwrap(call.timestamp)
        XCTAssertEqual(call.status(at: start.addingTimeInterval(5)), .running)
        XCTAssertEqual(call.status(at: start.addingTimeInterval(15)), .failed)
        XCTAssertEqual(call.status(at: start.addingTimeInterval(25)), .succeeded)
        XCTAssertEqual(call.status(at: start.addingTimeInterval(35)), .succeeded)
        XCTAssertEqual(graph.nodes.filter { $0.id.hasPrefix("native-result:") }.count, 1)
    }

    func testNativeLateCompletionKeepsOriginalTurnAndRecordsReceivingTurn() async throws {
        let f = try WorkFixture(); defer { f.remove() }
        try f.write([
            f.event("task_started", ["turn_id": "a"], timestamp: "2026-10-04T01:00:00Z"),
            f.event("item_started", ["turn_id": "a", "item": ["type": "CommandExecution", "id": "late", "status": "inProgress", "aggregated_output": ""]], timestamp: "2026-10-04T01:00:00Z"),
            f.event("task_complete", ["turn_id": "a"]),
            f.event("task_started", ["turn_id": "b"]),
            f.event("item_completed", ["turn_id": "b", "item": ["type": "CommandExecution", "id": "late", "status": "completed", "exit_code": 0]], timestamp: "2026-10-04T01:00:20Z")
        ])
        let graph = try await SessionWorkTopologyLoader(home: f.home).load(session: f.session)
        let command = try XCTUnwrap(graph.nodes.first { $0.kind == .command })
        let receipt = try XCTUnwrap(graph.nodes.first { $0.kind == .toolResult })
        XCTAssertEqual(command.turnID, "a")
        XCTAssertEqual(receipt.turnID, "a")
        XCTAssertEqual(command.status, .succeeded)
        XCTAssertEqual(graph.currentTurnID, "b")
        XCTAssertFalse(graph.edges.contains { ($0.source == command.id || $0.source == receipt.id) && $0.kind == .belongsToTurn && $0.target == "turn:s:b" })
        XCTAssertTrue(graph.edges.contains { $0.source == receipt.id && $0.kind == .receivedInTurn && $0.target == "turn:s:b" })
        let receivingEdge = try XCTUnwrap(graph.edges.first { $0.source == receipt.id && $0.kind == .receivedInTurn })
        XCTAssertEqual(receivingEdge.observedAt, command.timestamp?.addingTimeInterval(20))
        XCTAssertFalse(graph.edges.contains { $0.source == command.id && $0.kind == .receivedInTurn })
    }

    func testIDLessStartClearsIntervalAndCurrentTurnUntilReliableBoundary() async throws {
        let f = try WorkFixture(); defer { f.remove() }
        try f.write([
            f.event("task_started", ["turn_id": "old"]),
            f.event("task_started", [:]),
            f.event("user_message", ["message": "unknown request"]),
            f.response(["type": "function_call", "call_id": "unknown", "name": "tool", "arguments": "{}"])
        ])
        let loader = SessionWorkTopologyLoader(home: f.home)
        let unknown = try await loader.load(session: f.session)
        XCTAssertNil(unknown.currentTurnID)
        XCTAssertNil(unknown.nodes.first { $0.kind == .prompt }?.turnID)
        XCTAssertNil(unknown.nodes.first { $0.callID == "unknown" }?.turnID)
        try f.append(f.event("turn_context", ["turn_id": "known", "model": "m", "effort": "high"]))
        try f.append(f.event("user_message", ["message": "known request"]))
        let known = try await loader.load(session: f.session)
        XCTAssertEqual(known.currentTurnID, "known")
        XCTAssertEqual(known.nodes.last { $0.kind == .prompt }?.turnID, "known")
    }

    func testExplicitArtifactCollaborationAndDynamicToolProducers() async throws {
        let f = try WorkFixture(); defer { f.remove() }
        let largeResult = Dictionary(uniqueKeysWithValues: (0..<50).map { ("field_\($0)", String(repeating: "public", count: 100)) })
        try f.write([
            f.event("task_started", ["turn_id": "t"]),
            f.response(["type": "fileChange", "id": "file", "status": "completed", "changes": [["path": "/fixture/App.swift", "kind": "update", "diff": "+new"]]]),
            f.response(["type": "imageView", "id": "image", "path": "/fixture/view.png"]),
            f.response(["type": "collabToolCall", "id": "spawn", "tool": "spawnAgent", "senderThreadId": "s", "newThreadId": "child", "status": "completed"]),
            f.response(["type": "collabToolCall", "id": "send", "tool": "sendInput", "senderThreadId": "peer", "receiverThreadId": "child", "status": "inProgress"]),
            f.response(["type": "dynamicToolCall", "id": "dynamic", "tool": "publicTool", "success": false, "status": "completed", "result": largeResult])
        ])
        let graph = try await SessionWorkTopologyLoader(home: f.home).load(session: f.session)
        XCTAssertEqual(graph.edges.filter { $0.kind == .referencesArtifact }.count, 2)
        XCTAssertTrue(graph.nodes.contains { $0.kind == .artifact && $0.title == "/fixture/App.swift" && $0.status == .unknown })
        XCTAssertFalse(graph.edges.contains { $0.kind == .supportsClaim })
        XCTAssertTrue(graph.edges.contains { $0.kind == .spawnedSession })
        XCTAssertTrue(graph.edges.contains { $0.kind == .sentToSession })
        XCTAssertTrue(graph.edges.contains { $0.kind == .reportedBy })
        XCTAssertEqual(graph.nodes.first { $0.callID == "dynamic" && $0.kind == .toolCall }?.status, .failed)
        XCTAssertTrue(graph.nodes.allSatisfy { $0.bodyPreview.count <= 1800 })
    }

    func testDerivedChildAndArtifactNodesUseProducerObservationTimeAndBody() async throws {
        let f = try WorkFixture(); defer { f.remove() }
        try f.addChild("child", path: "/root/check")
        try f.write([
            f.event("task_started", ["turn_id": "t"], timestamp: "2026-10-04T01:00:00Z"),
            f.event("item_completed", ["item": ["type": "collabToolCall", "id": "spawn", "tool": "spawnAgent", "newThreadId": "child"]], timestamp: "2026-10-04T01:00:20Z"),
            f.event("item_completed", ["item": ["type": "fileChange", "id": "file", "changes": [["path": "/fixture/later.swift", "kind": "update", "diff": "+future"]]]], timestamp: "2026-10-04T01:00:30Z")
        ])
        let graph = try await SessionWorkTopologyLoader(home: f.home).load(session: f.session)
        let child = try XCTUnwrap(graph.nodes.first { $0.kind == .subsession && $0.turnID == "t" })
        let artifact = try XCTUnwrap(graph.nodes.first { $0.title == "/fixture/later.swift" })
        XCTAssertNotNil(child.timestamp)
        XCTAssertNotNil(child.bodyReference)
        XCTAssertNotNil(child.statusHistory.first?.recordOrdinal)
        XCTAssertNotNil(artifact.timestamp)
        XCTAssertNotNil(artifact.bodyReference)
        XCTAssertNotNil(artifact.statusHistory.first?.recordOrdinal)
        let start = try XCTUnwrap(graph.turns.first?.startedAt)
        XCTAssertGreaterThan(try XCTUnwrap(child.timestamp), start.addingTimeInterval(10))
        XCTAssertGreaterThan(try XCTUnwrap(artifact.timestamp), start.addingTimeInterval(10))
        XCTAssertNil(child.observation(at: start.addingTimeInterval(10)))
        XCTAssertNil(artifact.observation(at: start.addingTimeInterval(10)))
    }

    func testCancelledLoadNeverPublishesACandidateIndex() async throws {
        let f = try WorkFixture(); defer { f.remove() }
        try f.write([f.event("task_started", ["turn_id": "t"])])
        let loader = SessionWorkTopologyLoader(home: f.home)
        _ = try await loader.load(session: f.session)
        let before = try await diagnostics(loader)
        let record = try f.data(f.event("vendor_unknown", ["value": String(repeating: "x", count: 1024)])) + Data([10])
        for _ in 0..<2000 { try f.appendData(record) }
        let task = Task { try await loader.load(session: f.session) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError { }
        let after = try await diagnostics(loader)
        XCTAssertEqual(after.completeOffset, before.completeOffset)
        XCTAssertEqual(after.totalParsedRecords, before.totalParsedRecords)
    }
}

final class SessionWorkPerformanceTests: XCTestCase {
    func testHundredMegabyteColdWarmAndAppendReadBoundaries() async throws {
        let f = try WorkFixture(); defer { f.remove() }
        try f.write([f.event("task_started", ["turn_id": "large-turn"])])
        let record = try f.data(f.event("vendor_large", ["value": String(repeating: "x", count: 104 * 1024)])) + Data([10])
        for _ in 0..<1024 { try f.appendData(record) }
        let byteCount = try Data(contentsOf: f.rollout, options: .mappedIfSafe).count
        XCTAssertGreaterThan(byteCount, 100 * 1024 * 1024)
        let loader = SessionWorkTopologyLoader(home: f.home)
        let coldStart = Date()
        let cold = try await loader.load(session: f.session)
        let coldSeconds = Date().timeIntervalSince(coldStart)
        let coldDiagnostic = await loader.diagnostics(sessionID: "s")
        XCTAssertEqual(coldDiagnostic?.lastReadBytes, byteCount)
        XCTAssertEqual(coldDiagnostic?.totalParsedRecords, 1025)
        XCTAssertTrue(cold.nodes.allSatisfy { $0.bodyPreview.count <= 1800 })
        let warmStart = Date()
        _ = try await loader.load(session: f.session)
        let warmSeconds = Date().timeIntervalSince(warmStart)
        let warm = await loader.diagnostics(sessionID: "s")
        XCTAssertEqual(warm?.parsedRecords, 0)
        XCTAssertEqual(warm?.lastReadBytes, 0)
        let appended = try f.data(f.event("user_message", ["turn_id": "large-turn", "message": "appended request"])) + Data([10])
        try f.appendData(appended)
        let appendStart = Date()
        let graph = try await loader.load(session: f.session)
        let appendSeconds = Date().timeIntervalSince(appendStart)
        let append = await loader.diagnostics(sessionID: "s")
        XCTAssertEqual(append?.lastReadBytes, appended.count)
        XCTAssertEqual(append?.parsedRecords, 1)
        XCTAssertEqual(graph.nodes.filter { $0.kind == .prompt }.count, 1)
        var resource = rusage()
        getrusage(RUSAGE_SELF, &resource)
        print("SESSION_CIRCUIT_PERFORMANCE bytes=\(byteCount) records=1025 cold_seconds=\(coldSeconds) warm_seconds=\(warmSeconds) append_seconds=\(appendSeconds) warm_parsed=\(warm?.parsedRecords ?? -1) warm_suffix_bytes=\(warm?.lastReadBytes ?? -1) append_suffix_bytes=\(append?.lastReadBytes ?? -1) process_peak_rss_bytes=\(resource.ru_maxrss)")
    }
}

private struct WorkFixture {
    let home: URL
    var state: URL { home.appendingPathComponent("state_5.sqlite") }
    var rollout: URL { home.appendingPathComponent("rollout.jsonl") }
    var session: Session { Session(id: "s", title: "fixture", projectID: nil, cwd: "/fixture", model: "fixture-model", effort: "high") }
    init() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("SessionWork-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try execute("CREATE TABLE threads(id TEXT PRIMARY KEY,title TEXT,cwd TEXT,updated_at INTEGER,archived INTEGER,rollout_path TEXT,source TEXT)")
        try execute("INSERT INTO threads VALUES(?,?,?,?,?,?,?)", bindings: ["s", "fixture", "/fixture", "1", "0", rollout.path, "cli"])
    }
    func remove() { try? FileManager.default.removeItem(at: home) }
    func event(_ type: String, _ fields: [String: Any], timestamp: String? = nil) -> [String: Any] {
        var payload = fields; payload["type"] = type
        var json: [String: Any] = ["type": "event_msg", "payload": payload]
        if let timestamp { json["timestamp"] = timestamp }
        return json
    }
    func response(_ payload: [String: Any]) -> [String: Any] { ["type": "response_item", "payload": payload] }
    func data(_ json: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]) }
    func write(_ records: [[String: Any]], atomic: Bool = false) throws {
        var bytes = Data()
        for record in records { bytes.append(try data(record)); bytes.append(10) }
        try bytes.write(to: rollout, options: atomic ? .atomic : [])
    }
    func append(_ record: [String: Any]) throws { try appendData(try data(record) + Data([10])) }
    func appendData<D: DataProtocol>(_ data: D) throws {
        let file = try FileHandle(forWritingTo: rollout); defer { try? file.close() }
        try file.seekToEnd(); try file.write(contentsOf: data)
    }
    func addChild(_ id: String, path: String, key: String = "subagent") throws {
        let source = try data([key: ["thread_spawn": ["parent_thread_id": "s", "agent_path": path]]])
        try execute("INSERT INTO threads VALUES(?,?,?,?,?,?,?)", bindings: [id, id, "/fixture", "1", "0", "", String(decoding: source, as: UTF8.self)])
    }
    private func execute(_ sql: String, bindings: [String] = []) throws {
        var db: OpaquePointer?
        guard sqlite3_open(state.path, &db) == SQLITE_OK else { throw MaestroError.message("fixture database open failed") }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw MaestroError.message(String(cString: sqlite3_errmsg(db))) }
        defer { sqlite3_finalize(statement) }
        for (index, value) in bindings.enumerated() {
            let result = value.withCString { sqlite3_bind_text(statement, Int32(index + 1), $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            guard result == SQLITE_OK else { throw MaestroError.message("fixture binding failed") }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw MaestroError.message(String(cString: sqlite3_errmsg(db))) }
    }
}
