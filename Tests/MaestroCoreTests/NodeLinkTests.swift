import XCTest
@testable import MaestroCore

final class NodeLinkTests: XCTestCase {
    func testAllFourDirectionsPreserveTypedIdentityAndReverseRelationships() throws {
        var state = WorkspaceState()
        let endpoints: [(LinkEndpoint, LinkEndpoint)] = [
            (.session("same"), .session("other")), (.project("same"), .project("other")),
            (.session("same"), .project("same")), (.project("same"), .session("same"))
        ]
        for (source, target) in endpoints { try state.addNodeLink(NodeLink(source: source, target: target, kind: .context)) }
        XCTAssertEqual(state.links.count, 1)
        XCTAssertEqual(state.projectLinks.count, 1)
        XCTAssertEqual(state.nodeLinks.count, 2)
        XCTAssertEqual(state.allNodeLinks.count, 4)
        XCTAssertEqual(Set(state.allNodeLinks.map(\.id)).count, 4)
        XCTAssertEqual(Set(state.allNodeLinks.map(\.source)).count, 2)
        XCTAssertThrowsError(try state.addNodeLink(NodeLink(source: .session("same"), target: .session("same"), kind: .review)))
        XCTAssertThrowsError(try state.addNodeLink(NodeLink(source: .project("same"), target: .project("same"), kind: .review)))
        XCTAssertThrowsError(try state.addNodeLink(NodeLink(source: .session("same"), target: .project("same"), kind: .context)))
        try state.addNodeLink(NodeLink(source: .session("same"), target: .project("same"), kind: .review))
        XCTAssertEqual(state.allNodeLinks.count, 5)
    }

    func testEditingAcrossEndpointCombinationsKeepsIDAndRejectsCollisionAtomically() throws {
        var state = WorkspaceState()
        let first = NodeLink(source: .session("a"), target: .project("p"), kind: .context, note: "original")
        let second = NodeLink(source: .project("p"), target: .session("b"), kind: .review)
        try state.addNodeLink(first); try state.addNodeLink(second)
        var edited = first
        edited.source = .project("p"); edited.target = .project("q"); edited.note = "changed"
        try state.updateNodeLink(edited)
        XCTAssertEqual(state.projectLinks.first?.id, first.id)
        XCTAssertEqual(state.projectLinks.first?.note, "changed")
        XCTAssertEqual(state.nodeLinks, [second])
        edited.source = .session("a"); edited.target = .session("b")
        try state.updateNodeLink(edited)
        XCTAssertEqual(state.links.first?.id, first.id)
        XCTAssertTrue(state.projectLinks.isEmpty)
        let before = state.allNodeLinks
        edited.source = second.source; edited.target = second.target; edited.kind = second.kind
        XCTAssertThrowsError(try state.updateNodeLink(edited))
        XCTAssertEqual(state.allNodeLinks, before)
        state.removeNodeLink(id: first.id)
        XCTAssertEqual(state.allNodeLinks, [second])
        XCTAssertThrowsError(try state.updateNodeLink(first))
    }

    func testLegacyVersionOneLoadsWithoutMigrationAndRoundTripsMixedLinks() throws {
        let sid = UUID(), pid = UUID()
        let original = Data("""
        {"version":1,"links":[{"id":"\(sid)","source":"a","target":"b","kind":"context","note":"세션 메모"}],
        "projectLinks":[{"id":"\(pid)","source":"p","target":"q","kind":"dependency","note":"프로젝트 메모"}],
        "positions":{"a":{"x":234,"y":567}},"drafts":{"b":"기존 초안"}}
        """.utf8)
        var state = try JSONDecoder().decode(WorkspaceState.self, from: original)
        XCTAssertTrue(state.nodeLinks.isEmpty)
        XCTAssertEqual(state.links.first?.id, sid); XCTAssertEqual(state.projectLinks.first?.id, pid)
        let mixed = NodeLink(source: .project("p"), target: .session("b"), kind: .review, note: "혼합 메모")
        try state.addNodeLink(mixed)
        let reloaded = try JSONDecoder().decode(WorkspaceState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(reloaded.version, 2, "Mixed endpoints require the schema marker that protects against old writers")
        XCTAssertEqual(reloaded.links, state.links); XCTAssertEqual(reloaded.projectLinks, state.projectLinks)
        XCTAssertEqual(reloaded.nodeLinks, [mixed]); XCTAssertEqual(reloaded.allNodeLinks, state.allNodeLinks)
        XCTAssertEqual(reloaded.positions["a"], NodePosition(x: 234, y: 567))
        XCTAssertEqual(reloaded.drafts["b"], "기존 초안")
    }

    func testMixedLinkValidationAndMalformedStorageDoNotSilentlyDropData() throws {
        var state = WorkspaceState()
        let first = NodeLink(source: .session("a"), target: .project("p"), kind: .context)
        try state.addNodeLink(first)
        XCTAssertThrowsError(try state.addNodeLink(NodeLink(id: first.id, source: .project("q"), target: .session("b"), kind: .review)))
        XCTAssertThrowsError(try state.addLink(SessionLink(id: first.id, source: "a", target: "b", kind: .review)))
        XCTAssertThrowsError(try state.addProjectLink(ProjectLink(id: first.id, source: "p", target: "q", kind: .review)))
        XCTAssertThrowsError(try state.addNodeLink(NodeLink(source: .session(" \n"), target: .project("p"), kind: .review)))
        XCTAssertEqual(state.allNodeLinks, [first])
        let damaged = Data("""
        {"version":1,"links":[],"projectLinks":[],"nodeLinks":"damaged","positions":{},"drafts":{}}
        """.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(WorkspaceState.self, from: damaged))
    }

    func testNoteOnlyEditsRetainOrderWithinEveryStorageBucket() throws {
        let pairs: [(LinkEndpoint, LinkEndpoint)] = [
            (.session("a"), .session("b")), (.project("p"), .project("q")),
            (.session("a"), .project("p"))
        ]
        for (source, target) in pairs {
            var state = WorkspaceState()
            var first = NodeLink(source: source, target: target, kind: .context)
            let second = NodeLink(source: source, target: target, kind: .review)
            try state.addNodeLink(first); try state.addNodeLink(second)
            first.note = "updated in place"
            try state.updateNodeLink(first)
            XCTAssertEqual(state.allNodeLinks, [first, second])
        }
    }

    func testDiskPersistencePreservesAllBucketsAndPermissions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = WorkspacePersistence(url: directory.appendingPathComponent("workspace.json"))
        var state = WorkspaceState()
        try state.addNodeLink(NodeLink(source: .session("a"), target: .session("b"), kind: .context))
        try state.addNodeLink(NodeLink(source: .project("p"), target: .project("q"), kind: .dependency))
        try state.addNodeLink(NodeLink(source: .session("a"), target: .project("q"), kind: .review))
        try state.addNodeLink(NodeLink(source: .project("p"), target: .session("b"), kind: .context))
        try persistence.save(state)
        let reloaded = try persistence.load()
        XCTAssertEqual(reloaded.version, 2)
        XCTAssertEqual(reloaded.allNodeLinks, state.allNodeLinks)
        let permissions = try FileManager.default.attributesOfItem(atPath: persistence.url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }
}
