import XCTest
import MaestroCore
@testable import CodexMaestro

private actor WorkReadGate<Value: Sendable> {
    private var readers: [String: [CheckedContinuation<Value, Error>]] = [:]
    private var counts: [String: Int] = [:]
    private var observers: [String: [(Int, CheckedContinuation<Void, Never>)]] = [:]

    func read(_ id: String) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            readers[id, default: []].append(continuation)
            counts[id, default: 0] += 1
            let ready = observers[id, default: []].filter { $0.0 <= counts[id, default: 0] }
            observers[id] = observers[id, default: []].filter { $0.0 > counts[id, default: 0] }
            for (_, observer) in ready { observer.resume() }
        }
    }

    func awaitRead(_ id: String, count: Int = 1) async {
        if counts[id, default: 0] >= count { return }
        await withCheckedContinuation { observers[id, default: []].append((count, $0)) }
    }

    func finish(_ id: String, value: Value) { pop(id)?.resume(returning: value) }
    func fail(_ id: String, message: String) { pop(id)?.resume(throwing: MaestroError.message(message)) }
    func readCount(_ id: String) -> Int { counts[id, default: 0] }
    private func pop(_ id: String) -> CheckedContinuation<Value, Error>? {
        guard !readers[id, default: []].isEmpty else { return nil }
        return readers[id]?.removeFirst()
    }
}

private actor CatalogCancellationProbe {
    private var cancellation = false
    func record(_ value: Bool) { cancellation = value }
    func wasCancelled() -> Bool { cancellation }
}

final class SessionWorkStoreTests: XCTestCase {
    private static let start = Date(timeIntervalSince1970: 1000)

    private static func session(_ id: String, parentID: String? = nil) -> Session {
        var session = Session(id: id, title: id, projectID: "p", cwd: "/tmp", parentID: parentID)
        session.status = .running; session.isLive = true
        return session
    }

    private static func graph(_ id: String, current: String = "t1", child: String? = nil) -> SessionWorkTopology {
        let base = start
        var nodes = [
            WorkNode(id: "session:\(id)", sessionID: id, kind: .session, title: id, status: .running),
            WorkNode(id: "turn:\(id):t1", sessionID: id, turnID: "t1", kind: .session, title: "t1", status: .ended, timestamp: base),
            WorkNode(id: "\(id):prompt", sessionID: id, turnID: "t1", kind: .prompt, title: "Prompt", bodyPreview: "prompt preview", timestamp: base),
            WorkNode(id: "\(id):call", sessionID: id, turnID: "t1", kind: .toolCall, title: "Command", bodyPreview: "call preview", status: .ended, timestamp: base.addingTimeInterval(1), callID: "c1",
                     statusHistory: [WorkStatusObservation(timestamp: base.addingTimeInterval(1), status: .waiting, summary: "call observed", bodyPreview: "call preview"), WorkStatusObservation(timestamp: base.addingTimeInterval(5), status: .ended, summary: "result received", bodyPreview: "completed call")]),
            WorkNode(id: "\(id):result", sessionID: id, turnID: "t1", kind: .toolResult, title: "Result", bodyPreview: "result preview", status: .ended, timestamp: base.addingTimeInterval(5), callID: "c1")
        ]
        var turns = [WorkTurn(id: "t1", sessionID: id, promptNodeID: "\(id):prompt", status: .running, startedAt: base)]
        if current != "t1" {
            turns[0].status = .ended; turns[0].endedAt = base.addingTimeInterval(6)
            turns.append(WorkTurn(id: current, sessionID: id, status: .running, startedAt: base.addingTimeInterval(10)))
            nodes.append(WorkNode(id: "\(id):new", sessionID: id, turnID: current, kind: .prompt, title: "New prompt", timestamp: base.addingTimeInterval(10)))
        }
        if let child {
            nodes.append(WorkNode(id: "child:\(child)", sessionID: id, turnID: "t1", kind: .subsession, title: child, relatedSessionID: child))
        }
        return SessionWorkTopology(sessionID: id, title: id, nodes: nodes,
                                   edges: [WorkRelation(source: "\(id):result", target: "\(id):call", kind: .resultOf)],
                                   turns: turns,
                                   usage: [WorkUsage(id: "usage:\(id)", sessionID: id, turnID: "t1", input: 100, cachedInput: 80, output: 20, reasoningOutput: 5, scope: "세션 누적")],
                                   currentTurnID: current)
    }

    @MainActor func testScopeSwitchRejectsOldErrorWithoutClearingNewSpinner() async {
        let gate = WorkReadGate<SessionWorkTopology>()
        let store = SessionWorkStore(session: Self.session("a"), connected: true, pollInterval: nil,
                                     reader: { session, _ in try await gate.read(session.id) })
        let first = Task { await store.refresh() }
        await gate.awaitRead("a")
        let replacement = Task { await store.openSession(Self.session("b")) }
        await gate.awaitRead("b")
        await gate.fail("a", message: "late old error")
        await first.value
        XCTAssertEqual(store.session.id, "b")
        XCTAssertTrue(store.loading)
        XCTAssertNil(store.error)
        XCTAssertNil(store.graph)
        await gate.finish("b", value: Self.graph("b")); await replacement.value
        XCTAssertEqual(store.graph?.sessionID, "b")
        XCTAssertFalse(store.loading)
        store.close()
    }

    @MainActor func testCloseCancelsPollingAndRejectsLateGraph() async throws {
        let gate = WorkReadGate<SessionWorkTopology>()
        let store = SessionWorkStore(session: Self.session("a"), connected: true, pollInterval: .milliseconds(10),
                                     reader: { session, _ in try await gate.read(session.id) })
        store.start()
        await gate.awaitRead("a")
        let load = store.loadTask, poll = store.pollTask
        store.close()
        await gate.finish("a", value: Self.graph("a"))
        await load?.value; await poll?.value
        try await Task.sleep(for: .milliseconds(35))
        let reads = await gate.readCount("a")
        XCTAssertEqual(reads, 1)
        XCTAssertNil(store.pollTask); XCTAssertNil(store.loadTask)
        XCTAssertTrue(store.closed); XCTAssertNil(store.graph)
        XCTAssertFalse(store.loading); XCTAssertNil(store.error)
    }

    @MainActor func testSourceFailureAndDisconnectPreserveLastUsageAndStopSignals() async {
        let gate = WorkReadGate<SessionWorkTopology>()
        let session = Self.session("a")
        let store = SessionWorkStore(session: session, connected: true, pollInterval: nil,
                                     reader: { session, _ in try await gate.read(session.id) })
        store.start(); await gate.awaitRead("a")
        let initial = store.loadTask
        await gate.finish("a", value: Self.graph("a")); await initial?.value
        XCTAssertTrue(store.canAnimate)
        let refresh = Task { await store.refresh() }
        await gate.awaitRead("a", count: 2)
        await gate.fail("a", message: "source unavailable"); await refresh.value
        XCTAssertEqual(store.error, "source unavailable")
        XCTAssertTrue(store.stale); XCTAssertFalse(store.canAnimate)
        XCTAssertEqual(store.graph?.usage.first?.total, 120)
        store.synchronize(catalog: [], connected: false)
        XCTAssertNil(store.liveStatus)
        XCTAssertEqual(store.graph?.usage.first?.input, 100)
        XCTAssertEqual(store.graph?.nodes.first?.status, .unknown)
        store.close()
    }

    @MainActor func testPendingReadDoesNotOverwriteNewIPCState() async {
        let gate = WorkReadGate<SessionWorkTopology>()
        let store = SessionWorkStore(session: Self.session("a"), connected: true, pollInterval: nil,
                                     reader: { session, _ in try await gate.read(session.id) })
        let task = Task { await store.refresh() }; await gate.awaitRead("a")
        var waiting = Self.session("a"); waiting.status = .waiting
        let observation = Date(timeIntervalSince1970: 2000)
        store.synchronize(catalog: [waiting], connected: true, observedAt: observation, observedSessionID: "a")
        await gate.finish("a", value: Self.graph("a")); await task.value
        XCTAssertEqual(store.graph?.nodes.first?.status, .waiting)
        XCTAssertEqual(store.lastLiveObservation, observation)
        XCTAssertEqual(store.graph?.nodes.first { $0.kind == .toolCall }?.status, .ended)
        XCTAssertFalse(store.canAnimate)
        store.synchronize(catalog: [waiting], connected: true)
        XCTAssertEqual(store.lastLiveObservation, observation)
        store.close()
    }

    @MainActor func testUnavailableCoverageRetainsGraphWithoutRestoringLiveAnimation() async {
        let gate = WorkReadGate<SessionWorkTopology>()
        let store = SessionWorkStore(session: Self.session("a"), connected: true, pollInterval: nil,
                                     reader: { session, _ in try await gate.read(session.id) })
        store.start(); await gate.awaitRead("a")
        let initial = store.loadTask
        await gate.finish("a", value: Self.graph("a")); await initial?.value
        XCTAssertTrue(store.canAnimate)
        let task = Task { await store.refresh() }; await gate.awaitRead("a", count: 2)
        let unavailable = SessionWorkTopology(sessionID: "a", title: "a",
                                               nodes: [WorkNode(id: "session:a", sessionID: "a", kind: .session, title: "a")],
                                               coverage: [ContextCoverage(source: "rollout", sessionID: "a", status: .missing, issues: ["missing source"])])
        await gate.finish("a", value: unavailable); await task.value
        XCTAssertEqual(store.graph?.usage.first?.total, 120)
        XCTAssertTrue(store.graph?.nodes.contains { $0.id == "a:call" } == true)
        XCTAssertEqual(store.error, "missing source")
        XCTAssertTrue(store.stale); XCTAssertFalse(store.canAnimate)
        store.synchronize(catalog: [Self.session("a")], connected: true)
        XCTAssertFalse(store.canAnimate)
        store.close()
    }

    @MainActor func testPinnedTurnSelectionAndReplayRemainSeparateFromLiveRefresh() async {
        let gate = WorkReadGate<SessionWorkTopology>()
        let store = SessionWorkStore(session: Self.session("a"), connected: true, pollInterval: nil,
                                     reader: { session, _ in try await gate.read(session.id) })
        let first = Task { await store.refresh() }; await gate.awaitRead("a")
        await gate.finish("a", value: Self.graph("a")); await first.value
        store.selectNode("a:call")
        store.seek(to: Self.start.addingTimeInterval(2))
        XCTAssertEqual(store.visibleNodes.first { $0.id == "a:call" }?.status, .waiting)
        XCTAssertFalse(store.visibleNodes.contains { $0.id == "a:result" })
        XCTAssertTrue(store.visibleEdges.isEmpty)
        XCTAssertEqual(store.visibleNodes.first?.status, .unknown)
        let next = Task { await store.refresh() }; await gate.awaitRead("a", count: 2)
        await gate.finish("a", value: Self.graph("a", current: "t2")); await next.value
        XCTAssertEqual(store.selectedTurnID, "t1")
        XCTAssertEqual(store.selectedNodeID, "a:call")
        XCTAssertEqual(store.historyCutoff, Self.start.addingTimeInterval(2))
        XCTAssertFalse(store.canAnimate)
        store.returnToLive()
        XCTAssertEqual(store.selectedTurnID, "t2")
        XCTAssertNil(store.historyCutoff); XCTAssertNil(store.selectedNodeID)
        XCTAssertFalse(store.visibleNodes.contains { $0.id == "a:call" })
        store.close()
    }

    @MainActor func testLazyBodyRejectsOldSelectionAndCloseResults() async {
        let gate = WorkReadGate<String>()
        let fixture = Self.graph("a")
        let store = SessionWorkStore(session: Self.session("a"), connected: true, pollInterval: nil,
                                     reader: { _, _ in fixture }, bodyReader: { try await gate.read($0.id) })
        await store.refresh()
        store.selectNode("a:call"); await gate.awaitRead("a:call")
        let old = store.bodyTask
        store.selectNode("a:result"); await gate.awaitRead("a:result")
        await gate.finish("a:call", value: "late body"); await old?.value
        XCTAssertEqual(store.selectedNodeID, "a:result")
        XCTAssertTrue(store.bodyLoading)
        XCTAssertEqual(store.selectedBody, "result preview")
        let current = store.bodyTask
        await gate.finish("a:result", value: "full result"); await current?.value
        XCTAssertEqual(store.selectedBody, "full result"); XCTAssertFalse(store.bodyLoading)
        store.selectNode("a:call"); await gate.awaitRead("a:call", count: 2)
        let closing = store.bodyTask
        store.close()
        await gate.fail("a:call", message: "late close error"); await closing?.value
        XCTAssertNil(store.selectedBody); XCTAssertNil(store.bodyError); XCTAssertFalse(store.bodyLoading)
    }

    @MainActor func testReplayProjectsObservedSummaryAndExactBodyReference() async {
        let earlier = ContextBodyReference(path: "/fixture", offset: 10, length: 1, fingerprint: "earlier")
        let later = ContextBodyReference(path: "/fixture", offset: 50, length: 1, fingerprint: "later")
        var fixture = Self.graph("a")
        let index = fixture.nodes.firstIndex { $0.id == "a:call" }!
        fixture.nodes[index].summary = "future failure"
        fixture.nodes[index].bodyReference = later
        fixture.nodes[index].statusHistory = [
            WorkStatusObservation(timestamp: Self.start.addingTimeInterval(1), status: .running, summary: "observed running", bodyPreview: "earlier body", bodyReference: earlier),
            WorkStatusObservation(timestamp: Self.start.addingTimeInterval(5), status: .failed, summary: "future failure", bodyPreview: "later body", bodyReference: later)
        ]
        let snapshot = fixture
        let store = SessionWorkStore(session: Self.session("a"), connected: true, pollInterval: nil,
                                     reader: { _, _ in snapshot }, bodyReader: { "body offset:\($0.bodyReference?.offset ?? 0)" })
        await store.refresh()
        store.selectNode("a:call"); await store.bodyTask?.value
        XCTAssertEqual(store.selectedBody, "body offset:50")
        store.seek(to: Self.start.addingTimeInterval(2)); await store.bodyTask?.value
        XCTAssertEqual(store.visibleNodes.first { $0.id == "a:call" }?.summary, "observed running")
        XCTAssertEqual(store.visibleNodes.first { $0.id == "a:call" }?.status, .running)
        XCTAssertEqual(store.selectedBody, "body offset:10")
        store.returnToLive(); await store.bodyTask?.value
        XCTAssertEqual(store.selectedBody, "body offset:50")
        store.close()
    }

    @MainActor func testArchivedChildLookupAndBackRestoreParentSelectionAndBody() async {
        var child = Self.session("child", parentID: "a")
        child.isArchived = true; child.isLive = false; child.status = .unknown
        let archivedChild = child
        let store = SessionWorkStore(session: Self.session("a"), connected: true, pollInterval: nil,
                                     reader: { session, _ in Self.graph(session.id, child: session.id == "a" ? "child" : nil) },
                                     bodyReader: { "full body:\($0.id)" }, catalogReader: { [archivedChild] })
        await store.refresh()
        store.selectNode("a:call"); await store.bodyTask?.value
        store.seek(to: Self.start.addingTimeInterval(2))
        await store.openChild("child")
        XCTAssertEqual(store.session.id, "child")
        XCTAssertTrue(store.session.isArchived)
        XCTAssertEqual(store.breadcrumbs.map(\.id), ["a", "child"])
        XCTAssertFalse(store.canAnimate)
        XCTAssertEqual(Set(store.measuredGraphs.keys), Set(["a", "child"]))
        await store.back(); await store.bodyTask?.value
        XCTAssertEqual(store.session.id, "a")
        XCTAssertEqual(store.selectedNodeID, "a:call")
        XCTAssertEqual(store.selectedTurnID, "t1")
        XCTAssertEqual(store.historyCutoff, Self.start.addingTimeInterval(2))
        XCTAssertEqual(store.selectedBody, "full body:a:call")
        XCTAssertTrue(store.atRoot)
        store.close()
    }

    @MainActor func testRecordMapRoundTripPreservesInspectionAndWorkspace() async throws {
        let maestro = MaestroStore(demo: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let original = try encoder.encode(maestro.workspace)
        maestro.openSessionWork(for: "design")
        let inspection = try XCTUnwrap(maestro.workInspection)
        await inspection.refresh()
        maestro.showSessionRecordMap(); await maestro.contextTask?.value
        XCTAssertTrue(maestro.workInspection === inspection)
        XCTAssertEqual(maestro.contextScope, .session("design"))
        XCTAssertNil(inspection.pollTask)
        maestro.returnToSessionWork()
        XCTAssertNil(maestro.contextScope)
        XCTAssertTrue(maestro.workInspection === inspection)
        XCTAssertEqual(try encoder.encode(maestro.workspace), original)
        XCTAssertTrue(maestro.sending.isEmpty)
        maestro.openContext(for: .project("app")); await maestro.contextTask?.value
        XCTAssertNil(maestro.workInspection)
        XCTAssertEqual(maestro.contextScope, .project("app"))
        XCTAssertEqual(try encoder.encode(maestro.workspace), original)
        maestro.closeContext()
    }

    @MainActor func testObservationDetailIsIndependentFromReplayAndRegularSelectionClearsIt() async {
        let fixture = Self.graph("a")
        let store = SessionWorkStore(session: Self.session("a"), connected: true, pollInterval: nil,
                                     reader: { _, _ in fixture }, bodyReader: { $0.bodyPreview })
        await store.refresh()
        let cutoff = Self.start.addingTimeInterval(2)
        store.seek(to: cutoff)
        store.selectObservation(nodeID: "a:call", index: 1); await store.bodyTask?.value
        XCTAssertEqual(store.historyCutoff, cutoff)
        XCTAssertEqual(store.selectedObservationIndex, 1)
        XCTAssertEqual(store.selectedDetailNode?.status, .ended)
        XCTAssertEqual(store.selectedDetailNode?.summary, "result received")
        XCTAssertEqual(store.selectedDetailNode?.timestamp, Self.start.addingTimeInterval(5))
        XCTAssertEqual(store.selectedBody, "completed call")
        XCTAssertEqual(store.visibleNodes.first { $0.id == "a:call" }?.status, .waiting)
        store.seek(to: cutoff); await store.bodyTask?.value
        XCTAssertNil(store.selectedObservationIndex)
        XCTAssertEqual(store.selectedDetailNode?.status, .waiting)
        XCTAssertEqual(store.selectedBody, "call preview")
        store.selectObservation(nodeID: "a:call", index: 1)
        store.selectNode("a:call"); await store.bodyTask?.value
        XCTAssertNil(store.selectedObservationIndex)
        XCTAssertEqual(store.selectedDetailNode?.summary, "call observed")
        store.selectObservation(nodeID: "a:call", index: 1)
        store.selectTurn("t1"); await store.bodyTask?.value
        XCTAssertNil(store.selectedObservationIndex)
        store.close()
    }

    @MainActor func testObservationBodyRaceAndUndatedObservationRemainInspectable() async {
        let earlier = ContextBodyReference(path: "/fixture", offset: 10, length: 1, fingerprint: "earlier")
        let later = ContextBodyReference(path: "/fixture", offset: 50, length: 1, fingerprint: "later")
        var fixture = Self.graph("a")
        let index = fixture.nodes.firstIndex { $0.id == "a:call" }!
        fixture.nodes[index].statusHistory = [
            WorkStatusObservation(status: .unknown, summary: "undated raw item", bodyPreview: "undated", bodyReference: earlier),
            WorkStatusObservation(timestamp: Self.start.addingTimeInterval(5), status: .failed, summary: "dated failure", bodyPreview: "failure", bodyReference: later)
        ]
        let snapshot = fixture, gate = WorkReadGate<String>()
        let store = SessionWorkStore(session: Self.session("a"), connected: true, pollInterval: nil,
                                     reader: { _, _ in snapshot }, bodyReader: { try await gate.read(String($0.bodyReference?.offset ?? 0)) })
        await store.refresh()
        store.selectObservation(nodeID: "a:call", index: 0); await gate.awaitRead("10")
        XCTAssertNil(store.selectedDetailNode?.timestamp)
        XCTAssertEqual(store.selectedDetailNode?.summary, "undated raw item")
        let old = store.bodyTask
        store.selectObservation(nodeID: "a:call", index: 1); await gate.awaitRead("50")
        await gate.finish("10", value: "late undated body"); await old?.value
        XCTAssertEqual(store.selectedDetailNode?.status, .failed)
        XCTAssertTrue(store.bodyLoading)
        let current = store.bodyTask
        await gate.finish("50", value: "exact failure body"); await current?.value
        XCTAssertEqual(store.selectedBody, "exact failure body")
        store.close()
    }

    @MainActor func testSourceReplacementCannotRetargetSelectedObservation() async {
        let earlier = ContextBodyReference(path: "/fixture", offset: 10, length: 1, fingerprint: "generation-one")
        let replacement = ContextBodyReference(path: "/fixture", offset: 10, length: 1, fingerprint: "generation-two")
        var first = Self.graph("a"), next = Self.graph("a")
        let index = first.nodes.firstIndex { $0.id == "a:call" }!
        first.nodes[index].statusHistory = [WorkStatusObservation(timestamp: Self.start, status: .waiting, bodyPreview: "first", bodyReference: earlier)]
        next.nodes[index].statusHistory = [WorkStatusObservation(timestamp: Self.start, status: .waiting, bodyPreview: "replacement", bodyReference: replacement)]
        let gate = WorkReadGate<SessionWorkTopology>()
        let store = SessionWorkStore(session: Self.session("a"), connected: true, pollInterval: nil,
                                     reader: { session, _ in try await gate.read(session.id) }, bodyReader: { node in node.bodyPreview })
        let load = Task { await store.refresh() }; await gate.awaitRead("a")
        await gate.finish("a", value: first); await load.value
        store.selectObservation(nodeID: "a:call", index: 0); await store.bodyTask?.value
        let refresh = Task { await store.refresh() }; await gate.awaitRead("a", count: 2)
        await gate.finish("a", value: next); await refresh.value
        XCTAssertNil(store.selectedNodeID); XCTAssertNil(store.selectedObservationIndex)
        XCTAssertNil(store.selectedBody)
        store.close()
    }

    @MainActor func testCloseCancelsPendingArchivedCatalogLookup() async {
        let catalogGate = WorkReadGate<[Session]>(), probe = CatalogCancellationProbe()
        let fixture = Self.graph("a", child: "child")
        let store = SessionWorkStore(session: Self.session("a"), connected: true, pollInterval: nil,
                                     reader: { _, _ in fixture }, catalogReader: {
            let result = try await catalogGate.read("catalog")
            await probe.record(Task.isCancelled)
            return result
        })
        await store.refresh()
        let lookup = Task { await store.openChild("child") }
        await catalogGate.awaitRead("catalog")
        XCTAssertNotNil(store.catalogTask)
        store.close()
        await catalogGate.finish("catalog", value: [Self.session("child", parentID: "a")]); await lookup.value
        let cancelled = await probe.wasCancelled()
        XCTAssertTrue(cancelled)
        XCTAssertNil(store.catalogTask)
        XCTAssertEqual(store.session.id, "a")
        XCTAssertNil(store.graph); XCTAssertNil(store.error)
    }

    @MainActor func testAncestorBackRestoresObservationSelection() async {
        let child = Self.session("child", parentID: "a"), grandchild = Self.session("grandchild", parentID: "child")
        let store = SessionWorkStore(session: Self.session("a"), catalog: [child, grandchild], connected: true, pollInterval: nil,
                                     reader: { session, _ in
            Self.graph(session.id, child: session.id == "a" ? "child" : session.id == "child" ? "grandchild" : nil)
        }, bodyReader: { $0.bodyPreview })
        await store.refresh()
        let cutoff = Self.start.addingTimeInterval(2)
        store.seek(to: cutoff)
        store.selectObservation(nodeID: "a:call", index: 1); await store.bodyTask?.value
        await store.openChild("child"); await store.openChild("grandchild")
        XCTAssertEqual(store.breadcrumbs.map(\.id), ["a", "child", "grandchild"])
        await store.back(to: "a"); await store.bodyTask?.value
        XCTAssertEqual(store.breadcrumbs.map(\.id), ["a"])
        XCTAssertEqual(store.historyCutoff, cutoff)
        XCTAssertEqual(store.selectedObservationIndex, 1)
        XCTAssertEqual(store.selectedDetailNode?.status, .ended)
        XCTAssertEqual(store.selectedBody, "completed call")
        store.close()
    }

    @MainActor func testSuccessfulDraftPreparationClosesCircuitAndShowsRecipient() async throws {
        let decision = MaestroStore(demo: true)
        decision.openSessionWork(for: "design")
        let decisionCircuit = try XCTUnwrap(decision.workInspection)
        XCTAssertTrue(decision.prepareDecisionDraft("decision draft", sessionID: "models"))
        XCTAssertNil(decision.workInspection); XCTAssertNil(decision.contextScope)
        XCTAssertTrue(decisionCircuit.closed)
        XCTAssertEqual(decision.selectedSessionID, "models")
        XCTAssertEqual(decision.draft(for: "models"), "decision draft")
        XCTAssertTrue(decision.sending.isEmpty)

        let connection = MaestroStore(demo: true)
        let link = NodeLink(source: .session("design"), target: .session("models"), kind: .context)
        XCTAssertTrue(connection.saveNodeLink(link))
        connection.openSessionWork(for: "design")
        let connectionCircuit = try XCTUnwrap(connection.workInspection)
        let preparedConnection = await connection.prepareConnectionAction(link: link, config: ConnectionActionConfiguration(function: .review, executionSide: .target), preparedPrompt: "connection draft")
        XCTAssertTrue(preparedConnection)
        XCTAssertNil(connection.workInspection); XCTAssertTrue(connectionCircuit.closed)
        XCTAssertEqual(connection.selectedSessionID, "models")
        XCTAssertEqual(connection.draft(for: "models"), "connection draft")
        XCTAssertTrue(connection.sending.isEmpty)

        let optimization = MaestroStore(demo: true)
        optimization.openSessionWork(for: "design")
        let optimizationCircuit = try XCTUnwrap(optimization.workInspection)
        optimization.showSessionRecordMap(); await optimization.contextTask?.value
        let graph = try XCTUnwrap(optimization.contextTopology)
        optimization.requestOptimization(graph: graph, mode: .context, selectedNodeID: nil)
        let proposal = try XCTUnwrap(optimization.optimizationProposal)
        let preparedOptimization = await optimization.prepareContextOptimization(proposal, recipientID: "design", prompt: "optimization draft")
        XCTAssertTrue(preparedOptimization)
        XCTAssertNil(optimization.workInspection); XCTAssertNil(optimization.contextScope)
        XCTAssertTrue(optimizationCircuit.closed)
        XCTAssertEqual(optimization.selectedSessionID, "design")
        XCTAssertEqual(optimization.draft(for: "design"), "optimization draft")
        XCTAssertTrue(optimization.sending.isEmpty)
    }

    @MainActor func testRejectedDraftPreparationPreservesOpenCircuitAndDraft() {
        let store = MaestroStore(demo: true)
        store.workspace.drafts["models"] = "existing draft"
        store.openSessionWork(for: "design")
        let circuit = store.workInspection
        XCTAssertFalse(store.prepareDecisionDraft("replacement", sessionID: "models"))
        XCTAssertTrue(store.workInspection === circuit)
        XCTAssertEqual(store.selectedSessionID, "design")
        XCTAssertEqual(store.draft(for: "models"), "existing draft")
        XCTAssertTrue(store.sending.isEmpty)
        store.closeSessionWork()
    }

    @MainActor func testReceivingTurnIncludesOnlyExactLateReceiptAndPriorCall() async {
        var fixture = Self.graph("a", current: "t2")
        fixture.nodes.append(WorkNode(id: "turn:a:t2", sessionID: "a", turnID: "t2", kind: .session, title: "t2", timestamp: Self.start.addingTimeInterval(10)))
        let receiptIndex = fixture.nodes.firstIndex { $0.id == "a:result" }!
        fixture.nodes[receiptIndex].timestamp = Self.start.addingTimeInterval(11)
        fixture.edges.append(WorkRelation(source: "a:result", target: "turn:a:t2", kind: .receivedInTurn, evidence: "explicit receiving turn", observedAt: Self.start.addingTimeInterval(11)))
        let snapshot = fixture
        let store = SessionWorkStore(session: Self.session("a"), connected: true, pollInterval: nil,
                                     reader: { _, _ in snapshot }, bodyReader: { $0.bodyPreview })
        await store.refresh()
        XCTAssertEqual(store.selectedTurnID, "t2")
        XCTAssertTrue(store.visibleNodes.contains { $0.id == "a:result" && $0.turnID == "t1" })
        XCTAssertTrue(store.visibleNodes.contains { $0.id == "a:call" && $0.turnID == "t1" })
        XCTAssertFalse(store.visibleNodes.contains { $0.id == "a:prompt" })
        XCTAssertFalse(store.visibleNodes.contains { $0.id == "turn:a:t1" })
        XCTAssertTrue(store.visibleEdges.contains { $0.kind == .receivedInTurn && $0.evidence == "explicit receiving turn" })
        store.selectNode("a:call"); await store.bodyTask?.value
        XCTAssertEqual(store.selectedTurnID, "t2")
        XCTAssertEqual(store.selectedDetailNode?.turnID, "t1")
        store.seek(to: Self.start.addingTimeInterval(10))
        XCTAssertFalse(store.visibleNodes.contains { $0.id == "a:result" })
        XCTAssertFalse(store.visibleNodes.contains { $0.id == "a:call" })
        store.close()
    }

    @MainActor func testUnknownCurrentBoundaryDoesNotSelectPriorKnownPrompt() async {
        var fixture = Self.graph("a")
        fixture.currentTurnID = nil
        fixture.nodes.append(WorkNode(id: "unassigned:start", sessionID: "a", kind: .other, title: "turn ID unconfirmed", timestamp: Self.start.addingTimeInterval(20)))
        let snapshot = fixture
        let store = SessionWorkStore(session: Self.session("a"), connected: true, pollInterval: nil, reader: { _, _ in snapshot })
        await store.refresh()
        XCTAssertTrue(store.followsCurrentTurn)
        XCTAssertNil(store.selectedTurnID); XCTAssertNil(store.selectedTurn)
        XCTAssertFalse(store.visibleNodes.contains { $0.id == "a:prompt" })
        XCTAssertTrue(store.visibleNodes.contains { $0.id == "unassigned:start" })
        XCTAssertFalse(store.canAnimate)
        store.selectTurn("t1")
        XCTAssertTrue(store.visibleNodes.contains { $0.id == "a:prompt" })
        store.returnToLive()
        XCTAssertNil(store.selectedTurnID)
        XCTAssertFalse(store.visibleNodes.contains { $0.id == "a:prompt" })
        store.close()
    }

    @MainActor func testChildMetricsStayInParentScopeAndLateResultsAreRejectedAfterNavigation() async {
        let rootGraph = Self.graph("a", child: "child"), child = Self.session("child", parentID: "a")
        let gate = WorkReadGate<SessionWorkTopology>(), catalogGate = WorkReadGate<[Session]>()
        let store = SessionWorkStore(session: Self.session("a"), connected: true, pollInterval: nil,
                                     reader: { session, _ in
            if session.id == "child" { return try await gate.read("child") }
            return Self.graph(session.id, child: session.id == "a" ? "child" : nil)
        }, bodyReader: { $0.bodyPreview }, catalogReader: { try await catalogGate.read("catalog") })
        await store.refresh()
        store.selectNode("a:call"); await store.bodyTask?.value
        let body = store.selectedBody, selected = store.selectedNodeID, turn = store.selectedTurnID
        let firstMetrics = Task { await store.refreshChildMetrics() }
        await catalogGate.awaitRead("catalog")
        await catalogGate.finish("catalog", value: [child])
        await gate.awaitRead("child")
        XCTAssertTrue(store.childMetricsLoading)
        XCTAssertEqual(store.session.id, "a")
        XCTAssertEqual(store.graph?.nodes.count, rootGraph.nodes.count)
        XCTAssertEqual(store.selectedNodeID, selected); XCTAssertEqual(store.selectedTurnID, turn)
        XCTAssertEqual(store.selectedBody, body)
        await gate.finish("child", value: Self.graph("child")); await firstMetrics.value
        XCTAssertEqual(store.measuredGraphs["child"]?.usage.first?.total, 120)
        XCTAssertFalse(store.childMetricsLoading); XCTAssertNotNil(store.childMetricsCheckedAt)
        XCTAssertEqual(store.session.id, "a")
        XCTAssertEqual(store.selectedBody, body)
        let secondMetrics = Task { await store.refreshChildMetrics() }
        await gate.awaitRead("child", count: 2)
        let nav = Task { await store.openSession(Self.session("b")) }
        await nav.value
        var late = Self.graph("child")
        late.usage = [WorkUsage(sessionID: "child", input: 999, output: 1)]
        await gate.finish("child", value: late); await secondMetrics.value
        XCTAssertEqual(store.session.id, "b")
        XCTAssertEqual(store.graph?.sessionID, "b")
        XCTAssertEqual(store.measuredGraphs["child"]?.usage.first?.total, 120)
        XCTAssertFalse(store.childMetricsLoading)
        XCTAssertNil(store.metricsTask)
        store.close()
    }

    @MainActor func testRepeatedResultDoesNotRevealFutureReceivingTurnRelationship() async {
        var fixture = Self.graph("a", current: "t2")
        let receiveTime = Self.start.addingTimeInterval(11)
        fixture.nodes.append(WorkNode(id: "turn:a:t2", sessionID: "a", turnID: "t2", kind: .session, title: "t2", timestamp: Self.start.addingTimeInterval(10)))
        let resultIndex = fixture.nodes.firstIndex { $0.id == "a:result" }!
        // The canonical result first existed in t1. A later native update proves its receipt in t2.
        fixture.nodes[resultIndex].status = .failed
        fixture.nodes[resultIndex].summary = "native update received in t2"
        fixture.nodes[resultIndex].statusHistory = [
            WorkStatusObservation(timestamp: Self.start.addingTimeInterval(5), status: .ended, summary: "first receipt in t1", bodyPreview: "first result"),
            WorkStatusObservation(timestamp: receiveTime, status: .failed, summary: "native update received in t2", bodyPreview: "updated result")
        ]
        fixture.edges.append(WorkRelation(source: "a:result", target: "turn:a:t2", kind: .receivedInTurn, evidence: "later receiving record", observedAt: receiveTime))
        fixture.edges.append(WorkRelation(source: "session:a", target: "a:new", kind: .referencesArtifact, evidence: "later relationship between existing nodes", observedAt: receiveTime))
        let snapshot = fixture
        let store = SessionWorkStore(session: Self.session("a"), connected: true, pollInterval: nil,
                                     reader: { _, _ in snapshot }, bodyReader: { $0.bodyPreview })
        await store.refresh()
        store.seek(to: Self.start.addingTimeInterval(10))
        XCTAssertEqual(store.selectedTurnID, "t2")
        XCTAssertTrue(store.visibleNodes.contains { $0.id == "a:new" })
        XCTAssertFalse(store.visibleNodes.contains { $0.id == "a:result" })
        XCTAssertFalse(store.visibleNodes.contains { $0.id == "a:call" })
        XCTAssertFalse(store.visibleEdges.contains { $0.kind == .receivedInTurn })
        XCTAssertFalse(store.visibleEdges.contains { $0.kind == .referencesArtifact })
        store.seek(to: receiveTime)
        XCTAssertTrue(store.visibleNodes.contains { $0.id == "a:result" && $0.turnID == "t1" && $0.status == .failed })
        XCTAssertTrue(store.visibleNodes.contains { $0.id == "a:call" && $0.turnID == "t1" })
        XCTAssertTrue(store.visibleEdges.contains { $0.kind == .receivedInTurn && $0.observedAt == receiveTime })
        XCTAssertTrue(store.visibleEdges.contains { $0.kind == .referencesArtifact })
        store.selectNode("a:result"); await store.bodyTask?.value
        XCTAssertEqual(store.selectedTurnID, "t2")
        XCTAssertEqual(store.selectedBody, "updated result")
        store.close()
    }

    @MainActor func testUndatedReceiptDoesNotInheritEarlierCanonicalResultTime() async {
        var fixture = Self.graph("a", current: "t2")
        fixture.nodes.append(WorkNode(id: "turn:a:t2", sessionID: "a", turnID: "t2", kind: .session, title: "t2", timestamp: Self.start.addingTimeInterval(10)))
        let resultIndex = fixture.nodes.firstIndex { $0.id == "a:result" }!
        fixture.nodes[resultIndex].statusHistory.append(WorkStatusObservation(status: .failed, summary: "undated native update in t2", bodyPreview: "undated receipt body"))
        fixture.edges.append(WorkRelation(source: "a:result", target: "turn:a:t2", kind: .receivedInTurn, evidence: "receiving time unknown"))
        let snapshot = fixture
        let store = SessionWorkStore(session: Self.session("a"), connected: true, pollInterval: nil,
                                     reader: { _, _ in snapshot }, bodyReader: { $0.bodyPreview })
        await store.refresh()
        XCTAssertTrue(store.visibleNodes.contains { $0.id == "a:result" })
        store.selectObservation(nodeID: "a:result", index: 1); await store.bodyTask?.value
        XCTAssertEqual(store.selectedTurnID, "t2")
        XCTAssertNil(store.selectedDetailNode?.timestamp)
        XCTAssertEqual(store.selectedBody, "undated receipt body")
        store.seek(to: Self.start.addingTimeInterval(10))
        XCTAssertFalse(store.visibleNodes.contains { $0.id == "a:result" })
        XCTAssertFalse(store.visibleNodes.contains { $0.id == "a:call" })
        XCTAssertFalse(store.visibleEdges.contains { $0.kind == .receivedInTurn })
        store.close()
    }
}
