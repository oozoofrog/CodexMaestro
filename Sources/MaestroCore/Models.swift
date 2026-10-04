import Foundation

public struct Project: Identifiable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var roots: [String]
    public init(id: String, name: String, roots: [String] = []) { self.id = id; self.name = name; self.roots = roots }
}
public enum SessionStatus: String, CaseIterable, Sendable {
    case running, waiting, idle, unknown, error
    public var label: String {
        switch self { case .running: "실행 중"; case .waiting: "입력 대기"; case .idle: "대기 중"; case .unknown: "상태 미확인"; case .error: "오류" }
    }
    public static func parse(_ value: [String: Any]?) -> Self {
        switch value?["type"] as? String {
        case "active": return (value?["activeFlags"] as? [String] ?? []).isEmpty ? .running : .waiting
        case "idle": return .idle
        case "systemError": return .error
        default: return .unknown
        }
    }
}
public struct Session: Identifiable, Hashable, Sendable {
    public let id: String
    public var title: String
    public var projectID: String?
    public var cwd: String
    public var model: String
    public var effort: String
    public var updatedAt: Date
    public var preview: String
    public var lastMessage: SessionMessagePreview?
    public var branch: String
    public var parentID: String?
    public var status: SessionStatus = .unknown
    public var isLive: Bool = false
    public var isArchived: Bool = false
    public init(id: String, title: String, projectID: String?, cwd: String, model: String = "", effort: String = "", updatedAt: Date = Date(), preview: String = "", branch: String = "", parentID: String? = nil, lastMessage: SessionMessagePreview? = nil) {
        self.id = id; self.title = title; self.projectID = projectID; self.cwd = cwd; self.model = model; self.effort = effort; self.updatedAt = updatedAt; self.preview = preview; self.branch = branch; self.parentID = parentID
        self.lastMessage = lastMessage
    }
}
public struct SessionMessagePreview: Hashable, Sendable {
    public static let characterLimit = 160
    public let role: String
    public let text: String
    public var author: String { role == "assistant" ? "Codex" : "사용자" }
    public var displayText: String { "\(author): \(text)" }
    public init?(role: String, text: String) {
        guard role == "user" || role == "assistant" else { return nil }
        var characters: [Character] = []
        var pendingSpace = false
        for character in text {
            if character.isWhitespace { pendingSpace = !characters.isEmpty; continue }
            if pendingSpace { characters.append(" "); pendingSpace = false }
            characters.append(character)
            if characters.count > Self.characterLimit {
                characters = Array(characters.prefix(Self.characterLimit - 1))
                while characters.last?.isWhitespace == true { characters.removeLast() }
                characters.append("…")
                break
            }
        }
        guard !characters.isEmpty else { return nil }
        self.role = role; self.text = String(characters)
    }
}
public struct Catalog: Sendable {
    public var projects: [Project]
    public var sessions: [Session]
    public init(projects: [Project], sessions: [Session]) { self.projects = projects; self.sessions = sessions }
}
public struct TranscriptMessage: Identifiable, Sendable {
    public let id: String
    public let role: String
    public let text: String
    public init(id: String, role: String, text: String) { self.id = id; self.role = role; self.text = text }
}
public enum LinkKind: String, Codable, CaseIterable, Sendable {
    case context, dependency, review
    public var label: String { switch self { case .context: "참고"; case .dependency: "선행"; case .review: "검토" } }
    public var symbol: String { switch self { case .context: "arrow.up.right"; case .dependency: "arrow.triangle.branch"; case .review: "checkmark.bubble" } }
}
public struct SessionLink: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var source: String
    public var target: String
    public var kind: LinkKind
    public var note: String
    public init(id: UUID = UUID(), source: String, target: String, kind: LinkKind, note: String = "") { self.id = id; self.source = source; self.target = target; self.kind = kind; self.note = note }
}
public struct ProjectLink: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var source: String
    public var target: String
    public var kind: LinkKind
    public var note: String
    public init(id: UUID = UUID(), source: String, target: String, kind: LinkKind, note: String = "") {
        self.id = id; self.source = source; self.target = target; self.kind = kind; self.note = note
    }
}
public enum LinkEndpointKind: String, Codable, CaseIterable, Sendable {
    case project, session
    public var label: String { self == .project ? "프로젝트" : "세션" }
    public var symbol: String { self == .project ? "folder" : "terminal" }
}
public struct LinkEndpoint: Codable, Hashable, Sendable {
    public var kind: LinkEndpointKind
    public var id: String
    public init(kind: LinkEndpointKind, id: String) { self.kind = kind; self.id = id }
    public static func project(_ id: String) -> Self { Self(kind: .project, id: id) }
    public static func session(_ id: String) -> Self { Self(kind: .session, id: id) }
}
public struct NodeLink: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var source: LinkEndpoint
    public var target: LinkEndpoint
    public var kind: LinkKind
    public var note: String
    public init(id: UUID = UUID(), source: LinkEndpoint, target: LinkEndpoint, kind: LinkKind, note: String = "") {
        self.id = id; self.source = source; self.target = target; self.kind = kind; self.note = note
    }
    public init(_ link: SessionLink) {
        self.init(id: link.id, source: .session(link.source), target: .session(link.target), kind: link.kind, note: link.note)
    }
    public init(_ link: ProjectLink) {
        self.init(id: link.id, source: .project(link.source), target: .project(link.target), kind: link.kind, note: link.note)
    }
}
public struct NodePosition: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}
public struct WorkspaceState: Codable, Sendable {
    public var version = 1
    public var links: [SessionLink] = []
    public var projectLinks: [ProjectLink] = []
    // Additive storage keeps the original session/project arrays and their identifiers intact.
    public var nodeLinks: [NodeLink] = []
    public var connectionActions: [String: ConnectionActionConfiguration] = [:]
    public var positions: [String: NodePosition] = [:]
    public var drafts: [String: String] = [:]
    public init() {}
    private enum CodingKeys: String, CodingKey { case version, links, projectLinks, nodeLinks, connectionActions, positions, drafts }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        links = try values.decode([SessionLink].self, forKey: .links)
        projectLinks = try values.decodeIfPresent([ProjectLink].self, forKey: .projectLinks) ?? []
        nodeLinks = try values.decodeIfPresent([NodeLink].self, forKey: .nodeLinks) ?? []
        connectionActions = try values.decodeIfPresent([String: ConnectionActionConfiguration].self, forKey: .connectionActions) ?? [:]
        positions = try values.decode([String: NodePosition].self, forKey: .positions)
        drafts = try values.decode([String: String].self, forKey: .drafts)
    }
    public var allNodeLinks: [NodeLink] { links.map(NodeLink.init) + projectLinks.map(NodeLink.init) + nodeLinks }
    public mutating func addNodeLink(_ link: NodeLink) throws {
        guard !allNodeLinks.contains(where: { $0.id == link.id }) else { throw MaestroError.message("동일한 연결 식별자가 이미 있습니다.") }
        guard !link.source.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !link.target.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MaestroError.message("출발과 도착 노드를 선택하세요.") }
        guard link.source != link.target else { throw MaestroError.message("같은 노드에는 연결할 수 없습니다.") }
        guard !allNodeLinks.contains(where: { $0.source == link.source && $0.target == link.target && $0.kind == link.kind }) else { throw MaestroError.message("동일한 연결이 이미 있습니다.") }
        switch (link.source.kind, link.target.kind) {
        case (.session, .session): try addLink(SessionLink(id: link.id, source: link.source.id, target: link.target.id, kind: link.kind, note: link.note))
        case (.project, .project): try addProjectLink(ProjectLink(id: link.id, source: link.source.id, target: link.target.id, kind: link.kind, note: link.note))
        default: nodeLinks.append(link); version = max(2, version)
        }
    }
    public mutating func updateNodeLink(_ link: NodeLink) throws {
        guard allNodeLinks.contains(where: { $0.id == link.id }) else { throw MaestroError.message("변경할 연결이 없습니다.") }
        let sessionIndex = links.firstIndex { $0.id == link.id }
        let projectIndex = projectLinks.firstIndex { $0.id == link.id }
        let mixedIndex = nodeLinks.firstIndex { $0.id == link.id }
        var candidate = self
        candidate.removeNodeLink(id: link.id)
        candidate.connectionActions = connectionActions
        try candidate.addNodeLink(link)
        if let index = sessionIndex, let appended = candidate.links.firstIndex(where: { $0.id == link.id }) {
            let value = candidate.links.remove(at: appended); candidate.links.insert(value, at: index)
        }
        if let index = projectIndex, let appended = candidate.projectLinks.firstIndex(where: { $0.id == link.id }) {
            let value = candidate.projectLinks.remove(at: appended); candidate.projectLinks.insert(value, at: index)
        }
        if let index = mixedIndex, let appended = candidate.nodeLinks.firstIndex(where: { $0.id == link.id }) {
            let value = candidate.nodeLinks.remove(at: appended); candidate.nodeLinks.insert(value, at: index)
        }
        // A moved endpoint may no longer contain the chosen recipient. Require selection again.
        if let action = candidate.connectionActions[link.id.uuidString],
           let old = allNodeLinks.first(where: { $0.id == link.id }),
           action.executionEndpoint(for: old) != action.executionEndpoint(for: link) {
            var revised = action; revised.recipientSessionID = nil
            candidate.connectionActions[link.id.uuidString] = revised
        }
        self = candidate
    }
    public mutating func removeNodeLink(id: UUID) {
        links.removeAll { $0.id == id }; projectLinks.removeAll { $0.id == id }; nodeLinks.removeAll { $0.id == id }
        connectionActions.removeValue(forKey: id.uuidString)
    }
    public mutating func addLink(_ link: SessionLink) throws {
        guard !allNodeLinks.contains(where: { $0.id == link.id }) else { throw MaestroError.message("동일한 연결 식별자가 이미 있습니다.") }
        guard !link.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !link.target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MaestroError.message("연결할 세션을 선택하세요.") }
        guard link.source != link.target else { throw MaestroError.message("같은 세션에는 연결할 수 없습니다.") }
        guard !links.contains(where: { $0.source == link.source && $0.target == link.target && $0.kind == link.kind }) else { throw MaestroError.message("동일한 연결이 이미 있습니다.") }
        links.append(link)
    }
    public mutating func updateLink(_ link: SessionLink) throws {
        guard links.contains(where: { $0.id == link.id }) else { throw MaestroError.message("변경할 세션 연결이 없습니다.") }
        try updateNodeLink(NodeLink(link))
    }
    public mutating func addProjectLink(_ link: ProjectLink) throws {
        guard !allNodeLinks.contains(where: { $0.id == link.id }) else { throw MaestroError.message("동일한 프로젝트 연결 식별자가 이미 있습니다.") }
        guard !link.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !link.target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MaestroError.message("연결할 프로젝트를 선택하세요.") }
        guard link.source != link.target else { throw MaestroError.message("같은 프로젝트에는 연결할 수 없습니다.") }
        guard !projectLinks.contains(where: { $0.source == link.source && $0.target == link.target && $0.kind == link.kind }) else { throw MaestroError.message("동일한 프로젝트 연결이 이미 있습니다.") }
        projectLinks.append(link)
    }
    public mutating func updateProjectLink(_ link: ProjectLink) throws {
        guard projectLinks.contains(where: { $0.id == link.id }) else { throw MaestroError.message("변경할 프로젝트 연결이 없습니다.") }
        try updateNodeLink(NodeLink(link))
    }
}
public enum MaestroError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case let .message(value) = self { return value }; return nil }
}
public struct WorkspacePersistence: Sendable {
    public let url: URL
    public init(url: URL? = nil) {
        self.url = url ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CodexMaestro/workspace.json")
    }
    public func load() throws -> WorkspaceState {
        guard FileManager.default.fileExists(atPath: url.path) else { return WorkspaceState() }
        let state = try JSONDecoder().decode(WorkspaceState.self, from: Data(contentsOf: url))
        guard (1...3).contains(state.version) else { throw MaestroError.message("지원하지 않는 Maestro 작업공간 버전입니다.") }
        return state
    }
    public func save(_ state: WorkspaceState) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var encoded = state
        if !encoded.connectionActions.isEmpty { encoded.version = 3 }
        else if !encoded.nodeLinks.isEmpty { encoded.version = max(2, encoded.version) }
        let data = try JSONEncoder().encode(encoded)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
