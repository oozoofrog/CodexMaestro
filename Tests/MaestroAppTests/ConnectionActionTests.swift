import XCTest
import MaestroCore
@testable import CodexMaestro

final class ConnectionActionTests: XCTestCase {
    @MainActor func testCommandDropCreatesRelationFirstAndReuseDoesNotSendOrMoveNodes() {
        let store = MaestroStore(demo: true)
        let source = LinkEndpoint.project("app"), target = LinkEndpoint.session("models")
        let before = store.workspace.positions
        XCTAssertTrue(store.completeConnectionDrag(from: source, to: target))
        let link = store.workspace.allNodeLinks.last!
        XCTAssertEqual(store.actionSheetTarget?.id, link.id)
        store.actionSheetTarget = nil // Closing the configuration does not undo the cable.
        XCTAssertTrue(store.workspace.allNodeLinks.contains { $0.id == link.id })
        XCTAssertTrue(store.completeConnectionDrag(from: source, to: target))
        XCTAssertEqual(store.workspace.allNodeLinks.filter { $0.source == source && $0.target == target }.count, 1)
        XCTAssertEqual(store.workspace.positions, before)
        XCTAssertTrue(store.workspace.drafts.isEmpty)
        XCTAssertTrue(store.sending.isEmpty)
        XCTAssertFalse(store.completeConnectionDrag(from: source, to: source))
        XCTAssertFalse(store.completeConnectionDrag(from: source, to: .project("unassigned")))
    }

    @MainActor func testBothExecutionSidesResolveAllFourEndpointCombinations() async throws {
        let pairs: [(LinkEndpoint, LinkEndpoint)] = [(.session("design"), .session("models")), (.project("app"), .project("studio")), (.session("design"), .project("studio")), (.project("app"), .session("models"))]
        for (source, target) in pairs {
            let store = MaestroStore(demo: true)
            let link = NodeLink(source: source, target: target, kind: .review)
            XCTAssertTrue(store.saveNodeLink(link))
            for side in ConnectionExecutionSide.allCases {
                var config = ConnectionActionConfiguration(function: .custom, executionSide: side, prompt: "두 방향의 요청 원문")
                config.recipientSessionID = side == .source ? "design" : "models"
                let prompt = try await store.buildConnectionPrompt(link: link, config: config)
                let expected = side == .source ? "design" : "models"
                XCTAssertTrue(prompt.contains("(\(expected))"))
                XCTAssertTrue(prompt.contains("두 방향의 요청 원문"))
                XCTAssertTrue(prompt.contains(side == .source ? "Local AI" : "Codex") || prompt.contains("참고 세션:"))
                let prepared = await store.prepareConnectionAction(link: link, config: config, preparedPrompt: prompt)
                XCTAssertTrue(prepared)
                XCTAssertEqual(store.selectedSessionID, expected)
                XCTAssertNil(store.selectedProjectID, "Preparing work must retain the overall project flow")
                XCTAssertEqual(Set(store.visibleProjects.map(\.id)), Set(store.projects.map(\.id)))
                XCTAssertEqual(store.draft(for: expected), prompt)
                XCTAssertTrue(store.sending.isEmpty)
            }
        }
    }

    @MainActor func testProjectNeverSelectsRecipientImplicitlyAndMembershipIsRevalidated() async throws {
        let store = MaestroStore(demo: true)
        let link = NodeLink(source: .project("app"), target: .project("studio"), kind: .context)
        XCTAssertTrue(store.saveNodeLink(link))
        var config = ConnectionActionConfiguration()
        XCTAssertTrue(store.saveConnectionAction(link: link, config: config), "Unassigned project action is saveable but cannot run")
        let unassigned = await store.prepareConnectionAction(link: link, config: config)
        XCTAssertFalse(unassigned)
        XCTAssertTrue(store.workspace.drafts.isEmpty)
        config.recipientSessionID = "models"
        XCTAssertFalse(store.saveConnectionAction(link: link, config: config))
        config.recipientSessionID = "design"
        let prompt = try await store.buildConnectionPrompt(link: link, config: config)
        store.sessions[store.sessions.firstIndex { $0.id == "design" }!].projectID = "studio"
        let moved = await store.prepareConnectionAction(link: link, config: config, preparedPrompt: prompt)
        XCTAssertFalse(moved)
        XCTAssertTrue(store.workspace.drafts.isEmpty)
    }

    @MainActor func testPreparedSnapshotAndExistingDraftArePreserved() async throws {
        let store = MaestroStore(demo: true)
        let link = NodeLink(source: .session("design"), target: .session("models"), kind: .context)
        XCTAssertTrue(store.saveNodeLink(link))
        let config = ConnectionActionConfiguration(function: .handoff, executionSide: .target, prompt: "요청")
        let preview = "사용자가 확인한 고정 초안\n한글 😀"
        store.workspace.drafts["models"] = "기존 사용자 초안"
        let conflict = await store.prepareConnectionAction(link: link, config: config, preparedPrompt: preview)
        XCTAssertFalse(conflict)
        XCTAssertEqual(store.draft(for: "models"), "기존 사용자 초안")
        XCTAssertTrue(store.workspace.connectionActions.isEmpty)
        store.workspace.drafts["models"] = ""
        let prepared = await store.prepareConnectionAction(link: link, config: config, preparedPrompt: preview)
        XCTAssertTrue(prepared)
        XCTAssertEqual(store.draft(for: "models"), preview)
        XCTAssertEqual(store.workspace.version, 3)
        XCTAssertTrue(store.sending.isEmpty)
    }

    @MainActor func testFailedActionSaveAndDraftSaveRestoreAllState() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MaestroStore(persistence: WorkspacePersistence(url: directory.appendingPathComponent("workspace.json")))
        store.projects = [Project(id: "p", name: "P"), Project(id: "q", name: "Q")]
        store.sessions = [Session(id: "a", title: "A", projectID: "p", cwd: ""), Session(id: "b", title: "B", projectID: "q", cwd: "")]
        let link = NodeLink(source: .project("p"), target: .session("b"), kind: .context)
        XCTAssertTrue(store.saveNodeLink(link))
        try FileManager.default.removeItem(at: directory)
        try Data("blocked".utf8).write(to: directory)
        let config = ConnectionActionConfiguration(recipientSessionID: "a")
        XCTAssertFalse(store.saveConnectionAction(link: link, config: config))
        let prepared = await store.prepareConnectionAction(link: link, config: config, preparedPrompt: "새 초안")
        XCTAssertFalse(prepared)
        XCTAssertEqual(store.workspace.version, 2)
        XCTAssertTrue(store.workspace.connectionActions.isEmpty)
        XCTAssertTrue(store.workspace.drafts.isEmpty)
        XCTAssertNil(store.selectedSessionID)
        XCTAssertEqual(try Data(contentsOf: directory), Data("blocked".utf8))
    }

    @MainActor func testEveryAvailableFunctionDelegatesSkillsToReceivingSessionWithoutForcedBindingOrSend() async throws {
        let available: [ConnectionFunction] = [.reference, .handoff, .review, .custom]
        XCTAssertEqual(ConnectionFunction.availableFunctions, available)
        let selection = "이 세션에서 사용할 수 있는 스킬 중 요청에 적합한 스킬이 있으면 직접 선택해서 사용하세요."
        let original = "  요청 원문 e\u{301}\r\n두 번째 줄 😀  "
        for function in available {
            for side in ConnectionExecutionSide.allCases {
                let store = MaestroStore(demo: true)
                let link = NodeLink(source: .session("design"), target: .session("models"), kind: .context)
                XCTAssertTrue(store.saveNodeLink(link))
                let config = ConnectionActionConfiguration(function: function, executionSide: side, prompt: original,
                    skillName: "old-forced-skill", skillPath: "/missing/legacy/SKILL.md")
                let prompt = try await store.buildConnectionPrompt(link: link, config: config)
                XCTAssertEqual(prompt.components(separatedBy: selection).count - 1, 1)
                XCTAssertTrue(prompt.contains("적합한 스킬이 없으면 일반 작업 방식으로 진행하세요."))
                XCTAssertTrue(prompt.contains("반드시 필요한 스킬을 사용할 수 없으면 누락된 조건을 명시하세요."))
                XCTAssertFalse(prompt.contains("$old-forced-skill"))
                XCTAssertFalse(prompt.contains("/missing/legacy/SKILL.md"))
                XCTAssertNotNil(Data(prompt.utf8).range(of: Data(original.utf8)))
                XCTAssertTrue(store.saveConnectionAction(link: link, config: config))
                let saved = try XCTUnwrap(store.workspace.connectionActions[link.id.uuidString])
                XCTAssertEqual(saved.function, function)
                XCTAssertEqual(Array(saved.prompt.utf8), Array(original.utf8))
                XCTAssertNil(saved.skillName); XCTAssertNil(saved.skillPath)
                let prepared = await store.prepareConnectionAction(link: link, config: config, preparedPrompt: prompt)
                XCTAssertTrue(prepared)
                let recipient = side == .source ? "design" : "models"
                XCTAssertEqual(store.draft(for: recipient), prompt)
                XCTAssertEqual(store.selectedSessionID, recipient)
                XCTAssertTrue(store.sending.isEmpty)
                XCTAssertFalse(store.events.contains { $0.text.contains("프롬프트 전달") || $0.text.contains("데모 전송 완료") })
            }
        }
    }

    @MainActor func testMissingOrUnreadableLegacySkillPathNoLongerBlocksPreparation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let blocker = directory.appendingPathComponent("regular-file-parent")
        let retained = Data("not a directory".utf8)
        try retained.write(to: blocker)
        let oldPaths = [directory.appendingPathComponent("missing/SKILL.md").path, blocker.appendingPathComponent("SKILL.md").path]
        for path in oldPaths {
            XCTAssertFalse(FileManager.default.isReadableFile(atPath: path))
            let store = MaestroStore(demo: true)
            let link = NodeLink(source: .session("design"), target: .session("models"), kind: .context)
            XCTAssertTrue(store.saveNodeLink(link))
            let legacy = ConnectionActionConfiguration(function: .skill, executionSide: .target, prompt: " \t\r\n",
                skillName: "missing-old-skill", skillPath: path)
            XCTAssertTrue(store.saveConnectionAction(link: link, config: legacy))
            let prompt = try await store.buildConnectionPrompt(link: link, config: legacy)
            XCTAssertTrue(prompt.contains("참고 자료를 바탕으로 작업을 진행하세요."))
            XCTAssertFalse(prompt.contains("$missing-old-skill")); XCTAssertFalse(prompt.contains(path))
            let prepared = await store.prepareConnectionAction(link: link, config: legacy, preparedPrompt: prompt)
            XCTAssertTrue(prepared)
            let saved = try XCTUnwrap(store.workspace.connectionActions[link.id.uuidString])
            XCTAssertEqual(saved.function, .custom)
            XCTAssertEqual(saved.prompt, "참고 자료를 바탕으로 작업을 진행하세요.")
            XCTAssertNil(saved.skillName); XCTAssertNil(saved.skillPath)
            XCTAssertEqual(store.selectedSessionID, "models")
            XCTAssertTrue(store.sending.isEmpty)
        }
        XCTAssertEqual(try Data(contentsOf: blocker), retained)
    }

    @MainActor func testLegacySkillReadAndSavePreservePromptBytesAndPersistNormalizedConfiguration() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = WorkspacePersistence(url: directory.appendingPathComponent("workspace.json"))
        let original = "\n  사용자가 적은 $user-requested 텍스트 e\u{301}\r\n끝 😀  "
        let legacy = ConnectionActionConfiguration(function: .skill, executionSide: .target, recipientSessionID: "b", prompt: original,
            skillName: "stale-catalog-skill", skillPath: "/missing/stale/SKILL.md")
        let link = SessionLink(source: "a", target: "b", kind: .context)
        var state = WorkspaceState(); try state.addLink(link)
        state.connectionActions[link.id.uuidString] = legacy; state.version = 3
        try persistence.save(state)
        let originalDisk = try Data(contentsOf: persistence.url)
        let store = MaestroStore(persistence: persistence, catalog: CodexCatalog(home: directory), transcriptReader: { _ in
            [TranscriptMessage(id: "fixture", role: "assistant", text: "Isolated reference fixture")]
        })
        store.sessions = [Session(id: "a", title: "A", projectID: nil, cwd: ""), Session(id: "b", title: "B", projectID: nil, cwd: "")]
        let read = store.connectionAction(for: link.id)
        XCTAssertEqual(read.function, .custom)
        XCTAssertEqual(Array(read.prompt.utf8), Array(original.utf8))
        XCTAssertNil(read.skillName); XCTAssertNil(read.skillPath)
        XCTAssertEqual(try Data(contentsOf: persistence.url), originalDisk, "Reading legacy actions must not rewrite user files")
        XCTAssertTrue(store.saveConnectionAction(link: NodeLink(link), config: legacy))
        let persisted = try XCTUnwrap(persistence.load().connectionActions[link.id.uuidString])
        XCTAssertEqual(persisted, legacy.sessionManagedSkills())
        XCTAssertEqual(Array(persisted.prompt.utf8), Array(original.utf8))
        let prompt = try await store.buildConnectionPrompt(link: NodeLink(link), config: legacy)
        XCTAssertNotNil(Data(prompt.utf8).range(of: Data(original.utf8)))
        XCTAssertFalse(prompt.contains("$stale-catalog-skill")); XCTAssertFalse(prompt.contains("/missing/stale/SKILL.md"))
        let prepared = await store.prepareConnectionAction(link: NodeLink(link), config: legacy, preparedPrompt: prompt)
        XCTAssertTrue(prepared)
        XCTAssertEqual(store.draft(for: "b"), prompt)
        XCTAssertEqual(try persistence.load().connectionActions[link.id.uuidString], legacy.sessionManagedSkills())
        XCTAssertTrue(store.sending.isEmpty)
    }

    @MainActor func testTypedCRUDCleansUpActionAndPreservesActionOnFailedDelete() throws {
        let store = MaestroStore(demo: true)
        let projectLink = ProjectLink(source: "app", target: "studio", kind: .context)
        XCTAssertTrue(store.saveNodeLink(NodeLink(projectLink)))
        XCTAssertTrue(store.saveConnectionAction(link: NodeLink(projectLink), config: ConnectionActionConfiguration(recipientSessionID: "design")))
        XCTAssertTrue(store.deleteNodeLink(NodeLink(projectLink)))
        XCTAssertNil(store.workspace.connectionActions[projectLink.id.uuidString])
        let sessionLink = SessionLink(source: "design", target: "models", kind: .context)
        XCTAssertTrue(store.saveNodeLink(NodeLink(sessionLink)))
        XCTAssertTrue(store.saveConnectionAction(link: NodeLink(sessionLink), config: ConnectionActionConfiguration()))
        XCTAssertTrue(store.deleteNodeLink(NodeLink(sessionLink)))
        XCTAssertNil(store.workspace.connectionActions[sessionLink.id.uuidString])

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let failing = MaestroStore(persistence: WorkspacePersistence(url: directory.appendingPathComponent("workspace.json")))
        failing.projects = store.projects; failing.sessions = store.sessions
        XCTAssertTrue(failing.saveNodeLink(NodeLink(projectLink)))
        let config = ConnectionActionConfiguration(recipientSessionID: "design")
        XCTAssertTrue(failing.saveConnectionAction(link: NodeLink(projectLink), config: config))
        try FileManager.default.removeItem(at: directory)
        try Data("blocked".utf8).write(to: directory)
        XCTAssertFalse(failing.deleteNodeLink(NodeLink(projectLink)))
        XCTAssertEqual(failing.workspace.projectLinks, [projectLink])
        XCTAssertEqual(failing.workspace.connectionActions[projectLink.id.uuidString], config)
        XCTAssertEqual(failing.workspace.version, 3)
    }
}
