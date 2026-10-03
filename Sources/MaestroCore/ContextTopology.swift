import Foundation

public enum ContextNodeKind: String, CaseIterable, Sendable {
    case project, session, group, message, instruction, tool, toolCall, toolResult, skill, plugin, metadata, usage, compaction, association, file, other
    public var label: String {
        switch self {
        case .project: "프로젝트"; case .session: "세션"; case .group: "기록 묶음"; case .message: "대화"; case .instruction: "지침"
        case .tool: "관찰된 도구"; case .toolCall: "도구 호출"; case .toolResult: "도구 결과"; case .skill: "스킬 참조"; case .plugin: "플러그인 참조"
        case .metadata: "메타데이터"; case .usage: "사용량 기록"; case .compaction: "압축 기록"; case .association: "세션 관계"; case .file: "파일 참조"; case .other: "기타 기록"
        }
    }
    public var symbol: String {
        switch self {
        case .project: "folder"; case .session: "bubble.left.and.bubble.right"; case .group: "square.stack"; case .message: "text.bubble"; case .instruction: "doc.text"
        case .tool: "wrench.and.screwdriver"; case .toolCall: "arrow.up.right"; case .toolResult: "arrow.down.left"; case .skill: "sparkles"; case .plugin: "puzzlepiece"
        case .metadata: "info.circle"; case .usage: "chart.bar"; case .compaction: "archivebox"; case .association: "arrow.triangle.branch"; case .file: "doc"; case .other: "ellipsis.circle"
        }
    }
}
public struct ContextBodyReference: Sendable {
    public let path: String
    public let offset: UInt64
    public let length: Int
    public let fingerprint: String
    public let itemID: String?
    public let sessionID: String?
    public init(path: String, offset: UInt64, length: Int, fingerprint: String, itemID: String? = nil, sessionID: String? = nil) {
        self.path = path; self.offset = offset; self.length = length; self.fingerprint = fingerprint; self.itemID = itemID; self.sessionID = sessionID
    }
}
public struct ContextNode: Identifiable, Sendable {
    public let id: String
    public var parentID: String?
    public var kind: ContextNodeKind
    public var title: String
    public var summary: String
    public var fullText: String
    public var source: String
    public var sessionID: String?
    public var charCount: Int
    public var recordCount: Int
    public var bodyReference: ContextBodyReference?
    public init(id: String, parentID: String? = nil, kind: ContextNodeKind, title: String, summary: String = "", fullText: String = "", source: String = "", sessionID: String? = nil, recordCount: Int = 0, bodyReference: ContextBodyReference? = nil, charCount: Int? = nil) {
        self.id = id; self.parentID = parentID; self.kind = kind; self.title = title; self.summary = summary; self.fullText = fullText; self.source = source; self.sessionID = sessionID
        self.charCount = charCount ?? fullText.count; self.recordCount = recordCount; self.bodyReference = bodyReference
    }
}
public struct ContextEdge: Identifiable, Sendable {
    public let id: String
    public let source: String
    public let target: String
    public let relation: String
    public init(source: String, target: String, relation: String) { id = source + "|" + relation + "|" + target; self.source = source; self.target = target; self.relation = relation }
}
public enum ContextCoverageStatus: String, Sendable { case complete, partial, missing, error, skipped }
public struct ContextCoverage: Identifiable, Sendable {
    public var id: String { source + "|" + (sessionID ?? "") }
    public var source: String
    public var sessionID: String?
    public var status: ContextCoverageStatus
    public var records: Int
    public var bytes: Int
    public var issues: [String]
    public init(source: String, sessionID: String? = nil, status: ContextCoverageStatus, records: Int = 0, bytes: Int = 0, issues: [String] = []) {
        self.source = source; self.sessionID = sessionID; self.status = status; self.records = records; self.bytes = bytes; self.issues = issues
    }
}
public struct ContextUsage: Identifiable, Sendable {
    public let id: String
    public let sessionID: String
    public let source: String
    public let label: String
    public let metrics: [String: Int64]
    public init(id: String, sessionID: String, source: String, label: String, metrics: [String: Int64]) {
        self.id = id; self.sessionID = sessionID; self.source = source; self.label = label; self.metrics = metrics
    }
}
public struct ContextTopology: Sendable {
    public let scope: LinkEndpoint
    public let title: String
    public var nodes: [ContextNode]
    public var edges: [ContextEdge]
    public var coverage: [ContextCoverage]
    public var usage: [ContextUsage]
    public var sessions: [Session]
    public var boundaries: [String]
    public let loadedAt: Date
    public init(scope: LinkEndpoint, title: String, nodes: [ContextNode] = [], edges: [ContextEdge] = [], coverage: [ContextCoverage] = [], usage: [ContextUsage] = [], sessions: [Session] = []) {
        self.scope = scope; self.title = title; self.nodes = nodes; self.edges = edges; self.coverage = coverage; self.usage = usage; self.sessions = sessions; loadedAt = Date()
        boundaries = ["저장된 기록이며 현재 모델에 실제 전달된 입력 전체를 증명하지 않습니다.", "관찰된 도구 호출과 스킬 참조는 현재 사용 가능한 도구·스킬 목록이 아닙니다.", "글자·바이트 수는 기록 크기입니다. 토큰 사용량은 기록된 실제 telemetry만 표시합니다."]
    }
}
