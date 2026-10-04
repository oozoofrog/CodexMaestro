import Foundation

public extension SessionWorkTopology {
    /// Fixed synthetic data for visual and accessibility smoke checks. It never invokes a tool.
    static func demo(session: Session) -> SessionWorkTopology {
        let date = Date(timeIntervalSince1970: 1_791_000_000)
        let turn = "synthetic-turn"
        let rootID = "turn:\(session.id):\(turn)"
        let prefix = "synthetic:\(session.id):"
        let specifications: [(String, WorkNodeKind, String, String, WorkStatus, Int)] = [
            ("instructions", .instruction, "저장된 지침·컨텍스트", "합성 자료 · 실제 모델 입력 전체를 뜻하지 않습니다.", .ended, 0),
            ("prompt", .prompt, "현재 프롬프트", "선택 세션의 동적 작업 회로를 검토해 주세요. 합성 프롬프트입니다.", .ended, 1),
            ("command", .command, "swift test --filter SessionWork", "합성 실행 · 실제 테스트를 실행하지 않았습니다.", .succeeded, 3),
            ("command-result", .toolResult, "합성 명령 결과", "합성 exit_code: 0 · 사용자 결과 검증은 별도입니다.", .succeeded, 5),
            ("mcp", .mcp, "swift_intelligence · references", "합성 MCP 호출 · 도구 인수와 결과를 선택해서 확인합니다.", .failed, 4),
            ("mcp-result", .toolResult, "합성 MCP 오류", "합성 result.isError: true · 재시도는 별도 호출입니다.", .failed, 6),
            ("retry", .mcp, "swift_intelligence · 재시도", "합성 native status: inProgress · 결과 미수신", .running, 7),
            ("child", .subsession, "합성 하위 세션", "합성 위임 관계 · 실제 하위 세션을 생성하지 않았습니다.", .unknown, 3),
            ("message", .message, "공개 진행 보고", "합성 보고 · 명령 결과와 MCP 오류를 별도로 확인합니다.", .ended, 8),
            ("compaction", .compaction, "합성 컨텍스트 압축", "합성 압축 기록 · 현재 점유율은 미확인입니다.", .ended, 2),
            ("artifact", .artifact, "합성 산출물 참조", "합성 경로: /fixture/report.txt · 실제 파일을 만들지 않았습니다.", .unknown, 9),
            ("verification", .verification, "합성 검증 근거", "합성 소스·테스트 근거 · 실제 기기·배포 검증은 미확인입니다.", .unknown, 9),
            ("waiting", .waiting, "합성 입력 대기", "합성 입력 요청 · 답변을 제출하지 않습니다.", .waiting, 10),
            ("usage", .usage, "합성 토큰 계측", "합성 입력 24,380 + 출력 2,140 = 26,520", .ended, 8)
        ]
        var nodes = specifications.map { name, kind, title, summary, status, seconds in
            WorkNode(id: prefix + name, sessionID: session.id, turnID: turn, kind: kind, title: title, summary: summary, bodyPreview: summary + "\nSYNTHETIC DEMO — actual execution is unverified.", status: status, timestamp: date.addingTimeInterval(Double(seconds)), callID: ["command", "mcp", "retry"].contains(name) ? "synthetic-" + name : nil, relatedSessionID: name == "child" ? "synthetic-child" : nil, source: "합성 시연 자료 / deterministic demo")
        }
        nodes.insert(WorkNode(id: rootID, sessionID: session.id, turnID: turn, kind: .session, title: session.title + " · 합성 시연", summary: "합성 turn · 실제 실행 상태가 아닙니다.", status: .running, timestamp: date, source: "합성 시연 자료"), at: 0)
        var edges = specifications.map { WorkRelation(source: prefix + $0.0, target: rootID, kind: .belongsToTurn, evidence: "합성 명시 ID") }
        edges += [
            WorkRelation(source: prefix + "instructions", target: prefix + "prompt", kind: .recordedNext, evidence: "합성 기록 순서"),
            WorkRelation(source: rootID, target: prefix + "command", kind: .calls, evidence: "합성 호출 ID"),
            WorkRelation(source: rootID, target: prefix + "mcp", kind: .calls, evidence: "합성 호출 ID"),
            WorkRelation(source: rootID, target: prefix + "retry", kind: .calls, evidence: "합성 새 호출 ID"),
            WorkRelation(source: prefix + "command-result", target: prefix + "command", kind: .resultOf, evidence: "합성 call_id"),
            WorkRelation(source: prefix + "mcp-result", target: prefix + "mcp", kind: .resultOf, evidence: "합성 call_id"),
            WorkRelation(source: rootID, target: prefix + "child", kind: .spawnedSession, evidence: "합성 child ID"),
            WorkRelation(source: prefix + "message", target: prefix + "child", kind: .reportedBy, evidence: "합성 공개 보고 ID"),
            WorkRelation(source: prefix + "message", target: prefix + "artifact", kind: .referencesArtifact, evidence: "합성 경로 참조"),
            WorkRelation(source: prefix + "verification", target: prefix + "command-result", kind: .supportsClaim, evidence: "합성 근거 범위"),
            WorkRelation(source: rootID, target: prefix + "usage", kind: .observedUsage, evidence: "합성 명시된 turn 계측")
        ]
        let usage = WorkUsage(id: prefix + "telemetry", sessionID: session.id, turnID: turn, input: 24_380, cachedInput: 21_500, output: 2_140, reasoningOutput: 840, lastRequestInput: 19_800, modelContextWindow: 128_000, timestamp: date.addingTimeInterval(8), source: "합성 시연 자료", scope: "합성 명시된 turn 계측", includesSubsessions: false)
        return SessionWorkTopology(sessionID: session.id, title: session.title + " · 합성 시연", nodes: nodes, edges: edges, turns: [WorkTurn(id: turn, sessionID: session.id, promptNodeID: prefix + "prompt", status: .running, startedAt: date, model: "synthetic-model", effort: "synthetic")], usage: [usage], coverage: [ContextCoverage(source: "합성 시연 자료", sessionID: session.id, status: .complete, records: specifications.count, issues: ["모든 이벤트·상태·시각·계측은 합성 자료입니다. 실제 실행·테스트·배포 증거가 아닙니다."])], loadedAt: date.addingTimeInterval(10), currentTurnID: turn)
    }
}
