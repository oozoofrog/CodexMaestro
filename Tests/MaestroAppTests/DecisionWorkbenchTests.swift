import XCTest
import Foundation
@testable import MaestroCore
@testable import CodexMaestro

@MainActor final class DecisionWorkbenchTests: XCTestCase {
    private func repository(_ directory: URL) -> DecisionProfileRepository { .init(url: directory.appendingPathComponent("profiles.json")) }
    private func temporaryDirectory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    private func fixtureResult(_ profile: DecisionProfile, input: DecisionInput, bindings: [DecisionBinding] = []) -> DecisionResult {
        .init(status: .succeeded, profile: profile, inputFingerprint: input.fingerprint, evidence: input.evidence, stages: [:], traces: [], composed: .init(bindings: bindings), startedAt: Date(), completedAt: Date())
    }
    func testSaveCloneReuseAndDefinitionVersionsArePreservedWithoutCredentials() throws {
        let directory = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let maestro = MaestroStore(demo: true), store = DecisionWorkbenchStore(maestro: MaestroStore(demo: true), repository: repository(directory))
        store.apiKey = "private-synthetic-key-never-export"
        store.save(); XCTAssertNil(store.error)
        let id = store.profile.id
        store.profile.plan.stages[0].questions[0].spec.instructions = .string("변경한 질문")
        store.profile.plan.stages[0].questions[0].spec.criteria = .array([.string("없음"), .string("있음")])
        store.save()
        XCTAssertEqual(store.profile.revision, 2)
        XCTAssertEqual(store.profile.plan.stages[0].questions[0].revision, 2)
        XCTAssertEqual(store.profile.plan.stages[0].questions[0].criteriaRevision, 2)
        let reloaded = DecisionWorkbenchStore(maestro: maestro, repository: repository(directory))
        XCTAssertEqual(reloaded.profile, store.profile); XCTAssertTrue(reloaded.apiKey.isEmpty)
        XCTAssertFalse(String(decoding: try Data(contentsOf: repository(directory).url), as: UTF8.self).contains(store.apiKey))
        store.clone(); XCTAssertNotEqual(store.profile.id, id); store.save(); XCTAssertEqual(store.profiles.count, 2)
    }
    func testCorruptProfileFileBlocksWritesAndPreservesOriginalBytes() throws {
        let directory = temporaryDirectory(); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = Data("invalid profile storage".utf8); try original.write(to: repository(directory).url)
        let store = DecisionWorkbenchStore(maestro: MaestroStore(demo: true), repository: repository(directory))
        XCTAssertNotNil(store.error); store.save()
        XCTAssertEqual(try Data(contentsOf: repository(directory).url), original)
    }
    func testManualJSONLoadsLocallyAndMissingKeyNeverStartsExecution() async {
        let directory = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let maestro = MaestroStore(demo: true), store = DecisionWorkbenchStore(maestro: MaestroStore(demo: true), repository: repository(directory))
        store.manualJSON = #"{"goal":"한국어 자료 점검","ordered":["b","a"],"nested":{"nullable":null}}"#
        store.loadInput(maestro: maestro)
        while store.loadingInput { await Task.yield() }
        XCTAssertEqual(store.input?.state.at("/ordered/0"), .string("b"))
        store.run(maestro: maestro)
        XCTAssertFalse(store.running); XCTAssertNil(store.result)
        XCTAssertTrue(store.error?.contains("API 키") == true)
    }
    func testInvalidRubricIsBlockedAtSaveAndRunWithItsProfilePath() async {
        let directory = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let maestro = MaestroStore(demo: true), store = DecisionWorkbenchStore(maestro: maestro, repository: repository(directory))
        store.save()
        let original = try? Data(contentsOf: repository(directory).url)
        store.profile.plan.stages[0].questions[0].spec.criteria = .array([.null, .string("high")])
        store.save()
        XCTAssertTrue(store.error?.contains("/plan/stages/0/questions/0/spec/criteria/0") == true)
        XCTAssertEqual(try? Data(contentsOf: repository(directory).url), original)
        store.apiKey = "synthetic-key-never-sent"
        store.manualJSON = #"{"goal":"synthetic"}"#
        store.loadInput(maestro: maestro)
        while store.loadingInput { await Task.yield() }
        store.run(maestro: maestro)
        XCTAssertFalse(store.running)
        XCTAssertNil(store.result)
        XCTAssertTrue(store.error?.contains("/plan/stages/0/questions/0/spec/criteria/0") == true)
    }
    func testResultStalenessTracksProfileManualJSONAndDraftChanges() {
        let directory = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let maestro = MaestroStore(demo: true), store = DecisionWorkbenchStore(maestro: MaestroStore(demo: true), repository: repository(directory))
        let input = DecisionInput(state: .string("input"))
        store.result = fixtureResult(store.profile, input: input); store.resultSelectionFingerprint = store.selectionFingerprint(maestro: maestro)
        XCTAssertEqual(store.status(maestro: maestro), .succeeded)
        store.profile.name += "changed"; XCTAssertEqual(store.status(maestro: maestro), .stale)
        store.profile = store.result!.profile; store.manualJSON = "[]"; XCTAssertEqual(store.status(maestro: maestro), .stale)
        store.sourceKind = .draft; store.sessionID = "design"; store.resultSelectionFingerprint = store.selectionFingerprint(maestro: maestro)
        maestro.setDraft("new draft", for: "design"); XCTAssertEqual(store.status(maestro: maestro), .stale)
    }
    func testUnknownHandlerWrongDestinationAndStaleResultCannotPrepareDraft() async {
        let directory = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let maestro = MaestroStore(demo: true), store = DecisionWorkbenchStore(maestro: MaestroStore(demo: true), repository: repository(directory))
        let binding = DecisionBinding(handler: "prepareDraft", arguments: .object(["sessionID": .string("models"), "prompt": .string("exact original")]))
        store.result = fixtureResult(store.profile, input: .init(state: .string("input")), bindings: [binding]); store.resultSelectionFingerprint = store.selectionFingerprint(maestro: maestro)
        let wrong = await store.apply(binding, maestro: maestro, allowedSessionID: "design", allowedProjectID: "", comparisonSessionID: "")
        XCTAssertNil(wrong); XCTAssertTrue(maestro.workspace.drafts.isEmpty)
        let unknown = DecisionBinding(handler: "send", arguments: binding.arguments)
        store.result?.composed.bindings = [unknown]
        let unsupported = await store.apply(unknown, maestro: maestro, allowedSessionID: "models", allowedProjectID: "", comparisonSessionID: "")
        XCTAssertNil(unsupported); XCTAssertTrue(maestro.sending.isEmpty)
        store.result?.composed.bindings = [binding]; store.manualJSON = "changed"
        let stale = await store.apply(binding, maestro: maestro, allowedSessionID: "models", allowedProjectID: "", comparisonSessionID: "")
        XCTAssertNil(stale); XCTAssertTrue(maestro.workspace.drafts.isEmpty)
    }
    func testExplicitDraftPreparationCopiesExactOriginalAndProtectsExistingDraft() async {
        let directory = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let maestro = MaestroStore(demo: true), store = DecisionWorkbenchStore(maestro: MaestroStore(demo: true), repository: repository(directory))
        let prompt = "  원문 e\u{301}\r\n한글 😀  "
        let binding = DecisionBinding(handler: "prepareDraft", arguments: .object(["sessionID": .string("models"), "prompt": .string(prompt)]))
        store.result = fixtureResult(store.profile, input: .init(state: .string("input")), bindings: [binding]); store.resultSelectionFingerprint = store.selectionFingerprint(maestro: maestro)
        maestro.setDraft("existing", for: "models")
        let conflict = await store.apply(binding, maestro: maestro, allowedSessionID: "models", allowedProjectID: "", comparisonSessionID: "")
        XCTAssertNil(conflict)
        XCTAssertEqual(maestro.draft(for: "models"), "existing")
        maestro.setDraft("", for: "models")
        let applied = await store.apply(binding, maestro: maestro, allowedSessionID: "models", allowedProjectID: "", comparisonSessionID: "")
        XCTAssertNotNil(applied); XCTAssertEqual(maestro.draft(for: "models"), prompt); XCTAssertEqual(maestro.selectedSessionID, "models"); XCTAssertTrue(maestro.sending.isEmpty)
    }
    func testDraftPersistenceFailureRollsBackWorkspaceAndSelection() throws {
        let directory = temporaryDirectory(); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let maestro = MaestroStore(persistence: .init(url: directory.appendingPathComponent("workspace.json")))
        maestro.sessions = [.init(id: "target", title: "Target", projectID: "p", cwd: "")]
        maestro.scope = "recent"; maestro.search = "kept"; let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys; let before = try encoder.encode(maestro.workspace)
        try FileManager.default.removeItem(at: directory); try Data("blocked-parent".utf8).write(to: directory)
        XCTAssertFalse(maestro.prepareDecisionDraft("new prompt", sessionID: "target"))
        XCTAssertTrue(maestro.error?.contains("작업공간 저장 실패") == true)
        XCTAssertEqual(try encoder.encode(maestro.workspace), before)
        XCTAssertEqual(maestro.scope, "recent"); XCTAssertEqual(maestro.search, "kept"); XCTAssertNil(maestro.selectedSessionID); XCTAssertTrue(maestro.events.isEmpty); XCTAssertTrue(maestro.sending.isEmpty)
    }
    func testCancelledInputLoadDoesNotLeaveSpinnerOrPublishIntoAnotherScope() async {
        actor Gate {
            var continuation: CheckedContinuation<Void, Never>?
            func wait() async { await withCheckedContinuation { continuation = $0 } }
            var ready: Bool { continuation != nil }
            func release() { continuation?.resume(); continuation = nil }
        }
        let directory = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let gate = Gate(), maestro = MaestroStore(demo: true, contextReader: { endpoint, _, _ in await gate.wait(); return .init(scope: endpoint, title: "old") })
        let store = DecisionWorkbenchStore(maestro: maestro, repository: repository(directory))
        store.sourceKind = .session; store.sessionID = "design"; store.loadInput(maestro: maestro)
        while await !gate.ready { await Task.yield() }; store.sessionID = "models"; store.invalidateInput(); await gate.release()
        XCTAssertFalse(store.loadingInput); XCTAssertNil(store.input)
    }
}
