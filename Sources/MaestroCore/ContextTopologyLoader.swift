import Foundation
import CoreFoundation
import CSQLite

/// Reads recorded evidence only. No Codex-owned file is modified.
public struct ContextTopologyLoader: Sendable {
    public let home: URL
    public init(home: URL) { self.home = home }
    public func load(session: Session, catalog: [Session] = []) async throws -> ContextTopology {
        try Task.checkCancellation()
        return try read(scope: .session(session.id), title: session.title, sessions: [session], catalog: catalog)
    }
    public func load(project: Project, sessions: [Session]) async throws -> ContextTopology {
        try Task.checkCancellation()
        var result = try read(scope: .project(project.id), title: project.name, sessions: sessions.filter { $0.projectID == project.id }, catalog: sessions)
        let root = ContextNode(id: "project:\(project.id)", kind: .project, title: project.name, fullText: project.roots.joined(separator: "\n"), source: "Codex catalog")
        result.nodes.insert(root, at: 0)
        for index in result.nodes.indices where result.nodes[index].kind == .session { result.nodes[index].parentID = root.id }
        appendInstructions(paths: project.roots, parentID: root.id, sessionID: nil, topology: &result)
        result.edges += result.sessions.map { ContextEdge(source: root.id, target: "session:\($0.id)", relation: "구성원") }
        return result
    }
    public func loadBody(node: ContextNode) async throws -> String {
        try Task.checkCancellation()
        guard let ref = node.bodyReference else { return node.fullText }
        let data: Data
        if let itemID = ref.itemID {
            guard let sessionID = ref.sessionID else { throw MaestroError.message("기록의 세션 범위를 확인할 수 없습니다. 다시 불러오세요.") }
            let db = try ReadOnlyDatabase(url: URL(fileURLWithPath: ref.path))
            guard let raw = try db.rows("SELECT item_json FROM thread_items WHERE thread_id=? AND item_id=?", bindings: [sessionID, itemID]).first?["item_json"] else { throw MaestroError.message("기록이 삭제되었습니다. 다시 불러오세요.") }
            data = Data(raw.utf8)
        } else {
            let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: ref.path)); defer { try? file.close() }
            try file.seek(toOffset: ref.offset)
            data = try file.read(upToCount: ref.length) ?? Data()
        }
        guard data.count == ref.length, Self.fingerprint(data) == ref.fingerprint else { throw MaestroError.message("기록 내용이 변경되었습니다. 다시 불러오세요.") }
        if let json = try? JSONSerialization.jsonObject(with: data) { return Self.pretty(Self.sanitize(json)) }
        return String(decoding: data, as: UTF8.self)
    }
    private func read(scope: LinkEndpoint, title: String, sessions: [Session], catalog: [Session]) throws -> ContextTopology {
        var topology = ContextTopology(scope: scope, title: title, sessions: sessions)
        var instructionPaths = Set<String>(); var groupKinds: [String: ContextNodeKind] = [:]
        for session in sessions {
            try Task.checkCancellation()
            let rootID = "session:\(session.id)"
            topology.nodes.append(ContextNode(id: rootID, kind: .session, title: session.title, fullText: "ID: \(session.id)\n경로: \(session.cwd)\n모델: \(session.model)\n추론: \(session.effort)\n브랜치: \(session.branch)\n보관: \(session.isArchived)", source: "Codex catalog", sessionID: session.id))
            for related in catalog where related.parentID == session.id || related.id == session.parentID {
                let id = "related:\(session.id):\(related.id)"
                topology.nodes.append(ContextNode(id: id, parentID: rootID, kind: .association, title: related.title, fullText: "ID: \(related.id)\n경로: \(related.cwd)", source: "Codex catalog parentID", sessionID: related.id))
                topology.edges.append(ContextEdge(source: rootID, target: id, relation: related.parentID == session.id ? "하위 세션" : "상위 세션"))
            }
            var groups = Set<String>(); var tools = Set<String>(); var references = Set<String>()
            var callNodes: [String: Int] = [:]; var resultNodes: [String: Int] = [:]; var callTools: [String: String] = [:]; var pendingResults: [(index: Int, callID: String)] = []
            func appendRecord(_ raw: Data, path: String, ordinal: Int, offset: UInt64, itemID: String? = nil) throws {
                try Task.checkCancellation()
                guard let json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else { throw MaestroError.message("JSON 기록 \(ordinal)을 읽을 수 없습니다.") }
                let payload = json["payload"] as? [String: Any] ?? json
                let type = payload["type"] as? String ?? json["type"] as? String ?? "record"
                let role = payload["role"] as? String ?? ""
                let kind = Self.kind(type: type, outer: json["type"] as? String ?? "", role: role)
                let groupID = rootID + ":group:" + kind.rawValue
                if groups.insert(groupID).inserted {
                    groupKinds[groupID] = kind
                    topology.nodes.append(ContextNode(id: groupID, parentID: rootID, kind: .group, title: kind.label, source: path, sessionID: session.id))
                    topology.edges.append(ContextEdge(source: rootID, target: groupID, relation: "기록"))
                }
                let safe = Self.sanitize(json); let body = Self.pretty(safe)
                let id = rootID + ":record:" + (itemID ?? "\(ordinal)") + ":" + URL(fileURLWithPath: path).lastPathComponent
                let timestamp = json["timestamp"] as? String ?? ""
                let nativeTool = payload["tool"] as? String ?? payload["toolName"] as? String
                let name = payload["name"] as? String ?? nativeTool ?? type
                let toolName: String
                if let server = payload["server"] as? String, let tool = nativeTool { toolName = server + "." + tool } else { toolName = name }
                let stableCall = payload["call_id"] as? String ?? payload["id"] as? String ?? itemID ?? id
                let toolID = rootID + ":tool:" + toolName
                let preview = String(body.prefix(1400))
                let ref = ContextBodyReference(path: path, offset: offset, length: raw.count, fingerprint: Self.fingerprint(raw), itemID: itemID, sessionID: session.id)
                var record = ContextNode(id: kind == .toolCall ? rootID + ":call:" + stableCall : (kind == .toolResult && payload["call_id"] is String ? rootID + ":result:" + stableCall : id), parentID: kind == .toolCall ? toolID : groupID, kind: kind, title: "\(ordinal + 1). \(role.isEmpty ? toolName : role) \(timestamp)", summary: String(body.prefix(220)), fullText: preview + (body.count > 1400 ? "\n[미리보기 — 전체 기록은 선택하여 읽기]" : ""), source: path + " #\(ordinal + 1)", sessionID: session.id, recordCount: 1, bodyReference: ref, charCount: body.count)
                if kind == .toolCall, let existing = callNodes[stableCall] {
                    record.source = topology.nodes[existing].source + "\n갱신: " + record.source
                    topology.nodes[existing] = record
                    return
                }
                if kind == .toolResult, let callID = payload["call_id"] as? String, let existing = resultNodes[callID] {
                    record.source = topology.nodes[existing].source + "\n갱신: " + record.source
                    topology.nodes[existing] = record
                    return
                }
                let recordIndex = topology.nodes.count
                topology.nodes.append(record)
                if kind == .toolResult, let callID = payload["call_id"] as? String { pendingResults.append((recordIndex, callID)); resultNodes[callID] = recordIndex }
                topology.edges.append(ContextEdge(source: groupID, target: record.id, relation: "포함"))
                if kind == .toolCall {
                    callNodes[stableCall] = recordIndex; callTools[stableCall] = toolID
                    if tools.insert(toolID).inserted {
                        topology.nodes.append(ContextNode(id: toolID, parentID: groupID, kind: .tool, title: toolName, summary: "기록에서 사용 관찰", source: path, sessionID: session.id))
                        topology.edges.append(ContextEdge(source: groupID, target: toolID, relation: "관찰된 도구"))
                    }
                    topology.edges.append(ContextEdge(source: toolID, target: record.id, relation: "호출"))
                }
                if type == "token_count" || type == "token_usage_record" {
                    let clean = safe as? [String: Any] ?? [:]
                    let cleanPayload = clean["payload"] as? [String: Any] ?? clean
                    let metrics = Self.usageMetrics(cleanPayload, prefix: clean["payload"] == nil ? "" : "payload")
                    if !metrics.isEmpty { topology.usage.append(ContextUsage(id: id, sessionID: session.id, source: path, label: timestamp.isEmpty ? type : timestamp, metrics: metrics)) }
                }
                if kind == .instruction || kind == .metadata || kind == .toolCall || kind == .toolResult || kind == .file || kind == .message {
                    for (refKind, value) in Self.references(body) where references.insert(refKind.rawValue + value).inserted {
                        let refID = rootID + ":reference:" + refKind.rawValue + ":" + value
                        topology.nodes.append(ContextNode(id: refID, parentID: rootID, kind: refKind, title: value, summary: "기록에 등장한 참조", fullText: value, source: path, sessionID: session.id))
                        topology.edges.append(ContextEdge(source: record.id, target: refID, relation: "참조"))
                    }
                }
            }
            let rollout: String?
            do {
                let stored = try stateRecord(session.id)
                rollout = stored?["rollout_path"].flatMap { $0.isEmpty ? nil : ($0.hasPrefix("/") ? $0 : home.appendingPathComponent($0).path) }
                if let stored {
                    let body = Self.pretty(stored)
                    topology.nodes.append(ContextNode(id: rootID + ":catalog-metadata", parentID: rootID, kind: .metadata, title: "저장된 세션 메타데이터", fullText: body, source: "Codex state database", sessionID: session.id))
                    if let count = stored["tokens_used"].flatMap(Int64.init) {
                        topology.usage.append(ContextUsage(id: rootID + ":catalog-tokens", sessionID: session.id, source: "Codex state database", label: "저장된 누적 사용량", metrics: ["tokens_used": count]))
                    }
                }
            }
            catch {
                rollout = nil
                topology.coverage.append(ContextCoverage(source: "Codex state database", sessionID: session.id, status: .error, issues: [error.localizedDescription]))
            }
            var needsFallback = true
            if let rollout, FileManager.default.fileExists(atPath: rollout) {
                var count = 0; var bytes = 0; var issues: [String] = []
                do {
                    try Self.lines(path: rollout) { data, offset in
                        bytes += data.count
                        do { try appendRecord(data, path: rollout, ordinal: count, offset: offset) }
                        catch is CancellationError { throw CancellationError() }
                        catch { issues.append(error.localizedDescription) }
                        count += 1
                    }
                    needsFallback = !issues.isEmpty || count == 0
                    topology.coverage.append(ContextCoverage(source: rollout, sessionID: session.id, status: issues.isEmpty && count > 0 ? .complete : .partial, records: count, bytes: bytes, issues: issues))
                } catch is CancellationError { throw CancellationError() }
                catch { topology.coverage.append(ContextCoverage(source: rollout, sessionID: session.id, status: .error, records: count, bytes: bytes, issues: [error.localizedDescription])) }
            } else { topology.coverage.append(ContextCoverage(source: rollout ?? "rollout", sessionID: session.id, status: .missing, issues: ["저장된 rollout을 찾을 수 없습니다."])) }
            if needsFallback {
                let history = home.appendingPathComponent("thread_history_1.sqlite").path
                var count = 0; var bytes = 0; var issues: [String] = []
                do {
                    try Self.history(path: history, sessionID: session.id) { raw, itemID in
                        bytes += raw.count
                        do { try appendRecord(raw, path: history, ordinal: count, offset: 0, itemID: itemID) }
                        catch is CancellationError { throw CancellationError() }
                        catch { issues.append(error.localizedDescription) }
                        count += 1
                    }
                    topology.coverage.append(ContextCoverage(source: history, sessionID: session.id, status: count == 0 ? .missing : (issues.isEmpty ? .complete : .partial), records: count, bytes: bytes, issues: issues + ["rollout 누락·불완전 시 대체 기록입니다. 두 소스는 중복될 수 있습니다."]))
                } catch is CancellationError { throw CancellationError() }
                catch { topology.coverage.append(ContextCoverage(source: history, sessionID: session.id, status: .error, issues: [error.localizedDescription])) }
            }
            for (index, callID) in pendingResults {
                if let toolID = callTools[callID], let callIndex = callNodes[callID] {
                    topology.nodes[index].parentID = toolID
                    topology.edges.append(ContextEdge(source: topology.nodes[callIndex].id, target: topology.nodes[index].id, relation: "결과"))
                }
            }
            var directory = URL(fileURLWithPath: session.cwd).standardizedFileURL
            while !session.cwd.isEmpty {
                let file = directory.appendingPathComponent("AGENTS.md")
                if FileManager.default.fileExists(atPath: file.path), instructionPaths.insert(file.path).inserted {
                    do {
                        let raw = try Data(contentsOf: file); let text = String(decoding: raw, as: UTF8.self)
                        topology.nodes.append(ContextNode(id: "instruction:" + file.path, parentID: rootID, kind: .instruction, title: file.path, summary: "현재 디스크의 지침 — 과거 입력 여부는 별도", fullText: String(text.prefix(1400)), source: file.path, sessionID: session.id, bodyReference: ContextBodyReference(path: file.path, offset: 0, length: raw.count, fingerprint: Self.fingerprint(raw)), charCount: text.count))
                        topology.coverage.append(ContextCoverage(source: file.path, sessionID: session.id, status: .complete, records: 1, bytes: raw.count))
                    } catch { topology.coverage.append(ContextCoverage(source: file.path, sessionID: session.id, status: .error, issues: [error.localizedDescription])) }
                }
                if instructionPaths.contains(file.path) { topology.edges.append(ContextEdge(source: rootID, target: "instruction:" + file.path, relation: "현재 상위 경로 지침")) }
                let parent = directory.deletingLastPathComponent(); if parent.path == directory.path { break }; directory = parent
            }
        }
        var toolTotals: [String: (calls: Int, chars: Int)] = [:]
        var groupTotals: [String: (records: Int, chars: Int)] = [:]
        for node in topology.nodes where node.recordCount > 0 && node.kind != .tool && node.kind != .group {
            if let parent = node.parentID {
                let old = toolTotals[parent] ?? (0, 0)
                toolTotals[parent] = (old.calls + (node.kind == .toolCall ? node.recordCount : 0), old.chars + node.charCount)
            }
            if let sessionID = node.sessionID {
                let category = "session:" + sessionID + ":group:" + node.kind.rawValue
                if groupKinds[category] == node.kind {
                    let old = groupTotals[category] ?? (0, 0)
                    groupTotals[category] = (old.records + node.recordCount, old.chars + node.charCount)
                }
            }
        }
        for index in topology.nodes.indices {
            if topology.nodes[index].kind == .tool {
                let total = toolTotals[topology.nodes[index].id] ?? (0, 0)
                topology.nodes[index].recordCount = total.calls; topology.nodes[index].charCount = total.chars
            } else if topology.nodes[index].kind == .group {
                let total = groupTotals[topology.nodes[index].id] ?? (0, 0)
                topology.nodes[index].recordCount = total.records; topology.nodes[index].charCount = total.chars
            }
        }
        return topology
    }
    private func appendInstructions(paths: [String], parentID: String, sessionID: String?, topology: inout ContextTopology) {
        var seen = Set(topology.nodes.filter { $0.kind == .instruction }.map(\.id))
        for path in paths where !path.isEmpty {
            var directory = URL(fileURLWithPath: path).standardizedFileURL
            while true {
                let file = directory.appendingPathComponent("AGENTS.md"); let id = "instruction:" + file.path
                if FileManager.default.fileExists(atPath: file.path) {
                    if seen.insert(id).inserted {
                        do {
                            let raw = try Data(contentsOf: file); let text = String(decoding: raw, as: UTF8.self)
                            topology.nodes.append(ContextNode(id: id, parentID: parentID, kind: .instruction, title: file.path, summary: "현재 디스크의 지침 — 과거 입력 여부는 별도", fullText: String(text.prefix(1400)), source: file.path, sessionID: sessionID, bodyReference: ContextBodyReference(path: file.path, offset: 0, length: raw.count, fingerprint: Self.fingerprint(raw)), charCount: text.count))
                            topology.coverage.append(ContextCoverage(source: file.path, sessionID: sessionID, status: .complete, records: 1, bytes: raw.count))
                        } catch { topology.coverage.append(ContextCoverage(source: file.path, sessionID: sessionID, status: .error, issues: [error.localizedDescription])) }
                    }
                    topology.edges.append(ContextEdge(source: parentID, target: id, relation: "현재 상위 경로 지침"))
                }
                let parent = directory.deletingLastPathComponent(); if parent.path == directory.path { break }; directory = parent
            }
        }
    }
    private func stateRecord(_ id: String) throws -> [String: String]? {
        let files = try FileManager.default.contentsOfDirectory(at: home, includingPropertiesForKeys: nil)
        guard let state = files.filter({ $0.lastPathComponent.hasPrefix("state_") && $0.pathExtension == "sqlite" }).sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending }).first else { return nil }
        let db = try ReadOnlyDatabase(url: state)
        let columns = Set(try db.rows("PRAGMA table_info(threads)").compactMap { $0["name"] })
        let fields = ["id", "title", "name", "cwd", "model", "reasoning_effort", "model_provider", "updated_at", "created_at", "tokens_used", "source", "rollout_path", "cli_version", "archived", "git_branch", "project_id"].filter { columns.contains($0) }
        guard columns.contains("id"), !fields.isEmpty else { throw MaestroError.message("세션 메타데이터 형식이 변경되었습니다.") }
        return try db.rows("SELECT " + fields.joined(separator: ",") + " FROM threads WHERE id=?", bindings: [id]).first
    }
    private static func lines(path: String, consume: (Data, UInt64) throws -> Void) throws {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path)); defer { try? handle.close() }
        var buffer = Data(); var offset: UInt64 = 0
        while let chunk = try handle.read(upToCount: 65536), !chunk.isEmpty {
            try Task.checkCancellation(); buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<newline]); if !line.isEmpty { try consume(line, offset) }
                let consumed = buffer.distance(from: buffer.startIndex, to: newline) + 1; buffer.removeFirst(consumed); offset += UInt64(consumed)
            }
        }
        if !buffer.isEmpty { try consume(buffer, offset) }
    }
    private static func history(path: String, sessionID: String, consume: (Data, String) throws -> Void) throws {
        var db: OpaquePointer?; guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else { sqlite3_close(db); throw MaestroError.message("대체 기록 데이터베이스를 열 수 없습니다.") }; defer { sqlite3_close(db) }
        var statement: OpaquePointer?; guard sqlite3_prepare_v2(db, "SELECT item_id,item_json FROM thread_items WHERE thread_id=? ORDER BY rollout_ordinal", -1, &statement, nil) == SQLITE_OK else { throw MaestroError.message("대체 기록 형식을 읽을 수 없습니다.") }; defer { sqlite3_finalize(statement) }
        _ = sessionID.withCString { sqlite3_bind_text(statement, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        while true {
            try Task.checkCancellation(); let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }; guard status == SQLITE_ROW else { throw MaestroError.message("대체 기록 조회 실패") }
            guard let key = sqlite3_column_text(statement, 0), let raw = sqlite3_column_text(statement, 1) else { continue }
            try consume(Data(String(cString: raw).utf8), String(cString: key))
        }
    }
    private static func kind(type: String, outer: String, role: String) -> ContextNodeKind {
        if type == "reasoning" { return .metadata }
        if type.contains("compac") || outer.contains("compac") { return .compaction }
        if type.hasSuffix("_begin") || type == "function_call" || type == "custom_tool_call" || type == "mcpToolCall" || type == "commandExecution" || type == "collabAgentToolCall" { return .toolCall }
        if type.hasSuffix("_end") || type.contains("output") || type == "function_call_output" { return .toolResult }
        if type == "fileChange" { return .file }
        if outer == "turn_context" || role == "system" || role == "developer" || type.contains("instruction") { return .instruction }
        if type == "token_count" || type == "token_usage_record" { return .usage }
        if !role.isEmpty || type == "userMessage" || type == "agentMessage" || type == "user_message" || type == "agent_message" { return .message }
        return .metadata
    }
    private static func sanitize(_ value: Any) -> Any {
        if let dict = value as? [String: Any] {
            let type = dict["type"] as? String ?? ""
            if (type.lowercased().contains("reasoning") && !type.lowercased().contains("summary")) || dict["channel"] as? String == "analysis" {
                return ["type": type, "summary": sanitize(dict["summary"] ?? []), "boundary": "내부 reasoning 본문과 암호화 payload는 표시하지 않습니다."]
            }
            var clean: [String: Any] = [:]
            for (key, val) in dict where !["encrypted_content", "encryptedContent", "raw_reasoning", "reasoning_content", "reasoningText", "reasoning_text"].contains(key) { clean[key] = sanitize(val) }
            return clean
        }
        if let array = value as? [Any] { return array.map(sanitize) }
        return value
    }
    private static func pretty(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return String(describing: value) }
        return String(decoding: data, as: UTF8.self)
    }
    private static func fingerprint(_ data: Data) -> String { var hash: UInt64 = 14695981039346656037; for byte in data { hash = (hash ^ UInt64(byte)) &* 1099511628211 }; return String(hash, radix: 16) }
    /// Only recognized telemetry records and schema fields become measured usage.
    /// Token-like tool arguments/results are ordinary evidence, not token measurements.
    private static func usageMetrics(_ payload: [String: Any], prefix: String) -> [String: Int64] {
        let measuredKeys: Set<String> = ["input_tokens", "cached_input_tokens", "output_tokens", "reasoning_output_tokens", "total_tokens", "model_context_window", "context_window", "context_window_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"]
        var result: [String: Int64] = [:]
        func read(_ dictionary: [String: Any], path: String) {
            for key in measuredKeys {
                guard let number = dictionary[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { continue }
                result[path.isEmpty ? key : path + "." + key] = number.int64Value
            }
        }
        func nestedPath(_ suffix: String) -> String { prefix.isEmpty ? suffix : prefix + "." + suffix }
        read(payload, path: prefix)
        if let info = payload["info"] as? [String: Any] {
            read(info, path: nestedPath("info"))
            for key in ["last_token_usage", "total_token_usage"] {
                if let usage = info[key] as? [String: Any] { read(usage, path: nestedPath("info." + key)) }
            }
        }
        if let usage = payload["usage"] as? [String: Any] {
            read(usage, path: nestedPath("usage"))
            for key in ["last_token_usage", "total_token_usage"] {
                if let nested = usage[key] as? [String: Any] { read(nested, path: nestedPath("usage." + key)) }
            }
        }
        return result
    }
    /// A single lexical pass; path-segment regexes backtrack badly on large tool output.
    private static func references(_ text: String) -> [(ContextNodeKind, String)] {
        let bytes = Array(text.utf8)
        let skillSuffix = Array("/SKILL.md".utf8); let pluginPrefix = Array("plugin://".utf8)
        var result: [(ContextNodeKind, String)] = []; var seen = Set<String>()
        func add(_ kind: ContextNodeKind, _ start: Int, _ end: Int) {
            guard start < end else { return }
            let value = String(decoding: bytes[start..<end], as: UTF8.self)
            if seen.insert(kind.rawValue + ":" + value).inserted { result.append((kind, value)) }
        }
        func boundary(_ byte: UInt8) -> Bool {
            if byte <= 32 { return true }
            switch byte { case 34, 39, 60, 62, 96, 40, 41, 91, 92, 93, 123, 125, 44, 59: return true; default: return false }
        }
        func hardBoundary(_ byte: UInt8) -> Bool { boundary(byte) && byte != 32 }
        func asciiAlphanumeric(_ byte: UInt8) -> Bool { (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) }
        var tokenStart = 0; var absoluteStart: Int?
        func token(_ start: Int, _ end: Int) {
            guard start < end else { return }
            let slice = bytes[start..<end]
            if slice.starts(with: pluginPrefix) { add(.plugin, start, end); return }
            guard bytes[start] == 47 else { return }
            var fileEnd = end
            if let colon = slice.firstIndex(of: 58) {
                var pieces = 1; var hasDigit = false; var valid = true
                for byte in bytes[(colon + 1)..<end] {
                    if (48...57).contains(byte) { hasDigit = true }
                    else if byte == 58, hasDigit, pieces == 1 { pieces += 1; hasDigit = false }
                    else { valid = false; break }
                }
                if valid && hasDigit { fileEnd = colon }
            }
            if bytes[start..<fileEnd].suffix(skillSuffix.count).elementsEqual(skillSuffix) { add(.skill, start, fileEnd) }
            var slashCount = 0; var dot: Int?
            for index in start..<fileEnd { if bytes[index] == 47 { slashCount += 1; dot = nil } else if bytes[index] == 46 { dot = index } }
            if slashCount >= 2, let dot, (1...8).contains(fileEnd - dot - 1), bytes[(dot + 1)..<fileEnd].allSatisfy(asciiAlphanumeric) { add(.file, start, fileEnd) }
        }
        for index in bytes.indices {
            if index < tokenStart { continue }
            let byte = bytes[index]
            if byte == 92, index + 1 < bytes.count, [110, 114, 116].contains(bytes[index + 1]) {
                token(tokenStart, index); tokenStart = index + 2; absoluteStart = nil; continue
            }
            if hardBoundary(byte) { absoluteStart = nil }
            if byte == 47, (index == tokenStart || index == 0 || boundary(bytes[index - 1])) { absoluteStart = index }
            if byte == 47, let start = absoluteStart, bytes[index...].starts(with: skillSuffix) {
                let end = index + skillSuffix.count
                if end == bytes.count || boundary(bytes[end]) { add(.skill, start, end) }
            }
            if boundary(byte) { token(tokenStart, index); tokenStart = index + 1 }
        }
        token(tokenStart, bytes.count)
        return result
    }
    public static func demo(endpoint: LinkEndpoint) -> ContextTopology {
        let session = Session(id: endpoint.kind == .session ? endpoint.id : "demo-context-session", title: "기록 예시", projectID: endpoint.kind == .project ? endpoint.id : nil, cwd: "/demo", model: "데모")
        let root = ContextNode(id: "session:" + session.id, kind: .session, title: session.title, fullText: "데모 데이터입니다. 실제 Codex 기록을 읽지 않았습니다.", source: "demo", sessionID: session.id)
        let group = ContextNode(id: "demo-tools", parentID: root.id, kind: .group, title: "관찰된 도구", source: "demo")
        let tool = ContextNode(id: "demo-call", parentID: group.id, kind: .toolCall, title: "exec_command", summary: "swift test", fullText: "swift test\n예시 기록 — 실제 실행 근거가 아닙니다.", source: "demo", recordCount: 1)
        return ContextTopology(scope: endpoint, title: "기록 컨텍스트 예시", nodes: [root, group, tool], edges: [ContextEdge(source: root.id, target: group.id, relation: "기록"), ContextEdge(source: group.id, target: tool.id, relation: "호출")], coverage: [ContextCoverage(source: "demo", status: .complete, records: 1)], sessions: [session])
    }
}
