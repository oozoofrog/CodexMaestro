import XCTest
@testable import MaestroCore

final class ConnectionActionPersistenceTests: XCTestCase {
    func testLegacyDecodingAndVersionThreeDiskRoundTrip() throws {
        let legacy = Data(#"{"version":1,"links":[],"positions":{},"drafts":{"a":"기존"}}"#.utf8)
        var state = try JSONDecoder().decode(WorkspaceState.self, from: legacy)
        XCTAssertTrue(state.connectionActions.isEmpty)
        let link = NodeLink(source: .project("p"), target: .session("b"), kind: .context)
        try state.addNodeLink(link)
        let config = ConnectionActionConfiguration(function: .custom, executionSide: .target, recipientSessionID: "b", prompt: "원문 😀")
        state.connectionActions[link.id.uuidString] = config
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = WorkspacePersistence(url: directory.appendingPathComponent("workspace.json"))
        try persistence.save(state)
        let decoded = try persistence.load()
        XCTAssertEqual(decoded.version, 3)
        XCTAssertEqual(decoded.connectionActions[link.id.uuidString], config)
        XCTAssertEqual(decoded.drafts["a"], "기존")
        XCTAssertEqual(decoded.allNodeLinks, [link])
    }

    func testEditsPreserveConfigurationAndClearMovedExecutionRecipientAndDeleteCleansUp() throws {
        var state = WorkspaceState()
        var link = NodeLink(source: .project("p"), target: .session("b"), kind: .context)
        try state.addNodeLink(link)
        let config = ConnectionActionConfiguration(recipientSessionID: "a", prompt: "메모")
        state.connectionActions[link.id.uuidString] = config; state.version = 3
        link.note = "새 메모"
        try state.updateNodeLink(link)
        XCTAssertEqual(state.connectionActions[link.id.uuidString], config)
        XCTAssertEqual(state.version, 3)
        link.source = .project("q")
        try state.updateNodeLink(link)
        XCTAssertNil(state.connectionActions[link.id.uuidString]?.recipientSessionID)
        XCTAssertEqual(state.connectionActions[link.id.uuidString]?.prompt, "메모")
        state.removeNodeLink(id: link.id)
        XCTAssertTrue(state.connectionActions.isEmpty)
        XCTAssertEqual(state.version, 3)
    }

    func testLegacySkillDecodeNormalizesWithoutChangingRoutingOrPromptBytes() throws {
        let original = "\n  원문 $explicit-user-text e\u{301}\r\n끝 😀  "
        let legacy = ConnectionActionConfiguration(function: .skill, executionSide: .target, recipientSessionID: "receiver",
            prompt: original, skillName: "old", skillPath: "/missing/SKILL.md")
        let encoded = try JSONEncoder().encode(legacy)
        let decoded = try JSONDecoder().decode(ConnectionActionConfiguration.self, from: encoded)
        XCTAssertEqual(decoded.function, .skill, "Legacy enum value must remain decodable")
        let normalized = decoded.sessionManagedSkills()
        XCTAssertEqual(normalized.function, .custom)
        XCTAssertEqual(normalized.executionSide, .target)
        XCTAssertEqual(normalized.recipientSessionID, "receiver")
        XCTAssertEqual(Array(normalized.prompt.utf8), Array(original.utf8))
        XCTAssertNil(normalized.skillName); XCTAssertNil(normalized.skillPath)
        XCTAssertEqual(normalized.sessionManagedSkills(), normalized)
    }

    func testNormalizationSuppliesOnlyLegacyEmptyPromptAndClearsObsoleteMetadataForFourFunctions() {
        for prompt in ["", " \t\r\n"] {
            let legacy = ConnectionActionConfiguration(function: .skill, prompt: prompt)
            XCTAssertEqual(legacy.sessionManagedSkills().prompt, "참고 자료를 바탕으로 작업을 진행하세요.")
        }
        let available: [ConnectionFunction] = [.reference, .handoff, .review, .custom]
        XCTAssertEqual(ConnectionFunction.availableFunctions, available)
        for function in available {
            let config = ConnectionActionConfiguration(function: function, executionSide: .target, recipientSessionID: "receiver",
                prompt: "", skillName: "obsolete", skillPath: "/obsolete/SKILL.md")
            let normalized = config.sessionManagedSkills()
            XCTAssertEqual(normalized.function, function)
            XCTAssertEqual(normalized.prompt, "", "Do not invent task text for the four current functions")
            XCTAssertEqual(normalized.executionSide, .target)
            XCTAssertEqual(normalized.recipientSessionID, "receiver")
            XCTAssertNil(normalized.skillName); XCTAssertNil(normalized.skillPath)
        }
    }

    func testNormalizedLegacyActionDiskRoundTripDropsManualBindingAndPreservesOriginalText() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = WorkspacePersistence(url: directory.appendingPathComponent("workspace.json"))
        let original = "  原文 한글 e\u{301}\r\n$literal 😀  "
        let legacy = ConnectionActionConfiguration(function: .skill, executionSide: .target, recipientSessionID: "b", prompt: original,
            skillName: "old-skill", skillPath: "/not-readable/old/SKILL.md")
        let link = NodeLink(source: .project("p"), target: .session("b"), kind: .review)
        var state = WorkspaceState(); try state.addNodeLink(link)
        state.connectionActions[link.id.uuidString] = legacy.sessionManagedSkills()
        try persistence.save(state)
        let loaded = try persistence.load()
        let config = try XCTUnwrap(loaded.connectionActions[link.id.uuidString])
        XCTAssertEqual(config.function, .custom)
        XCTAssertEqual(config.executionSide, .target)
        XCTAssertEqual(config.recipientSessionID, "b")
        XCTAssertEqual(Array(config.prompt.utf8), Array(original.utf8))
        XCTAssertNil(config.skillName); XCTAssertNil(config.skillPath)
        XCTAssertEqual(loaded.allNodeLinks, [link])
        let disk = try String(contentsOf: persistence.url, encoding: .utf8)
        XCTAssertFalse(disk.contains("old-skill"))
        XCTAssertFalse(disk.contains("/not-readable/old/SKILL.md"))
    }
}
