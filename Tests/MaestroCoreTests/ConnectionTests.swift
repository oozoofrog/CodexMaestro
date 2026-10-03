import Foundation
import XCTest
@testable import MaestroCore

final class ConnectionTests: XCTestCase {
    func testExistingVersionOneWorkspaceDecodesWithoutProjectLinks() throws {
        let id = UUID()
        let data = Data("""
        {"version":1,"links":[{"id":"\(id)","source":"a","target":"b","kind":"context","note":"existing"}],"positions":{"a":{"x":23,"y":45}},"drafts":{"b":"private draft"}}
        """.utf8)
        let state = try JSONDecoder().decode(WorkspaceState.self, from: data)
        XCTAssertTrue(state.projectLinks.isEmpty)
        XCTAssertEqual(state.links.first?.id, id)
        XCTAssertEqual(state.positions["a"], NodePosition(x: 23, y: 45))
        XCTAssertEqual(state.drafts["b"], "private draft")
        let roundTrip = try JSONDecoder().decode(WorkspaceState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(roundTrip.links, state.links)
        XCTAssertEqual(roundTrip.drafts, state.drafts)
        XCTAssertEqual(roundTrip.version, 1)
    }
    func testProjectLinksPersistAlongsideSessionLinksAndPrivateDrafts() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("workspace.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var state = WorkspaceState()
        try state.addProjectLink(ProjectLink(source: "product", target: "sdk", kind: .dependency, note: "depends on build"))
        try state.addLink(SessionLink(source: "author", target: "reviewer", kind: .review))
        state.drafts["reviewer"] = "draft preserved"
        let persistence = WorkspacePersistence(url: url)
        try persistence.save(state)
        let actual = try persistence.load()
        XCTAssertEqual(actual.projectLinks, state.projectLinks)
        XCTAssertEqual(actual.links, state.links)
        XCTAssertEqual(actual.drafts, state.drafts)
        XCTAssertEqual(actual.version, 1)
    }
    func testProjectLinkValidationIsDirectedAndPurposeSpecific() throws {
        var state = WorkspaceState()
        let original = ProjectLink(source: "a", target: "b", kind: .context)
        try state.addProjectLink(original)
        XCTAssertThrowsError(try state.addProjectLink(ProjectLink(source: "a", target: "a", kind: .context)))
        XCTAssertThrowsError(try state.addProjectLink(ProjectLink(source: "a", target: "b", kind: .context)))
        XCTAssertThrowsError(try state.addProjectLink(ProjectLink(source: " \n", target: "b", kind: .context)))
        XCTAssertThrowsError(try state.addProjectLink(ProjectLink(source: "a", target: "", kind: .context)))
        XCTAssertThrowsError(try state.addProjectLink(ProjectLink(id: original.id, source: "x", target: "y", kind: .context)))
        try state.addProjectLink(ProjectLink(source: "b", target: "a", kind: .context))
        try state.addProjectLink(ProjectLink(source: "a", target: "b", kind: .review))
        XCTAssertEqual(state.projectLinks.count, 3)
    }
    func testProjectLinkUpdatePreservesIdentityAndDoesNotLoseDataOnFailure() throws {
        var state = WorkspaceState()
        let first = ProjectLink(source: "a", target: "b", kind: .context)
        let second = ProjectLink(source: "b", target: "c", kind: .review)
        try state.addProjectLink(first); try state.addProjectLink(second)
        var edited = first; edited.note = "revised"; edited.kind = .dependency
        try state.updateProjectLink(edited)
        XCTAssertEqual(state.projectLinks.map(\.id), [first.id, second.id])
        XCTAssertEqual(state.projectLinks.first?.note, "revised")
        let before = state.projectLinks
        edited.source = second.source; edited.target = second.target; edited.kind = second.kind
        XCTAssertThrowsError(try state.updateProjectLink(edited))
        XCTAssertEqual(state.projectLinks, before)
        XCTAssertThrowsError(try state.updateProjectLink(ProjectLink(source: "a", target: "b", kind: .review)))
        XCTAssertEqual(state.projectLinks, before)
    }
    func testSessionLinkUpdateRejectsCollisionWithoutRemovingOriginal() throws {
        var state = WorkspaceState()
        let first = SessionLink(source: "a", target: "b", kind: .context, note: "original")
        let second = SessionLink(source: "b", target: "c", kind: .review)
        try state.addLink(first); try state.addLink(second)
        var edited = first; edited.note = "updated"
        try state.updateLink(edited)
        XCTAssertEqual(state.links[0].note, "updated")
        let before = state.links
        edited.source = second.source; edited.target = second.target; edited.kind = second.kind
        XCTAssertThrowsError(try state.updateLink(edited))
        XCTAssertEqual(state.links, before)
        XCTAssertThrowsError(try state.addLink(SessionLink(source: "", target: "b", kind: .context)))
        XCTAssertThrowsError(try state.addLink(SessionLink(id: first.id, source: "x", target: "y", kind: .context)))
    }
    func testMalformedProjectLinksDoNotDecodeAsEmpty() throws {
        let data = Data("""
        {"version":1,"links":[],"projectLinks":"damaged","positions":{},"drafts":{}}
        """.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(WorkspaceState.self, from: data))
    }
}
