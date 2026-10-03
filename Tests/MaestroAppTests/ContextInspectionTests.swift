import XCTest
import MaestroCore
@testable import CodexMaestro

private actor ContextReadGate {
    private var readers: [String: CheckedContinuation<ContextTopology, Error>] = [:]
    private var observers: [String: [CheckedContinuation<Void, Never>]] = [:]
    func read(_ scope: LinkEndpoint) async throws -> ContextTopology {
        try await withCheckedThrowingContinuation { continuation in
            readers[scope.id] = continuation
            for observer in observers.removeValue(forKey: scope.id) ?? [] { observer.resume() }
        }
    }
    func awaitReader(_ id: String) async {
        if readers[id] != nil { return }
        await withCheckedContinuation { observers[id, default: []].append($0) }
    }
    func finish(_ id: String, graph: ContextTopology) { readers.removeValue(forKey: id)?.resume(returning: graph) }
}

final class ContextInspectionTests: XCTestCase {
    private func workspaceBytes(_ value: WorkspaceState) -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try! encoder.encode(value)
    }
    @MainActor func testOverlapIsAProposalUntilChoiceAndCancellationDoesNotWrite() {
        let store = MaestroStore(demo: true)
        let original = store.workspace
        let selection = store.selectedSessionID
        store.requestOverlap(from: .project("app"), to: .session("models"))
        XCTAssertNotNil(store.overlapProposal)
        XCTAssertEqual(workspaceBytes(store.workspace), workspaceBytes(original))
        XCTAssertNil(store.actionSheetTarget)
        XCTAssertEqual(store.selectedSessionID, selection)
        store.overlapProposal = nil
        XCTAssertEqual(workspaceBytes(store.workspace), workspaceBytes(original))
        XCTAssertTrue(store.sending.isEmpty)
    }

    @MainActor func testOverlapChoiceSupportsAllCombinationsAndPreservesOriginsAndDrafts() {
        let pairs: [(LinkEndpoint, LinkEndpoint)] = [(.project("app"), .project("studio")), (.project("app"), .session("models")), (.session("design"), .project("studio")), (.session("design"), .session("models"))]
        for (source, target) in pairs {
            let store = MaestroStore(demo: true)
            store.workspace.positions["design"] = NodePosition(x: 170, y: 230)
            store.workspace.drafts["models"] = "existing"
            let positions = store.workspace.positions, drafts = store.workspace.drafts
            store.requestOverlap(from: source, to: target)
            let proposal = store.overlapProposal!
            XCTAssertTrue(store.confirmOverlap(proposal, function: .review))
            let link = store.workspace.allNodeLinks.first { $0.source == source && $0.target == target }!
            XCTAssertEqual(store.actionSheetTarget?.id, link.id)
            XCTAssertEqual(store.connectionAction(for: link.id).function, .review)
            XCTAssertEqual(store.connectionAction(for: link.id).executionSide, .target)
            XCTAssertEqual(store.workspace.positions, positions)
            XCTAssertEqual(store.workspace.drafts, drafts)
            XCTAssertNil(store.overlapProposal)
            XCTAssertTrue(store.sending.isEmpty)
            store.actionSheetTarget = nil
            store.requestOverlap(from: source, to: target)
            XCTAssertTrue(store.confirmOverlap(store.overlapProposal!, function: .reference))
            XCTAssertEqual(store.workspace.allNodeLinks.filter { $0.source == source && $0.target == target && $0.kind == .context }.count, 1)
        }
    }

    @MainActor func testOverlapRevalidatesTargetAndFailedSaveRestoresState() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MaestroStore(persistence: WorkspacePersistence(url: directory))
        store.projects = [Project(id: "p", name: "P"), Project(id: "q", name: "Q")]
        store.requestOverlap(from: .project("p"), to: .project("q"))
        let proposal = store.overlapProposal!, original = store.workspace
        store.projects.removeAll { $0.id == "q" }
        XCTAssertFalse(store.confirmOverlap(proposal, function: .handoff))
        XCTAssertEqual(workspaceBytes(store.workspace), workspaceBytes(original))
        store.projects.append(Project(id: "q", name: "Q"))
        XCTAssertFalse(store.confirmOverlap(proposal, function: .handoff))
        XCTAssertEqual(workspaceBytes(store.workspace), workspaceBytes(original))
        XCTAssertNotNil(store.overlapProposal)
        XCTAssertNil(store.actionSheetTarget)
    }

    @MainActor func testProjectPositionUsesHeaderBounds() {
        let store = MaestroStore(demo: true)
        store.setPosition("project:app", point: CGPoint(x: 180, y: 70))
        XCTAssertEqual(store.workspace.positions["project:app"], NodePosition(x: 180, y: 70))
        store.setPosition("design", point: CGPoint(x: 180, y: 70))
        XCTAssertEqual(store.workspace.positions["design"], NodePosition(x: 180, y: 200))
    }

    @MainActor func testContextReadsRejectStaleLoadsAndNeverSaveWorkspace() async {
        let gate = ContextReadGate()
        let store = MaestroStore(demo: true, contextReader: { scope, _, _ in try await gate.read(scope) })
        let original = store.workspace
        store.beginLink(from: .session("design"))
        store.openContext(for: .session("design"))
        await gate.awaitReader("design")
        XCTAssertNil(store.linkingEndpoint)
        store.openContext(for: .session("models"))
        await gate.awaitReader("models")
        await gate.finish("design", graph: ContextTopologyLoader.demo(endpoint: .session("design")))
        await Task.yield()
        XCTAssertEqual(store.contextScope, .session("models"))
        XCTAssertNil(store.contextTopology)
        await gate.finish("models", graph: ContextTopologyLoader.demo(endpoint: .session("models")))
        await store.contextTask?.value
        XCTAssertEqual(store.contextTopology?.scope, .session("models"))
        XCTAssertFalse(store.contextLoading)
        XCTAssertEqual(workspaceBytes(store.workspace), workspaceBytes(original))
        XCTAssertNil(store.overlapProposal)
        XCTAssertNil(store.actionSheetTarget)
        store.closeContext()
        XCTAssertNil(store.contextTopology); XCTAssertNil(store.contextScope)
        XCTAssertEqual(workspaceBytes(store.workspace), workspaceBytes(original))
    }

    @MainActor func testClosingContextCancelsPendingResultAndErrorIsVisible() async {
        let gate = ContextReadGate()
        let store = MaestroStore(demo: true, contextReader: { scope, _, _ in try await gate.read(scope) })
        store.openContext(for: .session("design")); await gate.awaitReader("design")
        let task = store.contextTask
        store.closeContext()
        await gate.finish("design", graph: ContextTopologyLoader.demo(endpoint: .session("design")))
        await task?.value
        XCTAssertNil(store.contextTopology); XCTAssertNil(store.contextError); XCTAssertFalse(store.contextLoading)
        let failing = MaestroStore(demo: true, contextReader: { _, _, _ in throw MaestroError.message("fixture read failed") })
        failing.openContext(for: .project("app")); await failing.contextTask?.value
        XCTAssertEqual(failing.contextError, "fixture read failed")
        XCTAssertFalse(failing.contextLoading)
    }

    @MainActor func testProjectContextIncludesHiddenMembersAndSavedRequestsWithoutWriting() async {
        let store = MaestroStore(demo: true)
        store.scope = "live"; store.search = "not visible"
        let link = NodeLink(source: .project("app"), target: .session("models"), kind: .context)
        XCTAssertTrue(store.saveNodeLink(link))
        XCTAssertTrue(store.saveConnectionAction(link: link, config: ConnectionActionConfiguration(function: .review, executionSide: .target, prompt: "저장한 검토 조건")))
        let original = workspaceBytes(store.workspace)
        store.openContext(for: .project("app"))
        await store.contextTask?.value
        XCTAssertEqual(Set(store.contextTopology!.sessions.map(\.id)), Set(store.sessions.filter { $0.projectID == "app" }.map(\.id)))
        XCTAssertTrue(store.contextTopology!.nodes.contains { $0.kind == .association && $0.fullText.contains("저장한 검토 조건") })
        XCTAssertEqual(workspaceBytes(store.workspace), original)
        XCTAssertTrue(store.workspace.drafts.isEmpty)
        XCTAssertTrue(store.sending.isEmpty)
    }

    @MainActor func testRemovedScopeIsRejectedOnLoadCompletionAndOptimizationPreparation() async {
        let gate = ContextReadGate()
        let store = MaestroStore(demo: true, contextReader: { scope, _, _ in try await gate.read(scope) })
        let graph = ContextTopologyLoader.demo(endpoint: .project("app"))
        store.openContext(for: graph.scope); await gate.awaitReader("app")
        store.projects.removeAll { $0.id == "app" }
        await gate.finish("app", graph: graph); await store.contextTask?.value
        XCTAssertNil(store.contextTopology)
        XCTAssertNotNil(store.contextError)
        XCTAssertFalse(store.contextLoading)
        store.contextTopology = graph
        let proposal = ContextOptimizationProposal(graph: graph, mode: .context, selectedNodeID: nil)
        store.optimizationProposal = proposal
        let prepared = await store.prepareContextOptimization(proposal, recipientID: "design", prompt: "must not write")
        XCTAssertFalse(prepared)
        XCTAssertTrue(store.workspace.drafts.isEmpty)
    }

    @MainActor func testOptimizationRequiresExplicitProjectRecipientAndPreservesExistingDraft() async {
        let store = MaestroStore(demo: true)
        let graph = ContextTopologyLoader.demo(endpoint: .project("app"))
        store.contextScope = graph.scope; store.contextTopology = graph
        store.requestOptimization(graph: graph, mode: .tools, selectedNodeID: nil)
        let proposal = store.optimizationProposal!
        XCTAssertEqual(Set(store.optimizationRecipients(for: proposal).map(\.id)), Set(["design", "bridge", "test"]))
        var result = await store.prepareContextOptimization(proposal, recipientID: "", prompt: "request")
        XCTAssertFalse(result)
        result = await store.prepareContextOptimization(proposal, recipientID: "models", prompt: "request")
        XCTAssertFalse(result)
        store.workspace.drafts["design"] = "original"
        result = await store.prepareContextOptimization(proposal, recipientID: "design", prompt: "request")
        XCTAssertFalse(result)
        XCTAssertEqual(store.draft(for: "design"), "original")
        XCTAssertNotNil(store.contextScope)
        store.workspace.drafts["design"] = ""
        let pinned = "사용자가 편집한 최적화 요청 😀"
        result = await store.prepareContextOptimization(proposal, recipientID: "design", prompt: pinned)
        XCTAssertTrue(result)
        XCTAssertEqual(store.draft(for: "design"), pinned)
        XCTAssertEqual(store.selectedSessionID, "design")
        XCTAssertNil(store.contextScope)
        XCTAssertNil(store.selectedProjectID)
        XCTAssertTrue(store.sending.isEmpty)
    }

    @MainActor func testOptimizationRejectsChangedMembershipAndSnapshot() async {
        let store = MaestroStore(demo: true)
        let graph = ContextTopologyLoader.demo(endpoint: .project("app"))
        store.contextScope = graph.scope; store.contextTopology = graph
        store.requestOptimization(graph: graph, mode: .context, selectedNodeID: nil)
        let proposal = store.optimizationProposal!
        store.sessions[store.sessions.firstIndex { $0.id == "design" }!].projectID = "runner"
        let moved = await store.prepareContextOptimization(proposal, recipientID: "design", prompt: "request")
        XCTAssertFalse(moved)
        store.contextTopology = ContextTopologyLoader.demo(endpoint: .project("app"))
        let stale = await store.prepareContextOptimization(proposal, recipientID: "bridge", prompt: "request")
        XCTAssertFalse(stale)
        XCTAssertTrue(store.workspace.drafts.isEmpty)
    }

    func testOptimizationPromptPreservesMeasurementAndCoverageBoundaries() {
        var graph = ContextTopology(scope: .session("s"), title: "Session", sessions: [Session(id: "s", title: "S", projectID: "p", cwd: "/tmp")])
        graph.coverage = [ContextCoverage(source: "/rollout.jsonl", sessionID: "s", status: .partial, records: 80, issues: ["missing line"])]
        graph.usage = [ContextUsage(id: "first", sessionID: "s", source: "first sample", label: "first", metrics: ["input_tokens": 100]), ContextUsage(id: "last", sessionID: "s", source: "last sample", label: "last", metrics: ["input_tokens": 200])]
        let text = ContextOptimizationPrompt.make(ContextOptimizationProposal(graph: graph, mode: .tools, selectedNodeID: nil))
        XCTAssertTrue(text.contains("input_tokens: 200")); XCTAssertFalse(text.contains("input_tokens: 300"))
        XCTAssertTrue(text.contains("partial")); XCTAssertTrue(text.contains("missing line"))
        XCTAssertTrue(text.contains("현재 사용할 수 있는 툴과 설정은 별도로 확인"))
        XCTAssertTrue(text.contains("사용자 요청, 우선순위, 제약, 수정 지시, 미해결 작업을 보존"))
        XCTAssertTrue(text.contains("토큰 수로 환산하지"))
    }
}
