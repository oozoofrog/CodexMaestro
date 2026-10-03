import Foundation
import CSQLite

/// Codex-owned databases are opened read-only. No migrations or repair writes.
public struct CodexCatalog: Sendable {
    public let home: URL
    public init(home: URL? = nil) {
        self.home = home ?? ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }
    public func read(includeArchived: Bool = false) throws -> Catalog {
        let files = try FileManager.default.contentsOfDirectory(at: home, includingPropertiesForKeys: nil)
        guard let state = files.filter({ $0.lastPathComponent.hasPrefix("state_") && $0.pathExtension == "sqlite" }).sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending }).first else {
            throw MaestroError.message("Codex 세션 데이터베이스를 찾을 수 없습니다. Codex에 로그인한 뒤 다시 연결하세요.")
        }
        let db = try ReadOnlyDatabase(url: state)
        let columns = Set(try db.rows("PRAGMA table_info(threads)").compactMap { $0["name"] })
        let required: Set<String> = ["id", "title", "cwd", "updated_at", "archived"]
        guard required.isSubset(of: columns) else { throw MaestroError.message("Codex 데이터베이스 형식이 변경되었습니다. 어댑터 업데이트가 필요합니다.") }
        let tables = Set(try db.rows("SELECT name FROM sqlite_master WHERE type='table'").compactMap { $0["name"] })
        var projects: [Project] = []
        if tables.contains("projects") && tables.contains("project_roots") {
            let roots = try db.rows("SELECT project_id, path FROM project_roots ORDER BY position")
            projects = try db.rows("SELECT id, name FROM projects ORDER BY position").compactMap { row in
                guard let id = row["id"], let name = row["name"] else { return nil }
                return Project(id: id, name: name, roots: roots.filter { $0["project_id"] == id }.compactMap { $0["path"] })
            }
        }
        func field(_ name: String) -> String { columns.contains(name) ? name : "NULL AS \(name)" }
        let fields = ["id", "title", "name", "cwd", "model", "reasoning_effort", "updated_at", "preview", "git_branch", "project_id", "source", "archived"].map(field).joined(separator: ",")
        let rows = try db.rows("SELECT \(fields) FROM threads \(includeArchived ? "" : "WHERE archived=0") ORDER BY updated_at DESC")
        let sessions = rows.compactMap { row -> Session? in
            guard let id = row["id"] else { return nil }
            let cwd = row["cwd"] ?? ""
            let projectID = row["project_id"] ?? projects.compactMap { project -> (id: String, length: Int)? in
                let matches = project.roots.compactMap { root -> String? in
                    var normalized = root
                    while normalized.count > 1 && normalized.hasSuffix("/") { normalized.removeLast() }
                    guard !normalized.isEmpty, cwd == normalized || cwd.hasPrefix(normalized == "/" ? "/" : normalized + "/") else { return nil }
                    return normalized
                }
                guard let length = matches.map(\.count).max() else { return nil }
                return (project.id, length)
            }.max(by: { $0.length < $1.length })?.id
            var parent: String?
            if let data = row["source"]?.data(using: .utf8), let source = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let sub = source["subAgent"] as? [String: Any] {
                parent = (sub["thread_spawn"] as? [String: Any])?["parent_thread_id"] as? String
            }
            let title = [row["name"], row["title"]].compactMap { $0 }.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? "제목 없는 세션"
            var session = Session(id: id, title: title, projectID: projectID, cwd: cwd, model: row["model"] ?? "", effort: row["reasoning_effort"] ?? "", updatedAt: Date(timeIntervalSince1970: Double(row["updated_at"] ?? "0") ?? 0), preview: row["preview"] ?? "", branch: row["git_branch"] ?? "", parentID: parent)
            session.isArchived = row["archived"] == "1"
            return session
        }
        return Catalog(projects: projects, sessions: sessions)
    }
    public func transcript(threadID: String, limit: Int = 30) throws -> [TranscriptMessage] {
        guard limit > 0 else { return [] }
        let url = home.appendingPathComponent("thread_history_1.sqlite")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let db = try ReadOnlyDatabase(url: url)
        let rows = try db.rows("SELECT item_id, item_json FROM thread_items WHERE thread_id=? AND item_type IN ('userMessage','agentMessage') ORDER BY rollout_ordinal DESC LIMIT ?", bindings: [threadID, String(limit)])
        return rows.reversed().compactMap { row in
            guard let raw = row["item_json"]?.data(using: .utf8), let item = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else { return nil }
            let role = item["type"] as? String == "userMessage" ? "user" : "assistant"
            let content = (item["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: "\n")
            guard let text = item["text"] as? String ?? content, !text.isEmpty else { return nil }
            return TranscriptMessage(id: row["item_id"] ?? UUID().uuidString, role: role, text: text)
        }
    }
}
final class ReadOnlyDatabase {
    private var db: OpaquePointer?
    init(url: URL) throws {
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(db); db = nil
            throw MaestroError.message("Codex 데이터 읽기 실패: \(message)")
        }
        sqlite3_busy_timeout(db, 1500)
    }
    deinit { sqlite3_close(db) }
    func rows(_ sql: String, bindings: [String] = []) throws -> [[String: String]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw error() }
        defer { sqlite3_finalize(stmt) }
        for (index, value) in bindings.enumerated() {
            _ = value.withCString { sqlite3_bind_text(stmt, Int32(index + 1), $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        }
        var result: [[String: String]] = []
        while true {
            let status = sqlite3_step(stmt)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw error() }
            var row: [String: String] = [:]
            for index in 0..<sqlite3_column_count(stmt) {
                if let value = sqlite3_column_text(stmt, index) { row[String(cString: sqlite3_column_name(stmt, index))] = String(cString: value) }
            }
            result.append(row)
        }
    }
    private func error() -> MaestroError { .message(String(cString: sqlite3_errmsg(db))) }
}
