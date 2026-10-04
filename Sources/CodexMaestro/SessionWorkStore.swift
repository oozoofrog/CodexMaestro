import Foundation
import Observation
import MaestroCore

/// Read-only inspection state. Workspace drafts, connections, and delivery are owned by MaestroStore.
@MainActor @Observable final class SessionWorkStore {
    typealias Reader = @Sendable (Session, [Session]) async throws -> SessionWorkTopology
    typealias BodyReader = @Sendable (WorkNode) async throws -> String
    typealias CatalogReader = @Sendable () async throws -> [Session]

    private(set) var session: Session
    private(set) var graph: SessionWorkTopology?
    private(set) var breadcrumbs: [Session]
    private(set) var measuredGraphs: [String: SessionWorkTopology] = [:]
    private(set) var selectedTurnID: String?
    private(set) var selectedNodeID: String?
    private(set) var selectedObservationIndex: Int?
    private(set) var historyCutoff: Date?
    private(set) var loading = false
    private(set) var error: String?
    private(set) var selectedBody: String?
    private(set) var bodyLoading = false
    private(set) var bodyError: String?
    private(set) var connected: Bool
    private(set) var lastLiveObservation: Date?
    private(set) var closed = false
    private(set) var childMetricsLoading = false
    private(set) var childMetricsErrors: [String: String] = [:]
    private(set) var childMetricsCheckedAt: Date?
    let isDemo: Bool

    @ObservationIgnored private let reader: Reader
    @ObservationIgnored private let bodyReader: BodyReader
    @ObservationIgnored private let catalogReader: CatalogReader
    @ObservationIgnored private let pollInterval: Duration?
    @ObservationIgnored private(set) var loadTask: Task<Void, Never>?
    @ObservationIgnored private(set) var pollTask: Task<Void, Never>?
    @ObservationIgnored private(set) var bodyTask: Task<Void, Never>?
    @ObservationIgnored private(set) var catalogTask: Task<[Session], Error>?
    @ObservationIgnored private(set) var metricsTask: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var loadGeneration = UUID()
    @ObservationIgnored private var bodyGeneration = UUID()
    @ObservationIgnored private var pollGeneration = UUID()
    @ObservationIgnored private var catalogGeneration = UUID()
    @ObservationIgnored private var metricsGeneration = UUID()
    private var sourceReadFailed = false
    private var suspended = true
    private(set) var followsCurrentTurn = true
    private var members: [String: Session]
    private var navigationSelections: [String: Selection] = [:]
    private var liveObservations: [String: Date] = [:]
    private var catalogIncludesArchived = false

    private struct Selection {
        let turnID: String?
        let nodeID: String?
        let observationIndex: Int?
        let cutoff: Date?
        let followsCurrentTurn: Bool
    }

    init(session: Session, catalog: [Session] = [], home: URL = CodexCatalog().home,
         connected: Bool = false, demo: Bool = false, pollInterval: Duration? = .milliseconds(1500),
         reader: Reader? = nil, bodyReader: BodyReader? = nil, catalogReader: CatalogReader? = nil) {
        self.session = session; breadcrumbs = [session]; self.connected = connected; isDemo = demo
        self.pollInterval = pollInterval
        var initialMembers = Dictionary(catalog.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        initialMembers[session.id] = session
        members = initialMembers
        // The actor keeps incremental file cursors for the entire inspection lifetime.
        let loader = SessionWorkTopologyLoader(home: home)
        self.reader = reader ?? { session, catalog in
            if demo { return SessionWorkTopology.demo(session: session) }
            return try await loader.load(session: session, catalog: catalog)
        }
        self.bodyReader = bodyReader ?? { node in try await loader.loadBody(node: node) }
        self.catalogReader = catalogReader ?? {
            let catalog = CodexCatalog(home: home)
            let task = Task.detached(priority: .utility) { try catalog.read(includeArchived: true, includeMessagePreviews: false).sessions }
            return try await withTaskCancellationHandler {
                let sessions = try await task.value
                try Task.checkCancellation()
                return sessions
            } onCancel: { task.cancel() }
        }
    }

    deinit { loadTask?.cancel(); pollTask?.cancel(); bodyTask?.cancel(); catalogTask?.cancel(); metricsTask?.cancel() }

    var atRoot: Bool { breadcrumbs.count < 2 }
    var knownSessions: [Session] { members.values.sorted { $0.id < $1.id } }
    var selectedTurn: WorkTurn? { graph?.turns.first { $0.id == selectedTurnID } }
    var selectedDetailNode: WorkNode? {
        guard let selectedNodeID else { return nil }
        if let selectedObservationIndex,
           let node = graph?.nodes.first(where: { $0.id == selectedNodeID }),
           node.statusHistory.indices.contains(selectedObservationIndex) {
            return observationNode(node, observation: node.statusHistory[selectedObservationIndex])
        }
        return visibleNodes.first { $0.id == selectedNodeID }
    }
    var liveStatus: SessionStatus? { connected && session.isLive ? session.status : nil }
    var stale: Bool { sourceReadFailed || !connected || !session.isLive || session.status == .unknown }
    var canAnimate: Bool {
        !closed && !suspended && !stale && historyCutoff == nil && session.status == .running &&
        selectedTurnID == graph?.currentTurnID && selectedTurn?.status == .running
    }

    var visibleNodes: [WorkNode] {
        guard let graph else { return [] }
        let receivingTurnNodeID = selectedTurnID.map { "turn:\(session.id):\($0)" }
        let receipts = Set(graph.edges.filter { edge in
            guard edge.kind == .receivedInTurn, edge.target == receivingTurnNodeID else { return false }
            guard let historyCutoff else { return true }
            return edge.observedAt.map { $0 <= historyCutoff } ?? false
        }.map(\.source))
        let priorCalls = Set(graph.edges.filter { $0.kind == .resultOf && receipts.contains($0.source) && relationVisible($0) }.map(\.target))
        let exactReferences = receipts.union(priorCalls)
        let filtered = graph.nodes.filter { node in
            guard node.turnID == nil || node.turnID == selectedTurnID || exactReferences.contains(node.id) else { return false }
            return historyCutoff.map { cutoff in node.timestamp.map { $0 <= cutoff } ?? true } ?? true
        }
        guard let cutoff = historyCutoff else { return filtered }
        return filtered.map { original in
            var node = original
            let observation = original.observation(at: cutoff)
            node.status = observation?.status ?? .unknown
            node.summary = observation?.summary ?? "선택한 시각까지 확인한 상태: \(node.status.label)"
            node.bodyPreview = observation?.bodyPreview ?? "선택한 시각의 원문은 미확인입니다."
            node.bodyReference = observation?.bodyReference
            if let ref = node.bodyReference { node.source = "\(ref.path) · byte \(ref.offset)" }
            else { node.source = "선택한 시각의 상태 관찰 · 원문 위치 미확인" }
            // IPC is a current observation. It is never a historical execution state.
            if node.id == "session:\(session.id)" {
                node.status = .unknown; node.summary = "IPC 현재 상태는 기록 재생에 적용하지 않습니다."
            }
            return node
        }
    }

    var visibleEdges: [WorkRelation] {
        let ids = Set(visibleNodes.map(\.id))
        return graph?.edges.filter { ids.contains($0.source) && ids.contains($0.target) && relationVisible($0) } ?? []
    }

    private func relationVisible(_ edge: WorkRelation) -> Bool {
        guard let historyCutoff else { return true }
        guard let observedAt = edge.observedAt else { return edge.kind != .receivedInTurn }
        return observedAt <= historyCutoff
    }

    private func observationNode(_ original: WorkNode, observation: WorkStatusObservation) -> WorkNode {
        var node = original
        node.status = observation.status
        node.summary = observation.summary ?? "선택한 원시 관찰 상태: \(observation.status.label)"
        node.bodyPreview = observation.bodyPreview ?? "선택한 관찰의 원문은 미확인입니다."
        node.bodyReference = observation.bodyReference
        node.timestamp = observation.timestamp
        node.source = observation.bodyReference.map { "\($0.path) · byte \($0.offset)" } ?? "선택한 관찰 · 원문 위치 미확인"
        return node
    }

    func start() { startPolling(refreshImmediately: true) }

    private func startPolling(refreshImmediately: Bool) {
        guard !closed else { return }
        suspended = false
        guard pollTask == nil else { return }
        let interval = pollInterval, token = UUID()
        pollGeneration = token
        pollTask = Task { [weak self] in
            if refreshImmediately { await self?.refresh() }
            guard let interval else {
                if self?.pollGeneration == token { self?.pollTask = nil }
                return
            }
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                guard !Task.isCancelled, self?.pollGeneration == token else { return }
                await self?.refresh()
            }
        }
    }

    func stopPolling() {
        suspended = true
        pollGeneration = UUID()
        pollTask?.cancel(); pollTask = nil
        loadTask?.cancel(); loadTask = nil; loadGeneration = UUID(); loading = false
        catalogTask?.cancel(); catalogTask = nil; catalogGeneration = UUID()
        metricsTask?.cancel(); metricsTask = nil; metricsGeneration = UUID(); childMetricsLoading = false
        cancelBody()
    }

    func refresh() async {
        guard !closed else { return }
        if let loadTask, loading { await loadTask.value; return }
        let scope = generation, token = UUID(), session = session, catalog = knownSessions, reader = reader
        loadGeneration = token; loading = true
        let task = Task { [weak self] in
            do {
                let result = try await reader(session, catalog)
                try Task.checkCancellation()
                guard let self, !self.closed, self.generation == scope, self.loadGeneration == token,
                      self.session.id == session.id else { return }
                guard result.sessionID == session.id else { throw MaestroError.message("읽은 기록의 세션 범위가 다릅니다.") }
                let failures = result.coverage.filter { $0.status == .error || $0.status == .missing }
                var observed = result
                // Some adapters return an unavailable-source snapshot instead of throwing.
                // Keep the last observed work and telemetry if that snapshot has no execution records.
                if !failures.isEmpty, !result.nodes.contains(where: { $0.kind != .session && $0.kind != .subsession }),
                   let last = self.graph {
                    observed = SessionWorkTopology(sessionID: last.sessionID, title: last.title, nodes: last.nodes,
                                                   edges: last.edges, turns: last.turns, usage: last.usage,
                                                   coverage: result.coverage, loadedAt: last.loadedAt, currentTurnID: last.currentTurnID)
                }
                self.accept(observed)
                self.loading = false; self.sourceReadFailed = !failures.isEmpty
                let messages = failures.flatMap(\.issues).joined(separator: "\n")
                self.error = failures.isEmpty ? nil : messages.isEmpty ? "기록 자료를 갱신하지 못했습니다. 마지막 관찰을 표시합니다." : messages
            } catch is CancellationError {
                // The scope switch or close action owns the replacement state.
            } catch {
                guard let self, !self.closed, self.generation == scope, self.loadGeneration == token,
                      self.session.id == session.id else { return }
                self.error = error.localizedDescription; self.loading = false; self.sourceReadFailed = true
            }
        }
        loadTask = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        if loadGeneration == token { loadTask = nil; loading = false }
    }

    private func accept(_ result: SessionWorkTopology) {
        let previous = selectedDetailNode
        graph = result; measuredGraphs[session.id] = result
        applyCurrentLiveStatus()
        if followsCurrentTurn { selectedTurnID = result.currentTurnID }
        else if let selectedTurnID, !result.turns.contains(where: { $0.id == selectedTurnID }) {
            self.selectedTurnID = result.currentTurnID
            followsCurrentTurn = true; historyCutoff = nil
        }
        guard let id = selectedNodeID else { return }
        if selectedObservationIndex != nil, let previous,
           let node = result.nodes.first(where: { $0.id == id }) {
            // A source generation replacement cannot silently retarget an observation selection.
            guard let index = node.statusHistory.firstIndex(where: {
                let candidate = observationNode(node, observation: $0)
                return bodyKey(candidate) == bodyKey(previous) && candidate.timestamp == previous.timestamp && candidate.status == previous.status
            }) else { selectNode(nil); return }
            selectedObservationIndex = index
        }
        guard let selected = selectedDetailNode else { selectNode(nil); return }
        if selectedBody == nil || bodyTask == nil || (previous.map({ bodyKey($0) != bodyKey(selected) }) ?? true) { loadSelectedBody(selected) }
    }

    func synchronize(catalog: [Session], connected: Bool, observedAt: Date? = nil, observedSessionID: String? = nil) {
        guard !closed else { return }
        self.connected = connected
        for member in catalog { members[member.id] = member }
        if let current = catalog.first(where: { $0.id == session.id }) { session = current }
        else { session.isLive = false; session.status = .unknown }
        members[session.id] = session
        if let observedSessionID, let observedAt {
            liveObservations[observedSessionID] = observedAt
            if observedSessionID == session.id { lastLiveObservation = observedAt }
        }
        if let index = breadcrumbs.firstIndex(where: { $0.id == session.id }) { breadcrumbs[index] = session }
        applyCurrentLiveStatus()
    }

    private func applyCurrentLiveStatus() {
        // This changes only the root session node, never inferred tool execution states.
        if let index = graph?.nodes.firstIndex(where: { $0.id == "session:\(session.id)" }) {
            graph?.nodes[index].status = switch liveStatus {
            case .running: .running; case .waiting: .waiting; case .error: .failed
            case .idle: .ended; case .unknown, .none: .unknown
            }
        }
    }

    func selectTurn(_ id: String?) {
        guard !closed, id == nil || graph?.turns.contains(where: { $0.id == id }) == true else { return }
        followsCurrentTurn = id == nil
        selectedObservationIndex = nil
        selectedTurnID = id ?? graph?.currentTurnID
        historyCutoff = nil
        updateSelectedProjection()
    }

    func selectNode(_ id: String?) {
        guard !closed else { return }
        let alreadyVisible = visibleNodes.contains { $0.id == id }
        selectedObservationIndex = nil
        guard let id, let node = graph?.nodes.first(where: { $0.id == id }) else {
            selectedNodeID = nil; cancelBody(); selectedBody = nil; bodyError = nil; return
        }
        selectedNodeID = id
        if let turnID = node.turnID {
            if !alreadyVisible { selectedTurnID = turnID }
            followsCurrentTurn = false
        }
        loadSelectedBody(visibleNodes.first { $0.id == id } ?? node)
    }

    func selectObservation(nodeID: String, index: Int) {
        guard !closed, let node = graph?.nodes.first(where: { $0.id == nodeID }),
              node.statusHistory.indices.contains(index) else { return }
        let alreadyVisible = visibleNodes.contains { $0.id == nodeID }
        selectedNodeID = nodeID; selectedObservationIndex = index
        if let turnID = node.turnID {
            if !alreadyVisible { selectedTurnID = turnID }
            followsCurrentTurn = false
        }
        if let detail = selectedDetailNode { loadSelectedBody(detail) }
    }

    private func cancelBody() {
        bodyTask?.cancel(); bodyTask = nil; bodyGeneration = UUID(); bodyLoading = false
    }

    private func loadSelectedBody(_ node: WorkNode) {
        cancelBody(); selectedBody = node.bodyPreview; bodyError = nil; bodyLoading = true
        let token = UUID(), scope = generation, reader = bodyReader, key = bodyKey(node)
        bodyGeneration = token
        bodyTask = Task { [weak self] in
            do {
                let text = try await reader(node)
                try Task.checkCancellation()
                guard let self, !self.closed, self.generation == scope, self.bodyGeneration == token,
                      self.selectedNodeID == node.id,
                      let current = self.selectedDetailNode, self.bodyKey(current) == key else { return }
                self.selectedBody = text; self.bodyLoading = false
            } catch is CancellationError {
            } catch {
                guard let self, !self.closed, self.generation == scope, self.bodyGeneration == token,
                      self.selectedNodeID == node.id else { return }
                self.bodyError = error.localizedDescription; self.bodyLoading = false
            }
        }
    }

    private func bodyKey(_ node: WorkNode) -> String {
        guard let ref = node.bodyReference else { return node.bodyPreview }
        return "\(ref.path)|\(ref.offset)|\(ref.length)|\(ref.fingerprint)|\(ref.itemID ?? "")|\(ref.sessionID ?? "")"
    }

    func seek(to date: Date?) {
        guard !closed else { return }
        historyCutoff = date
        selectedObservationIndex = nil
        if date != nil { followsCurrentTurn = false }
        updateSelectedProjection()
    }

    private func updateSelectedProjection() {
        guard selectedNodeID != nil else { return }
        guard let node = selectedDetailNode else { selectNode(nil); return }
        loadSelectedBody(node)
    }

    func returnToLive() { selectTurn(nil) }

    func openSession(_ session: Session) async {
        guard !closed else { return }
        navigationSelections.removeAll(); breadcrumbs = [session]
        navigate(to: session)
        await refresh(); startPolling(refreshImmediately: false)
    }

    func openChild(_ id: String) async {
        guard !closed, id != session.id else { return }
        let scope = generation, parentID = session.id
        guard graph?.nodes.contains(where: { $0.relatedSessionID == id }) == true || members[id]?.parentID == parentID else { return }
        if members[id] == nil {
            let token = UUID(), reader = catalogReader
            catalogTask?.cancel()
            let task = Task { try await reader() }
            catalogTask = task; catalogGeneration = token
            do {
                let catalog = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
                try Task.checkCancellation()
                guard !closed, generation == scope, session.id == parentID, catalogGeneration == token else { return }
                catalogTask = nil
                for child in catalog where members[child.id] == nil { members[child.id] = child }
                catalogIncludesArchived = true
            } catch {
                guard !closed, generation == scope, session.id == parentID, catalogGeneration == token else { return }
                catalogTask = nil
                if !(error is CancellationError) { self.error = error.localizedDescription }
                return
            }
        }
        guard let child = members[id] else { error = "하위 세션의 저장된 기록을 찾을 수 없습니다: \(id)"; return }
        guard !breadcrumbs.contains(where: { $0.id == id }) else { return }
        saveSelection(); breadcrumbs.append(child); navigate(to: child)
        await refresh(); startPolling(refreshImmediately: false)
    }

    func back() async {
        guard !closed, breadcrumbs.count > 1 else { return }
        await back(to: breadcrumbs[breadcrumbs.count - 2].id)
    }

    func back(to ancestorID: String) async {
        guard !closed, let index = breadcrumbs.firstIndex(where: { $0.id == ancestorID }), index < breadcrumbs.count - 1 else { return }
        saveSelection(); breadcrumbs = Array(breadcrumbs.prefix(index + 1))
        guard let parent = breadcrumbs.last else { return }
        navigate(to: members[parent.id] ?? parent)
        await refresh(); startPolling(refreshImmediately: false)
    }

    /// Loads direct-child measurement snapshots without changing the visible inspection scope.
    func refreshChildMetrics() async {
        guard !closed else { return }
        if let metricsTask, childMetricsLoading { await metricsTask.value; return }
        let scope = generation, token = UUID(), parentID = session.id, reader = reader, catalogReader = catalogReader
        let snapshot = members, needsCatalog = !catalogIncludesArchived
        let referencedIDs = Set(graph?.nodes.filter { $0.kind == .subsession }.compactMap(\.relatedSessionID) ?? [])
        metricsGeneration = token; childMetricsLoading = true; childMetricsErrors = [:]
        let task = Task { [weak self] in
            var catalog = snapshot
            if needsCatalog || referencedIDs.contains(where: { catalog[$0] == nil }) {
                do {
                    let archived = try await catalogReader()
                    try Task.checkCancellation()
                    guard let self, !self.closed, self.generation == scope, self.metricsGeneration == token,
                          self.session.id == parentID else { return }
                    for member in archived where catalog[member.id] == nil { catalog[member.id] = member }
                    for member in archived where self.members[member.id] == nil { self.members[member.id] = member }
                    self.catalogIncludesArchived = true
                } catch is CancellationError { return }
                catch {
                    guard let self, !self.closed, self.generation == scope, self.metricsGeneration == token,
                          self.session.id == parentID else { return }
                    self.childMetricsErrors["catalog"] = error.localizedDescription
                }
            }
            let childIDs = referencedIDs.union(catalog.values.filter { $0.parentID == parentID }.map(\.id)).subtracting([parentID]).sorted()
            let members = catalog.values.sorted { $0.id < $1.id }
            // Direct children are read once, sequentially. Grandchildren do not expand this job.
            for id in childIDs {
                guard !Task.isCancelled else { return }
                guard let child = catalog[id] else {
                    if let self, self.generation == scope, self.metricsGeneration == token {
                        self.childMetricsErrors[id] = "하위 세션의 카탈로그 항목을 찾을 수 없습니다."
                    }
                    continue
                }
                do {
                    let result = try await reader(child, members)
                    try Task.checkCancellation()
                    guard let self, !self.closed, self.generation == scope, self.metricsGeneration == token,
                          self.session.id == parentID else { return }
                    guard result.sessionID == id else { throw MaestroError.message("하위 계측의 세션 범위가 다릅니다.") }
                    if result.sourceIsStale, !result.nodes.contains(where: { $0.kind != .session && $0.kind != .subsession }),
                       let last = self.measuredGraphs[id] {
                        self.measuredGraphs[id] = SessionWorkTopology(sessionID: last.sessionID, title: last.title, nodes: last.nodes,
                                                                      edges: last.edges, turns: last.turns, usage: last.usage,
                                                                      coverage: result.coverage, loadedAt: last.loadedAt, currentTurnID: last.currentTurnID)
                    } else { self.measuredGraphs[id] = result }
                    if result.sourceIsStale {
                        self.childMetricsErrors[id] = result.coverage.filter { $0.status == .missing || $0.status == .error }.flatMap(\.issues).joined(separator: "\n")
                    }
                } catch is CancellationError { return }
                catch {
                    guard let self, !self.closed, self.generation == scope, self.metricsGeneration == token,
                          self.session.id == parentID else { return }
                    self.childMetricsErrors[id] = error.localizedDescription
                }
            }
            guard let self, !self.closed, self.generation == scope, self.metricsGeneration == token,
                  self.session.id == parentID else { return }
            self.childMetricsLoading = false; self.childMetricsCheckedAt = Date()
        }
        metricsTask = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        if metricsGeneration == token { metricsTask = nil; childMetricsLoading = false }
    }

    private func saveSelection() {
        navigationSelections[session.id] = Selection(turnID: selectedTurnID, nodeID: selectedNodeID, observationIndex: selectedObservationIndex,
                                                     cutoff: historyCutoff, followsCurrentTurn: followsCurrentTurn)
    }

    private func navigate(to session: Session) {
        stopPolling(); generation = UUID()
        self.session = session; members[session.id] = session
        graph = measuredGraphs[session.id]; error = nil; sourceReadFailed = false
        lastLiveObservation = liveObservations[session.id]
        let saved = navigationSelections[session.id]
        selectedTurnID = saved?.turnID ?? graph?.currentTurnID
        selectedNodeID = saved?.nodeID; historyCutoff = saved?.cutoff
        selectedObservationIndex = saved?.observationIndex
        followsCurrentTurn = saved?.followsCurrentTurn ?? true
        selectedBody = nil; bodyError = nil
        childMetricsErrors = [:]; childMetricsCheckedAt = nil
    }

    func close() {
        stopPolling(); generation = UUID(); closed = true
        graph = nil; selectedTurnID = nil; selectedNodeID = nil; historyCutoff = nil
        selectedObservationIndex = nil
        selectedBody = nil; error = nil; bodyError = nil
    }
}
