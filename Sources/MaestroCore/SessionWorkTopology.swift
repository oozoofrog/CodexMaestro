import Foundation

public enum WorkNodeKind: String, CaseIterable, Sendable {
    case session, prompt, instruction, toolCall, command, mcp, toolResult, subsession, message, compaction, usage, artifact, verification, waiting, other
    public var label: String {
        switch self {
        case .session: "세션"; case .prompt: "프롬프트"; case .instruction: "지침·컨텍스트"; case .toolCall: "도구 호출"
        case .command: "명령 실행"; case .mcp: "MCP 실행"; case .toolResult: "호출 결과"; case .subsession: "하위 세션"
        case .message: "공개 메시지"; case .compaction: "컨텍스트 압축"; case .usage: "토큰 계측"; case .artifact: "산출물 참조"
        case .verification: "검증 근거"; case .waiting: "입력 대기"; case .other: "기타 기록"
        }
    }
    public var symbol: String {
        switch self {
        case .session: "bubble.left.and.bubble.right"; case .prompt: "text.bubble"; case .instruction: "doc.text"; case .toolCall: "wrench.and.screwdriver"
        case .command: "terminal"; case .mcp: "puzzlepiece"; case .toolResult: "arrow.down.left"; case .subsession: "arrow.triangle.branch"
        case .message: "bubble.left"; case .compaction: "archivebox"; case .usage: "chart.bar"; case .artifact: "doc"
        case .verification: "checkmark.shield"; case .waiting: "pause.circle"; case .other: "ellipsis.circle"
        }
    }
    public var lane: Int {
        switch self {
        case .instruction, .compaction: 0
        case .session, .prompt: 1
        case .toolCall, .command, .mcp, .subsession, .waiting: 2
        default: 3
        }
    }
}

public enum WorkStatus: String, CaseIterable, Sendable {
    case unknown, queued, running, waiting, succeeded, failed, ended, cancelled
    public var label: String {
        switch self {
        case .unknown: "미확인"; case .queued: "실행 대기"; case .running: "실행 중"; case .waiting: "결과·입력 대기"
        case .succeeded: "성공 근거 있음"; case .failed: "실패"; case .ended: "종료·반환 수신"; case .cancelled: "중단"
        }
    }
    public var isActive: Bool { self == .queued || self == .running || self == .waiting }
}

public enum WorkRelationKind: String, CaseIterable, Sendable {
    case belongsToTurn, calls, resultOf, spawnedSession, sentToSession, reportedBy, referencesArtifact, supportsClaim, observedUsage, recordedNext, dependsOn, historicalAssociation, receivedInTurn
    public var label: String {
        switch self {
        case .belongsToTurn: "turn 소속"; case .calls: "호출"; case .resultOf: "호출 결과"; case .spawnedSession: "위임"
        case .sentToSession: "메시지 발신"; case .reportedBy: "공개 보고"; case .referencesArtifact: "산출물 참조"
        case .supportsClaim: "검증 근거"; case .observedUsage: "계측"; case .recordedNext: "기록 순서"
        case .dependsOn: "명시된 의존성"; case .historicalAssociation: "과거 부모·자식 관계"
        case .receivedInTurn: "결과 수신 turn"
        }
    }
}

public struct WorkStatusObservation: Sendable {
    public let timestamp: Date?
    public let status: WorkStatus
    public let recordOrdinal: Int?
    public let summary: String?
    public let bodyPreview: String?
    public let bodyReference: ContextBodyReference?
    public init(timestamp: Date? = nil, status: WorkStatus, recordOrdinal: Int? = nil, summary: String? = nil, bodyPreview: String? = nil, bodyReference: ContextBodyReference? = nil) {
        self.timestamp = timestamp; self.status = status; self.recordOrdinal = recordOrdinal
        self.summary = summary; self.bodyPreview = bodyPreview; self.bodyReference = bodyReference
    }
}

public struct WorkNode: Identifiable, Sendable {
    public let id: String
    public let sessionID: String
    public var turnID: String?
    public var kind: WorkNodeKind
    public var title: String
    public var summary: String
    public var bodyPreview: String
    public var status: WorkStatus
    public var timestamp: Date?
    public var callID: String?
    public var relatedSessionID: String?
    public var bodyReference: ContextBodyReference?
    public var source: String
    public var statusHistory: [WorkStatusObservation]
    /// A cutoff never exposes an outcome observed after that cutoff, or at an unknown time.
    public func status(at cutoff: Date) -> WorkStatus {
        observation(at: cutoff)?.status ?? .unknown
    }
    public func observation(at cutoff: Date) -> WorkStatusObservation? {
        var latest: Date?
        var result: WorkStatusObservation?
        for observation in statusHistory {
            guard let timestamp = observation.timestamp, timestamp <= cutoff else { continue }
            if latest == nil || timestamp >= latest! { latest = timestamp; result = observation }
        }
        return result
    }
    public init(id: String, sessionID: String, turnID: String? = nil, kind: WorkNodeKind, title: String, summary: String = "", bodyPreview: String = "", status: WorkStatus = .unknown, timestamp: Date? = nil, callID: String? = nil, relatedSessionID: String? = nil, bodyReference: ContextBodyReference? = nil, source: String = "", statusHistory: [WorkStatusObservation] = []) {
        self.id = id; self.sessionID = sessionID; self.turnID = turnID; self.kind = kind; self.title = title; self.summary = summary; self.bodyPreview = bodyPreview; self.status = status; self.timestamp = timestamp; self.callID = callID; self.relatedSessionID = relatedSessionID; self.bodyReference = bodyReference; self.source = source
        self.statusHistory = statusHistory.isEmpty ? [WorkStatusObservation(timestamp: timestamp, status: status, summary: summary, bodyPreview: bodyPreview, bodyReference: bodyReference)] : statusHistory
    }
}

public struct WorkRelation: Identifiable, Sendable {
    public let id: String
    public let source: String
    public let target: String
    public let kind: WorkRelationKind
    public let label: String
    public let evidence: String
    public let observedAt: Date?
    public init(id: String? = nil, source: String, target: String, kind: WorkRelationKind, label: String = "", evidence: String = "", observedAt: Date? = nil) {
        self.id = id ?? source + "|" + kind.rawValue + "|" + target; self.source = source; self.target = target; self.kind = kind; self.label = label.isEmpty ? kind.label : label; self.evidence = evidence
        self.observedAt = observedAt
    }
}

public struct WorkTurn: Identifiable, Sendable {
    public let id: String
    public let sessionID: String
    public var promptNodeID: String?
    public var status: WorkStatus
    public var startedAt: Date?
    public var endedAt: Date?
    public var model: String
    public var effort: String
    public init(id: String, sessionID: String, promptNodeID: String? = nil, status: WorkStatus = .unknown, startedAt: Date? = nil, endedAt: Date? = nil, model: String = "", effort: String = "") {
        self.id = id; self.sessionID = sessionID; self.promptNodeID = promptNodeID; self.status = status; self.startedAt = startedAt; self.endedAt = endedAt; self.model = model; self.effort = effort
    }
}

public struct WorkUsage: Identifiable, Sendable {
    public let id: String
    public let sessionID: String
    public let turnID: String?
    public let input: Int64?
    public let cachedInput: Int64?
    public let output: Int64?
    public let reasoningOutput: Int64?
    public let lastRequestInput: Int64?
    public let modelContextWindow: Int64?
    public let timestamp: Date?
    public let source: String
    /// Examples: session cumulative, last request, explicitly recorded turn, unknown.
    public let scope: String
    public let includesSubsessions: Bool?
    public var label: String { scope }
    public var total: Int64? {
        guard let input, let output else { return nil }
        let (value, overflow) = input.addingReportingOverflow(output)
        return overflow ? nil : value
    }
    public var lastRequestRatio: Double? {
        guard let lastRequestInput, let modelContextWindow, modelContextWindow > 0 else { return nil }
        return Double(lastRequestInput) / Double(modelContextWindow)
    }
    public init(id: String = UUID().uuidString, sessionID: String, turnID: String? = nil, input: Int64? = nil, cachedInput: Int64? = nil, output: Int64? = nil, reasoningOutput: Int64? = nil, lastRequestInput: Int64? = nil, modelContextWindow: Int64? = nil, timestamp: Date? = nil, source: String = "", scope: String = "범위 미확인", includesSubsessions: Bool? = nil) {
        self.id = id; self.sessionID = sessionID; self.turnID = turnID; self.input = input; self.cachedInput = cachedInput; self.output = output; self.reasoningOutput = reasoningOutput; self.lastRequestInput = lastRequestInput; self.modelContextWindow = modelContextWindow; self.timestamp = timestamp; self.source = source; self.scope = scope
        self.includesSubsessions = includesSubsessions
    }
}

public struct SessionWorkTopology: Sendable {
    public let sessionID: String
    public let title: String
    public var nodes: [WorkNode]
    public var edges: [WorkRelation]
    public var turns: [WorkTurn]
    public var usage: [WorkUsage]
    public var coverage: [ContextCoverage]
    public let loadedAt: Date
    public var currentTurnID: String?
    public var sourceIsStale: Bool { coverage.contains { $0.status == .error || $0.status == .missing } }
    public init(sessionID: String, title: String, nodes: [WorkNode] = [], edges: [WorkRelation] = [], turns: [WorkTurn] = [], usage: [WorkUsage] = [], coverage: [ContextCoverage] = [], loadedAt: Date = Date(), currentTurnID: String? = nil) {
        self.sessionID = sessionID; self.title = title; self.nodes = nodes; self.edges = edges; self.turns = turns; self.usage = usage; self.coverage = coverage; self.loadedAt = loadedAt; self.currentTurnID = currentTurnID
    }
}

public struct SessionWorkReadDiagnostics: Sendable {
    public let generation: Int
    public let parsedRecords: Int
    /// New/pending suffix bytes. Excludes bounded integrity probes of up to 8 KiB per poll.
    public let lastReadBytes: Int
    public let totalParsedRecords: Int
    public let completeOffset: UInt64
}
