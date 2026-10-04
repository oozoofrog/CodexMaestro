import Foundation
import Observation
import AppKit
import MaestroCore

struct ActivityEvent: Identifiable {
    let id = UUID()
    let date = Date()
    let text: String
    let isError: Bool
}
struct ConnectionActionTarget: Identifiable { let id: UUID }
struct OverlapProposal: Identifiable {
    let id = UUID()
    let source: LinkEndpoint
    let target: LinkEndpoint
}

@MainActor @Observable final class MaestroStore {
    var projects: [Project] = []
    var sessions: [Session] = []
    var selectedSessionID: String?
    var selectedNodeProjectID: String?
    var selectedProjectID: String?
    var scope = "recent"
    var search = ""
    var connected = false
    var refreshing = false
    var error: String?
    var notice: String?
    var lastRefresh: Date?
    var workspace = WorkspaceState()
    var transcript: [TranscriptMessage] = []
    var transcriptLoading = false
    var transcriptError: String?
    var sending: Set<String> = []
    var events: [ActivityEvent] = []
    var showLinks = true
    var showList = false
    var zoom: Double = 0.85
    var expandedProjects: Set<String> = []
    var linkingEndpoint: LinkEndpoint?
    var actionSheetTarget: ConnectionActionTarget?
    var overlapProposal: OverlapProposal?
    var contextScope: LinkEndpoint?
    var contextTopology: ContextTopology?
    var contextLoading = false
    var contextError: String?
    var optimizationProposal: ContextOptimizationProposal?
    var workInspection: SessionWorkStore?
    let demo: Bool
    let catalog: CodexCatalog
    private let bridge = DesktopBridge()
    private let persistence: WorkspacePersistence
    private var persistenceWritable = true
    private var liveStates: [String: LiveSession] = [:]
    @ObservationIgnored private(set) var liveStateObservedAt: [String: Date] = [:]
    private var started = false
    private var connecting = false
    private var transcriptGeneration = UUID()
    @ObservationIgnored private let transcriptReader: @Sendable (String) async throws -> [TranscriptMessage]
    @ObservationIgnored let contextReader: @Sendable (LinkEndpoint, [Project], [Session]) async throws -> ContextTopology
    @ObservationIgnored var contextTask: Task<Void, Never>?
    var contextGeneration = UUID()

    init(demo: Bool = false, persistence: WorkspacePersistence = WorkspacePersistence(), catalog: CodexCatalog = CodexCatalog(), transcriptReader: (@Sendable (String) async throws -> [TranscriptMessage])? = nil, contextReader: (@Sendable (LinkEndpoint, [Project], [Session]) async throws -> ContextTopology)? = nil) {
        self.transcriptReader = transcriptReader ?? { id in
            try await Task.detached(priority: .utility) { try catalog.transcript(threadID: id) }.value
        }
        self.catalog = catalog
        self.contextReader = contextReader ?? { endpoint, projects, sessions in
            if demo { return ContextDemoTopology.make(scope: endpoint, projects: projects, sessions: sessions) }
            let all = try await Task.detached(priority: .utility) { try catalog.read(includeArchived: true) }.value
            var members = Dictionary(uniqueKeysWithValues: all.sessions.map { ($0.id, $0) })
            for session in sessions { members[session.id] = session }
            let loader = ContextTopologyLoader(home: catalog.home)
            if endpoint.kind == .session {
                guard let session = members[endpoint.id] else { throw MaestroError.message("세션을 찾을 수 없습니다.") }
                return try await loader.load(session: session, catalog: members.values.sorted { $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt })
            }
            guard let project = projects.first(where: { $0.id == endpoint.id }) else { throw MaestroError.message("프로젝트를 찾을 수 없습니다.") }
            return try await loader.load(project: project, sessions: members.values.sorted { $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt })
        }
        self.persistence = persistence
        self.demo = demo
        if demo { loadDemo(); return }
        do { workspace = try persistence.load() }
        catch { self.error = "작업공간을 읽지 못했습니다: \(error.localizedDescription)"; persistenceWritable = false }
        bridge.onSnapshot = { [weak self] id, state in self?.updateLive(id, state) }
        bridge.onDisconnect = { [weak self] reason in
            guard let self else { return }
            self.connected = false; self.liveStates.removeAll()
            self.liveStateObservedAt.removeAll()
            for i in self.sessions.indices { self.sessions[i].isLive = false; self.sessions[i].status = .unknown }
            self.synchronizeSessionWork()
            self.record(reason, isError: true)
        }
        bridge.onActivity = { [weak self] _, message in self?.record(message, isError: true) }
    }
    var selectedNodeProject: Project? {
        guard let id = selectedNodeProjectID else { return nil }
        return projects.first { $0.id == id } ?? Project(id: id, name: id == "unassigned" ? "프로젝트 없는 세션" : "기타 프로젝트")
    }
    var selectedSession: Session? { sessions.first { $0.id == selectedSessionID } }
    var selectedEndpoint: LinkEndpoint? {
        if let id = selectedSessionID { return .session(id) }
        if let id = selectedNodeProjectID { return .project(id) }
        return nil
    }
    func endpointExists(_ endpoint: LinkEndpoint) -> Bool {
        switch endpoint.kind {
        case .project: return projects.contains { $0.id == endpoint.id }
        case .session: return sessions.contains { $0.id == endpoint.id }
        }
    }
    func endpointTitle(_ endpoint: LinkEndpoint) -> String {
        switch endpoint.kind {
        case .project: return projects.first { $0.id == endpoint.id }?.name ?? "찾을 수 없는 프로젝트 · \(endpoint.id)"
        case .session: return sessions.first { $0.id == endpoint.id }?.title ?? "찾을 수 없는 세션 · \(endpoint.id)"
        }
    }
    var runningCount: Int { sessions.filter { $0.status == .running }.count }
    var liveCount: Int { sessions.filter(\.isLive).count }
    var waitingCount: Int { sessions.filter { $0.status == .waiting }.count }
    var filteredSessions: [Session] {
        var result = sessions
        if let project = selectedProjectID { result = result.filter { ($0.projectID ?? "unassigned") == project } }
        else if scope == "live" { result = result.filter(\.isLive) }
        else if scope == "recent" && search.isEmpty {
            let recent = Set(sessions.prefix(40).map(\.id))
            result = result.filter { $0.isLive || recent.contains($0.id) }
        }
        if !search.isEmpty {
            result = result.filter { ($0.title + " " + $0.cwd + " " + $0.id + " " + $0.model).localizedCaseInsensitiveContains(search) }
        }
        return result
    }
    var visibleProjects: [Project] { orderedProjects(for: filteredSessions) }
    func orderedProjects(for filtered: [Session]) -> [Project] {
        var firstIndex: [String: Int] = [:]
        var runningProjects: Set<String> = []
        for (index, session) in filtered.enumerated() {
            let id = session.projectID ?? "unassigned"
            if firstIndex[id] == nil { firstIndex[id] = index }
            if session.status == .running { runningProjects.insert(id) }
        }
        var ids = Set(firstIndex.keys)
        if selectedProjectID == nil && search.isEmpty {
            let relationProjects = workspace.allNodeLinks.flatMap { [$0.source, $0.target] }
                .filter { $0.kind == .project }.map(\.id)
            ids.formUnion(relationProjects.filter { id in projects.contains { $0.id == id } })
            if scope == "all" { ids.formUnion(projects.map(\.id)) }
        }
        var values = projects.filter { ids.contains($0.id) || selectedProjectID == $0.id }
        if ids.contains("unassigned") { values.append(Project(id: "unassigned", name: "프로젝트 없는 세션")) }
        let known = Set(values.map(\.id))
        for id in ids.subtracting(known) { values.append(Project(id: id, name: "기타 프로젝트")) }
        return values.sorted { a, b in
            let aLive = runningProjects.contains(a.id), bLive = runningProjects.contains(b.id)
            if aLive != bLive { return aLive }
            let ai = firstIndex[a.id] ?? Int.max, bi = firstIndex[b.id] ?? Int.max
            if ai != bi { return ai < bi }
            return a.name == b.name ? a.id < b.id : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
    func displayedSessions(in project: Project) -> [Session] {
        displayedSessions(filteredSessions.filter { ($0.projectID ?? "unassigned") == project.id }, projectID: project.id)
    }
    func displayedSessions(_ items: [Session], projectID: String) -> [Session] {
        if expandedProjects.contains(projectID) || selectedProjectID != nil || !search.isEmpty { return items }
        let firstIDs = Set(items.prefix(3).map(\.id))
        return items.filter { firstIDs.contains($0.id) || $0.isLive || $0.id == selectedSessionID }
    }
    func count(in projectID: String) -> Int { sessions.filter { ($0.projectID ?? "unassigned") == projectID }.count }
    func projectName(for session: Session) -> String { projects.first { $0.id == session.projectID }?.name ?? "프로젝트 없음" }
    func position(for id: String, fallback: CGPoint) -> CGPoint {
        guard let point = workspace.positions[id] else { return fallback }
        return CGPoint(x: point.x, y: point.y)
    }
    func setPosition(_ id: String, point: CGPoint) {
        let previous = workspace
        workspace.positions[id] = NodePosition(x: max(160, point.x), y: max(id.hasPrefix("project:") ? 29 : 200, point.y))
        if !save() { workspace = previous }
    }
    func resetPositions() { workspace.positions = [:]; zoom = 0.85; save() }
    func draft(for id: String) -> String { workspace.drafts[id] ?? "" }
    func setDraft(_ value: String, for id: String) { workspace.drafts[id] = value }
    func saveDrafts() { save() }
    @discardableResult func save() -> Bool {
        if demo { return true }
        guard persistenceWritable else {
            error = "작업공간 읽기에 실패하여 저장이 차단되었습니다. 파일을 복구한 뒤 앱을 다시 실행하세요."
            return false
        }
        do { try persistence.save(workspace); return true }
        catch { self.error = "작업공간 저장 실패: \(error.localizedDescription)"; return false }
    }
    func run() async {
        guard !started else { return }; started = true
        if demo { return }
        await refresh()
        await reconnect()
        while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(5)) } catch { break }
            await refresh()
            if !connected { await reconnect(quiet: true) }
        }
        bridge.disconnect()
        connected = false
        synchronizeSessionWork()
    }
    func refresh() async {
        guard !demo, !refreshing else { return }; refreshing = true
        defer { refreshing = false }
        do {
            let reader = catalog
            let snapshot = try await Task.detached(priority: .utility) { try reader.read() }.value
            projects = snapshot.projects
            sessions = snapshot.sessions.map { value in
                var value = value
                if let live = liveStates[value.id] { merge(&value, live) }
                return value
            }
            synchronizeSessionWork()
            lastRefresh = Date()
            if connected { try bridge.follow(sessions.map(\.id)) }
            if let id = selectedSessionID { await loadTranscript(id) }
        } catch { self.error = error.localizedDescription }
    }
    func reconnect(quiet: Bool = false) async {
        guard !demo, !connecting else { return }
        connecting = true
        defer { connecting = false }
        connected = false; liveStates.removeAll()
        liveStateObservedAt.removeAll()
        for i in sessions.indices { sessions[i].isLive = false; sessions[i].status = .unknown }
        synchronizeSessionWork()
        do {
            try await bridge.connect(socketPath: catalog.home.appendingPathComponent("ipc/ipc.sock").path)
            connected = true
            synchronizeSessionWork()
            try bridge.follow(sessions.map(\.id))
            record("Codex 데스크톱에 연결되었습니다.")
        } catch {
            connected = false
            synchronizeSessionWork()
            if !quiet { self.error = error.localizedDescription; record(error.localizedDescription, isError: true) }
        }
    }
    private func updateLive(_ id: String, _ state: LiveSession) {
        liveStates[id] = state.owner.isEmpty ? nil : state
        liveStateObservedAt[id] = state.owner.isEmpty ? nil : Date()
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        var updated = sessions[index]
        merge(&updated, state)
        guard updated != sessions[index] else { synchronizeSessionWork(observedSessionID: id); return }
        let oldStatus = sessions[index].status
        sessions[index] = updated
        synchronizeSessionWork(observedSessionID: id)
        if oldStatus != state.status { record("\(sessions[index].title) · \(state.status.label)") }
    }
    private func merge(_ session: inout Session, _ state: LiveSession) {
        session.status = state.status; session.isLive = !state.owner.isEmpty
        if let model = state.model { session.model = model }
        if let effort = state.effort { session.effort = effort }
        if let title = state.title, !title.isEmpty { session.title = title }
        if let parent = state.parentID { session.parentID = parent }
    }
    func select(_ session: Session) {
        if let source = linkingEndpoint, source != .session(session.id) {
            completeConnectionDrag(from: source, to: .session(session.id)); return
        }
        if workInspection != nil {
            openSessionWork(for: session.id)
            return
        }
        selectedNodeProjectID = nil
        selectSessionID(session.id)
        Task { await loadTranscript(session.id) }
    }
    func selectProjectNode(_ project: Project) {
        cancelLink()
        if workInspection != nil || contextScope != nil { closeSessionWork() }
        selectSessionID(nil)
        selectedNodeProjectID = project.id
    }
    func selectEndpoint(_ endpoint: LinkEndpoint) {
        if let source = linkingEndpoint, source != endpoint {
            completeConnectionDrag(from: source, to: endpoint); return
        }
        switch endpoint.kind {
        case .session: if let session = sessions.first(where: { $0.id == endpoint.id }) { select(session) }
        case .project:
            if let project = projects.first(where: { $0.id == endpoint.id }) { selectProjectNode(project) }
            else if endpoint.id == "unassigned" { selectProjectNode(Project(id: "unassigned", name: "프로젝트 없는 세션")) }
        }
    }
    func selectSessionID(_ id: String?) {
        guard selectedSessionID != id else { return }
        transcriptGeneration = UUID()
        transcript = []; transcriptError = nil; transcriptLoading = false
        selectedSessionID = id
    }
    func loadTranscript(_ id: String) async {
        // A send completion for an old selection must not take ownership of the new inspector load.
        guard selectedSessionID == id else { return }
        guard !demo else { transcript = Self.demoMessages(for: id); return }
        let token = UUID(); transcriptGeneration = token; transcriptLoading = true; transcriptError = nil
        defer { if transcriptGeneration == token { transcriptLoading = false } }
        do {
            let result = try await transcriptReader(id)
            guard transcriptGeneration == token, selectedSessionID == id else { return }
            transcript = result
        } catch {
            guard transcriptGeneration == token, selectedSessionID == id else { return }
            transcript = []; transcriptError = error.localizedDescription
        }
    }
    func send(to session: Session) async {
        let prompt = draft(for: session.id)
        guard !sending.contains(session.id), !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        sending.insert(session.id); defer { sending.remove(session.id) }
        if demo {
            record("데모: ‘\(session.title)’ 전송 동작을 확인했습니다. 실제 세션에는 전송하지 않았습니다.")
            notice = "데모 전송 완료 · 실제 전송 없음"; return
        }
        save()
        do {
            try await bridge.sendPrompt(threadID: session.id, prompt: prompt)
            if draft(for: session.id) == prompt { workspace.drafts[session.id] = ""; save() }
            notice = "‘\(session.title)’에 프롬프트를 전달했습니다."
            record("프롬프트 전달 · \(session.title)")
            await loadTranscript(session.id)
        } catch { self.error = error.localizedDescription; record("전달 확인 실패 · \(session.title): \(error.localizedDescription)", isError: true) }
    }
    func beginLink(from endpoint: LinkEndpoint) { linkingEndpoint = endpoint }
    func cancelLink() { linkingEndpoint = nil }
    @discardableResult func saveNodeLink(_ link: NodeLink) -> Bool {
        guard endpointExists(link.source), endpointExists(link.target) else {
            error = "연결할 출발 또는 도착 노드를 현재 목록에서 찾을 수 없습니다."; return false
        }
        let previous = workspace
        do {
            if workspace.allNodeLinks.contains(where: { $0.id == link.id }) { try workspace.updateNodeLink(link) }
            else { try workspace.addNodeLink(link) }
            guard save() else { workspace = previous; return false }
            record("\(link.source.kind.label) → \(link.target.kind.label) 연결 저장 · \(link.kind.label)")
            return true
        } catch { workspace = previous; self.error = error.localizedDescription; return false }
    }
    @discardableResult func deleteNodeLink(_ link: NodeLink) -> Bool {
        let previous = workspace
        workspace.removeNodeLink(id: link.id)
        guard save() else { workspace = previous; return false }
        record("\(link.source.kind.label) → \(link.target.kind.label) 연결 삭제")
        return true
    }
    func connectionReferenceMessages(_ id: String) async throws -> [TranscriptMessage] {
        demo ? Self.demoMessages(for: id) : try await transcriptReader(id)
    }
    func openInCodex(_ session: Session) { if let url = URL(string: "codex://threads/\(session.id)") { NSWorkspace.shared.open(url) } }
    func revealProject(_ project: Project) { if let root = project.roots.first { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: root) } }
    func exportGraph() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "CodexMaestro-topology.json"; panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url {
            do {
                // Export graph structure, without private prompt drafts.
                var exported = workspace; exported.drafts = [:]
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(exported).write(to: url, options: .atomic)
            } catch { self.error = error.localizedDescription }
        }
    }
    func record(_ text: String, isError: Bool = false) {
        events.insert(ActivityEvent(text: text, isError: isError), at: 0)
        if events.count > 80 { events.removeLast(events.count - 80) }
    }
    private func loadDemo() {
        projects = [Project(id: "app", name: "CodexMaestro", roots: ["~/Projects/CodexMaestro"]), Project(id: "runner", name: "RunnersHeart", roots: ["~/Projects/RunnersHeart"]), Project(id: "studio", name: "Local AI Studio", roots: ["~/Projects/LocalAIStudio"])]
        let rows: [(String, String, String, SessionStatus)] = [("design", "워크스페이스 토폴로지 설계", "app", .running), ("bridge", "Codex 세션 브리지 구현", "app", .running), ("test", "IPC 연결과 복구 검증", "app", .waiting), ("watch", "러닝 코칭 피드백 개선", "runner", .running), ("sync", "Watch 동기화 상태 점검", "runner", .idle), ("models", "로컬 모델 실행 검증", "studio", .idle)]
        sessions = rows.enumerated().map { index, row in
            var value = Session(id: row.0, title: row.1, projectID: row.2, cwd: "~/Projects/\(row.2)", model: "세션 기본 모델", effort: "high", updatedAt: Date().addingTimeInterval(Double(-index * 100)), preview: "작업 내용과 결과를 연결된 세션에서 확인할 수 있습니다.", branch: "main")
            if let message = Self.demoMessages(for: row.0).last {
                value.lastMessage = SessionMessagePreview(role: message.role, text: message.text)
            }
            value.status = row.3; value.isLive = true; return value
        }
        workspace.links = [SessionLink(source: "design", target: "bridge", kind: .context, note: "토폴로지와 상태 표시 계약 공유"), SessionLink(source: "bridge", target: "test", kind: .review), SessionLink(source: "watch", target: "sync", kind: .dependency)]
        selectedSessionID = "bridge"; transcript = Self.demoMessages(for: "bridge"); connected = true; lastRefresh = Date()
        record("데모 모드 · 실제 Codex에 연결하지 않습니다.")
    }
    static func demoMessages(for id: String) -> [TranscriptMessage] {
        let responses = [
            "design": "프로젝트별 세션 카드를 구성했습니다. 연결 방향과 작업 상태를 같은 화면에서 확인할 수 있습니다.",
            "bridge": "세션 브리지를 연결했습니다. 상태 스냅샷과 변경 사항을 수신하고 연결이 끊기면 다시 구독합니다.",
            "test": "IPC 연결과 복구 검사가 통과했습니다. 추가 검증 전에 실행 대상과 전송할 초안을 확인해주세요.",
            "watch": "러닝 중 확인할 항목을 줄이고 짧은 햅틱 안내로 바꿨습니다. 상세 피드백은 달리기 후 iPhone에서 확인할 수 있습니다.",
            "sync": "Watch와 iPhone의 동기화 상태를 확인했습니다. 저장한 운동 기록은 다음 연결에서 전달됩니다.",
            "models": "로컬 모델 실행을 확인했습니다. 입력 파일과 생성 결과를 비교했고 다음 단계의 메모리 사용량도 점검했습니다."
        ]
        return [TranscriptMessage(id: "u-\(id)", role: "user", text: "세션 상태를 관찰하고 연결된 작업 간 컨텍스트를 전달할 수 있도록 구성해주세요."), TranscriptMessage(id: "a-\(id)", role: "assistant", text: responses[id] ?? "프로젝트별 세션을 구성했습니다. 실행 상태는 실시간으로 반영되며, 연결을 선택하면 전달할 내용을 검토할 수 있습니다.")]
    }
}
