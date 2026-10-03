import Foundation
import MaestroCore

enum ContextDemoTopology {
    static func make(scope: LinkEndpoint, projects: [Project], sessions: [Session]) -> ContextTopology {
        let members = sessions.filter { scope.kind == .project ? $0.projectID == scope.id : $0.id == scope.id }
        let title = scope.kind == .project ? projects.first { $0.id == scope.id }?.name ?? "프로젝트" : members.first?.title ?? "세션"
        var graph = ContextTopology(scope: scope, title: title, sessions: members)
        graph.boundaries = ["데모 기록입니다. 실제 세션의 기록이나 실행 근거가 아닙니다."]
        let rootID = scope.kind == .project ? "project:\(scope.id)" : "session:\(scope.id)"
        if scope.kind == .project {
            graph.nodes.append(ContextNode(id: rootID, kind: .project, title: title, summary: "\(members.count)개 세션", fullText: "프로젝트 컨텍스트의 데모입니다.", source: "demo"))
        }
        for session in members {
            let id = "session:\(session.id)"
            graph.nodes.append(ContextNode(id: id, parentID: scope.kind == .project ? rootID : nil, kind: .session, title: session.title, summary: "데모 기록", fullText: "모델: \(session.model)\n작업 경로: \(session.cwd)\n데모 세션입니다.", source: "demo", sessionID: session.id))
            if scope.kind == .project { graph.edges.append(ContextEdge(source: rootID, target: id, relation: "구성원")) }
            let conversation = ContextNode(id: id + ":conversation", parentID: id, kind: .group, title: "대화", summary: "요청과 응답", source: "demo", sessionID: session.id, recordCount: 2)
            let instructions = ContextNode(id: id + ":instructions", parentID: id, kind: .group, title: "지침", summary: "현재 작업의 조건", source: "demo", sessionID: session.id, recordCount: 1)
            let tool = ContextNode(id: id + ":tool", parentID: id, kind: .tool, title: "exec_command", summary: "호출과 결과", source: "demo", sessionID: session.id, recordCount: 1)
            let compaction = ContextNode(id: id + ":compaction", parentID: id, kind: .compaction, title: "압축 기록", summary: "이전 작업의 요약", fullText: "완료: 연결 대상 확인\n유지할 조건: 기존 초안 보존, 실제 전송은 사용자 실행\n다음 작업: 컨텍스트와 툴 호출 기록 검토\n데모 예시입니다.", source: "demo", sessionID: session.id, recordCount: 1)
            graph.nodes += [conversation, instructions, tool, compaction]
            graph.nodes += [
                ContextNode(id: id + ":request", parentID: conversation.id, kind: .message, title: "요청", fullText: "세션 상태를 관찰하고 연결된 작업 간 컨텍스트를 전달할 수 있도록 구성해주세요.\n데모 대화입니다.", source: "demo", sessionID: session.id, recordCount: 1),
                ContextNode(id: id + ":response", parentID: conversation.id, kind: .message, title: "응답", fullText: "프로젝트별 세션을 구성했습니다. 다음 작업은 기록을 확인하고 담당 세션에 요청할 수 있습니다.\n데모 대화입니다.", source: "demo", sessionID: session.id, recordCount: 1),
                ContextNode(id: id + ":instruction", parentID: instructions.id, kind: .instruction, title: "작업 조건", fullText: "기존 초안을 덮어쓰지 않습니다. 저장된 기록과 실제 실행 결과를 구분합니다.\n데모 지침입니다.", source: "demo", sessionID: session.id, recordCount: 1),
                ContextNode(id: id + ":call", parentID: tool.id, kind: .toolCall, title: "swift test", summary: "검증 명령", fullText: "swift test\n데모 호출 기록입니다.", source: "demo", sessionID: session.id, recordCount: 1),
                ContextNode(id: id + ":result", parentID: tool.id, kind: .toolResult, title: "검증 결과", summary: "출력 예시", fullText: "Test Suite passed\n데모 출력이며 실제 검증 결과가 아닙니다.", source: "demo", sessionID: session.id, recordCount: 1)
            ]
            graph.coverage.append(ContextCoverage(source: "demo:\(session.id)", sessionID: session.id, status: .complete, records: 6))
        }
        for node in graph.nodes where node.parentID != nil { graph.edges.append(ContextEdge(source: node.parentID!, target: node.id, relation: "포함")) }
        return graph
    }
}
