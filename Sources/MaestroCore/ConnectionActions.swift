import Foundation

public enum ConnectionExecutionSide: String, Codable, CaseIterable, Sendable {
    case source, target
    public var label: String { self == .source ? "출발 쪽" : "도착 쪽" }
}

public enum ConnectionFunction: String, Codable, CaseIterable, Sendable {
    // `skill` remains decodable for workspace version 3 records written by the old picker.
    case reference, handoff, review, custom, skill
    public static let availableFunctions: [ConnectionFunction] = [.reference, .handoff, .review, .custom]
    public var label: String {
        switch self {
        case .reference: "참고"
        case .handoff: "전달"
        case .review: "검토"
        case .custom: "직접 요청"
        case .skill: "직접 요청"
        }
    }
    public var defaultExecutionSide: ConnectionExecutionSide {
        self == .handoff || self == .review ? .target : .source
    }
    public var instruction: String {
        switch self {
        case .reference: "참고 자료를 근거로 현재 작업을 진행하세요. 필요한 자료가 없으면 누락된 근거를 명시하세요."
        case .handoff: "참고 자료와 아래 요청을 바탕으로 다음 작업을 진행하세요."
        case .review: "참고 자료를 검토하고 결함, 영향, 필요한 검증을 근거와 함께 보고하세요."
        case .custom, .skill: "아래 요청을 수행하세요."
        }
    }
}

public struct ConnectionActionConfiguration: Codable, Hashable, Sendable {
    public var function: ConnectionFunction
    public var executionSide: ConnectionExecutionSide
    public var recipientSessionID: String?
    public var prompt: String
    public var skillName: String?
    public var skillPath: String?
    public init(function: ConnectionFunction = .reference, executionSide: ConnectionExecutionSide = .source,
                recipientSessionID: String? = nil, prompt: String = "", skillName: String? = nil, skillPath: String? = nil) {
        self.function = function; self.executionSide = executionSide; self.recipientSessionID = recipientSessionID
        self.prompt = prompt; self.skillName = skillName; self.skillPath = skillPath
    }
    public func executionEndpoint(for link: NodeLink) -> LinkEndpoint { executionSide == .source ? link.source : link.target }
    public func referenceEndpoint(for link: NodeLink) -> LinkEndpoint { executionSide == .source ? link.target : link.source }

    /// Use session-selected skills while preserving legacy task text and execution routing.
    public func sessionManagedSkills() -> Self {
        var value = self
        if value.function == .skill {
            value.function = .custom
            if value.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                value.prompt = "참고 자료를 바탕으로 작업을 진행하세요."
            }
        }
        value.skillName = nil
        value.skillPath = nil
        return value
    }
}
