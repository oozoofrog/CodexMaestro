import XCTest
import Foundation
import CSQLite
@testable import MaestroCore

final class ArchivedContextCatalogTests: XCTestCase {
    func testDefaultCatalogExcludesArchiveAndContextCatalogIncludesMappedArchivedSessions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("state_5.sqlite").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let sql = """
        CREATE TABLE projects(id TEXT, name TEXT, position INT);
        CREATE TABLE project_roots(project_id TEXT, path TEXT, position INT);
        CREATE TABLE threads(id TEXT, title TEXT, cwd TEXT, updated_at INT, archived INT, project_id TEXT);
        INSERT INTO projects VALUES('p', 'Product', 0);
        INSERT INTO project_roots VALUES('p', '/work/product', 0);
        INSERT INTO threads VALUES('active', 'Current task', '/work/product', 30, 0, NULL);
        INSERT INTO threads VALUES('archived', 'Earlier task', '/work/product/Sources', 20, 1, NULL);
        INSERT INTO threads VALUES('other', 'Other project', '/work/product-extra', 10, 1, NULL);
        """
        var error: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, sql, nil, nil, &error)
        let message = error.map { String(cString: $0) } ?? ""
        sqlite3_free(error); XCTAssertEqual(result, SQLITE_OK, message)
        let catalog = CodexCatalog(home: directory)
        let active = try catalog.read()
        XCTAssertEqual(active.sessions.map(\.id), ["active"])
        XCTAssertFalse(try XCTUnwrap(active.sessions.first).isArchived)
        let context = try catalog.read(includeArchived: true)
        XCTAssertEqual(context.sessions.map(\.id), ["active", "archived", "other"])
        let archived = try XCTUnwrap(context.sessions.first { $0.id == "archived" })
        XCTAssertTrue(archived.isArchived); XCTAssertEqual(archived.projectID, "p")
        let other = try XCTUnwrap(context.sessions.first { $0.id == "other" })
        XCTAssertTrue(other.isArchived); XCTAssertNil(other.projectID)
        XCTAssertEqual(context.sessions.filter { $0.projectID == "p" }.map(\.id), ["active", "archived"])
    }
}
