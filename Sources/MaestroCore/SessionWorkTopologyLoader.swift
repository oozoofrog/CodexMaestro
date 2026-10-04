import Foundation
import CoreFoundation

/// A read-only, actor-isolated index of complete rollout records. Unchanged polls parse no records.
public actor SessionWorkTopologyLoader {
    public let home: URL
    private var caches: [String: WorkFileIndex] = [:]
    private var lastDiagnostics: [String: SessionWorkReadDiagnostics] = [:]

    public init(home: URL) { self.home = home }

    public func diagnostics(sessionID: String) -> SessionWorkReadDiagnostics? { lastDiagnostics[sessionID] }

    public func load(session: Session, catalog: [Session] = []) async throws -> SessionWorkTopology {
        try Task.checkCancellation()
        var metadataCoverage: [ContextCoverage] = []
        let path: String?
        do {
            path = try rolloutPath(sessionID: session.id)
            metadataCoverage.append(ContextCoverage(source: "Codex state database", sessionID: session.id, status: path == nil ? .missing : .complete, issues: path == nil ? ["rollout 경로가 없습니다."] : []))
        } catch {
            path = nil
            metadataCoverage.append(ContextCoverage(source: "Codex state database", sessionID: session.id, status: .error, issues: [error.localizedDescription]))
        }
        guard let path else {
            let coverage = metadataCoverage + [ContextCoverage(source: "rollout", sessionID: session.id, status: .missing, issues: ["공개 실행 기록을 확인할 수 없습니다."])]
            if let index = caches[session.id] { return index.topology(session: session, catalog: catalog, extraCoverage: coverage, stale: true) }
            return emptyTopology(session: session, catalog: catalog, coverage: coverage)
        }
        do {
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            defer { try? handle.close() }
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            let identity = Self.fileIdentity(attributes)
            let modificationDate = attributes[.modificationDate] as? Date
            var index = caches[session.id] ?? WorkFileIndex(sessionID: session.id, path: path, identity: identity)
            let sameSizeMutation = index.observedSize > 0 && size == index.observedSize && modificationDate != index.observedModificationDate
            let reset = index.path != path || index.identity != identity || size < index.observedSize || sameSizeMutation || !checkpointMatches(index, handle: handle)
            if reset {
                index = WorkFileIndex(sessionID: session.id, path: path, identity: identity, generation: index.generation + 1)
                index.issues.append("출처 파일이 교체·축소·수정되어 새 세대로 다시 읽었습니다.")
            }
            let paths = (try? agentPathMap(parentID: session.id)) ?? index.agentPathMap
            if paths != index.agentPathMap {
                index.agentPathMap = paths
                index.resolvePendingSessions()
            }
            let recordsBefore = index.records
            let startOffset = index.completeOffset
            try handle.seek(toOffset: startOffset)
            var buffer = Data()
            var readPosition = startOffset
            var lineOffset = startOffset
            var parsedSinceYield = 0
            while readPosition < size {
                try Task.checkCancellation()
                let bytes = try handle.read(upToCount: Int(min(256 * 1024, size - readPosition))) ?? Data()
                if bytes.isEmpty { break }
                readPosition += UInt64(bytes.count)
                buffer.append(bytes)
                var consumed = buffer.startIndex
                while let newline = buffer[consumed...].firstIndex(of: 10) {
                    var raw = Data(buffer[consumed..<newline])
                    let byteLength = raw.count + 1
                    if raw.last == 13 { raw.removeLast() }
                    if !raw.isEmpty { index.consume(raw: raw, offset: lineOffset) }
                    index.completeOffset = lineOffset + UInt64(byteLength)
                    lineOffset = index.completeOffset
                    consumed = buffer.index(after: newline)
                    parsedSinceYield += 1
                    if parsedSinceYield >= 128 {
                        // Yield while keeping the candidate index local. Cancellation never publishes a partial index.
                        await Task.yield()
                        try Task.checkCancellation()
                        parsedSinceYield = 0
                    }
                }
                if consumed != buffer.startIndex { buffer = Data(buffer[consumed...]) }
            }
            index.observedSize = size
            index.observedModificationDate = modificationDate
            index.pendingBytes = buffer.count
            index.headLength = Int(min(index.completeOffset, 4096))
            index.headFingerprint = try Self.fingerprintRange(handle, offset: 0, count: index.headLength)
            index.tailLength = Int(min(index.completeOffset, 4096))
            index.tailFingerprint = try Self.fingerprintRange(handle, offset: index.completeOffset - UInt64(index.tailLength), count: index.tailLength)
            let finalAttributes = try FileManager.default.attributesOfItem(atPath: path)
            let finalSize = (finalAttributes[.size] as? NSNumber)?.uint64Value ?? 0
            guard Self.fileIdentity(finalAttributes) == identity, finalSize >= size,
                  finalSize != size || (finalAttributes[.modificationDate] as? Date) == modificationDate else {
                throw MaestroError.message("기록을 읽는 동안 출처 파일이 변경되었습니다. 다음 갱신에서 새 세대를 확인합니다.")
            }
            try Task.checkCancellation()
            // Another load can reenter during a yield. A newer generation or longer snapshot wins.
            if let newer = caches[session.id], newer.generation > index.generation || (newer.generation == index.generation && newer.observedSize > index.observedSize) {
                return newer.topology(session: session, catalog: catalog, extraCoverage: metadataCoverage)
            }
            caches[session.id] = index
            lastDiagnostics[session.id] = SessionWorkReadDiagnostics(generation: index.generation, parsedRecords: index.records - recordsBefore, lastReadBytes: Int(readPosition - startOffset), totalParsedRecords: index.records, completeOffset: index.completeOffset)
            return index.topology(session: session, catalog: catalog, extraCoverage: metadataCoverage)
        } catch is CancellationError { throw CancellationError() }
        catch {
            let coverage = metadataCoverage + [ContextCoverage(source: path, sessionID: session.id, status: .error, issues: [error.localizedDescription, "현재 기록 상태는 미확인입니다."])]
            if let index = caches[session.id] { return index.topology(session: session, catalog: catalog, extraCoverage: coverage, stale: true) }
            return emptyTopology(session: session, catalog: catalog, coverage: coverage)
        }
    }

    public func loadBody(node: WorkNode) async throws -> String {
        try Task.checkCancellation()
        guard let reference = node.bodyReference else { return node.bodyPreview }
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: reference.path))
        defer { try? handle.close() }
        let attributes = try FileManager.default.attributesOfItem(atPath: reference.path)
        guard let index = caches[node.sessionID], index.path == reference.path,
              index.identity == Self.fileIdentity(attributes), checkpointMatches(index, handle: handle),
              !((attributes[.size] as? NSNumber)?.uint64Value == index.observedSize && (attributes[.modificationDate] as? Date) != index.observedModificationDate),
              reference.fingerprint.hasPrefix(index.referencePrefix) else {
            throw MaestroError.message("기록의 출처 세대가 변경되었습니다. 다시 불러오세요.")
        }
        try handle.seek(toOffset: reference.offset)
        let raw = try handle.read(upToCount: reference.length) ?? Data()
        guard raw.count == reference.length, index.referencePrefix + WorkRecordSupport.fingerprint(raw) == reference.fingerprint else {
            throw MaestroError.message("기록 내용이 변경되었습니다. 다시 불러오세요.")
        }
        try Task.checkCancellation()
        guard let json = try? JSONSerialization.jsonObject(with: raw) else { return "해석할 수 없는 JSON 기록입니다. 원문 위치와 fingerprint를 보존했습니다." }
        return WorkRecordSupport.pretty(WorkRecordSupport.sanitize(json))
    }

    private func rolloutPath(sessionID: String) throws -> String? {
        let files = try FileManager.default.contentsOfDirectory(at: home, includingPropertiesForKeys: nil)
        guard let state = files.filter({ $0.lastPathComponent.hasPrefix("state_") && $0.pathExtension == "sqlite" }).sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending }).first else { return nil }
        let db = try ReadOnlyDatabase(url: state)
        let columns = Set(try db.rows("PRAGMA table_info(threads)").compactMap { $0["name"] })
        guard columns.contains("id"), columns.contains("rollout_path") else { return nil }
        guard let path = try db.rows("SELECT rollout_path FROM threads WHERE id=?", bindings: [sessionID]).first?["rollout_path"], !path.isEmpty else { return nil }
        return path.hasPrefix("/") ? path : home.appendingPathComponent(path).path
    }
    private func agentPathMap(parentID: String) throws -> [String: String] {
        let files = try FileManager.default.contentsOfDirectory(at: home, includingPropertiesForKeys: nil)
        guard let state = files.filter({ $0.lastPathComponent.hasPrefix("state_") && $0.pathExtension == "sqlite" }).sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending }).first else { return [:] }
        let db = try ReadOnlyDatabase(url: state)
        guard try db.rows("PRAGMA table_info(threads)").contains(where: { $0["name"] == "source" }) else { return [:] }
        var result: [String: String] = [:]
        for row in try db.rows("SELECT id,source FROM threads WHERE source LIKE ?", bindings: ["%thread_spawn%"]) {
            guard let id = row["id"], let data = row["source"]?.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let sub = (json["subagent"] ?? json["subAgent"]) as? [String: Any], let spawn = sub["thread_spawn"] as? [String: Any], spawn["parent_thread_id"] as? String == parentID, let path = spawn["agent_path"] as? String else { continue }
            result[path] = id
        }
        return result
    }
    private func checkpointMatches(_ index: WorkFileIndex, handle: FileHandle) -> Bool {
        guard index.completeOffset > 0 else { return true }
        return (try? Self.fingerprintRange(handle, offset: 0, count: index.headLength)) == index.headFingerprint &&
            (try? Self.fingerprintRange(handle, offset: index.completeOffset - UInt64(index.tailLength), count: index.tailLength)) == index.tailFingerprint
    }
    private static func fingerprintRange(_ handle: FileHandle, offset: UInt64, count: Int) throws -> String {
        try handle.seek(toOffset: offset)
        return WorkRecordSupport.fingerprint(try handle.read(upToCount: count) ?? Data())
    }
    private static func fileIdentity(_ attributes: [FileAttributeKey: Any]) -> String {
        "\((attributes[.systemNumber] as? NSNumber)?.uint64Value ?? 0):\((attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0)"
    }
    private func emptyTopology(session: Session, catalog: [Session], coverage: [ContextCoverage]) -> SessionWorkTopology {
        WorkFileIndex(sessionID: session.id, path: "", identity: "").topology(session: session, catalog: catalog, extraCoverage: coverage)
    }
}

private struct WorkFileIndex {
    let sessionID: String
    let path: String
    let identity: String
    let generation: Int
    var completeOffset: UInt64 = 0
    var observedSize: UInt64 = 0
    var observedModificationDate: Date?
    var pendingBytes = 0
    var records = 0
    var headLength = 0
    var headFingerprint = ""
    var tailLength = 0
    var tailFingerprint = ""
    var issues: [String] = []
    var nodes: [WorkNode] = []
    var nodeIndices: [String: Int] = [:]
    var edges: [WorkRelation] = []
    var edgeIDs: Set<String> = []
    var turns: [WorkTurn] = []
    var turnIndices: [String: Int] = [:]
    var usage: [WorkUsage] = []
    var usageIDs: Set<String> = []
    var callNodes: [String: String] = [:]
    var resultNodes: [String: [String]] = [:]
    var agentPathMap: [String: String] = [:]
    var pendingSessionRelations: [String: (target: String, kind: WorkRelationKind, source: String)] = [:]
    var activeTurnID: String?
    var lastKnownTurnID: String?
    var unresolvedStartBoundary = false
    var lastRecordedNodeID: String?
    var cumulativeSegment = 0
    var previousCumulative: (input: Int64?, output: Int64?)?
    var nativeCumulative: [String: (input: Int64?, output: Int64?, segment: Int)] = [:]
    var referencePrefix: String { "\(identity)|\(generation)|" }

    init(sessionID: String, path: String, identity: String, generation: Int = 0) {
        self.sessionID = sessionID; self.path = path; self.identity = identity; self.generation = generation
    }
    mutating func consume(raw: Data, offset: UInt64) {
        records += 1
        let ref = ContextBodyReference(path: path, offset: offset, length: raw.count, fingerprint: referencePrefix + WorkRecordSupport.fingerprint(raw), sessionID: sessionID)
        guard let json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            issues.append("완결된 JSONL 기록 #\(records)을 해석할 수 없습니다.")
            append(WorkNode(id: recordID(offset), sessionID: sessionID, kind: .other, title: "해석할 수 없는 기록", summary: "원문 위치를 보존했습니다.", bodyPreview: "해석할 수 없는 JSON 기록", bodyReference: ref, source: "\(path) #\(records)"))
            return
        }
        let payload = json["payload"] as? [String: Any] ?? json
        let outerType = json["type"] as? String ?? ""
        let eventType = payload["type"] as? String ?? outerType
        let nested = payload["item"] as? [String: Any]
        let item = nested ?? payload
        let type = item["type"] as? String ?? eventType
        let key = WorkRecordSupport.normalized(type)
        let explicitTurn = WorkRecordSupport.string(item, keys: ["turn_id", "turnId"]) ?? WorkRecordSupport.string(payload, keys: ["turn_id", "turnId"]) ?? (item["metadata"] as? [String: Any])?["turn_id"] as? String ?? (item["internal_chat_message_metadata_passthrough"] as? [String: Any])?["turn_id"] as? String
        let timestamp = WorkRecordSupport.date(json["timestamp"] ?? payload["timestamp"] ?? item["timestamp"])
        let source = "\(path) #\(records), 세대 \(generation)"
        let safe = WorkRecordSupport.sanitize(json)
        // Avoid serializing a large public body merely to construct a bounded preview.
        let preview = WorkRecordSupport.pretty(WorkRecordSupport.previewValue(safe, remaining: 1800))
        var nodePreview = String(preview.prefix(1800))

        if key == "taskstarted" || key == "turnstarted" {
            if let explicitTurn {
                unresolvedStartBoundary = false
                activeTurnID = explicitTurn
                lastKnownTurnID = explicitTurn
                ensureTurn(explicitTurn, timestamp: timestamp)
                turns[turnIndices[explicitTurn]!].status = .running
                turns[turnIndices[explicitTurn]!].startedAt = timestamp
            } else {
                activeTurnID = nil; unresolvedStartBoundary = true
                issues.append("시작 기록 #\(records)에 turn ID가 없습니다. 현재 turn과 이후 구간 소속은 미확인입니다.")
            }
        }
        if unresolvedStartBoundary, let explicitTurn, key == "turncontext" || key == "usermessage" || (key == "message" && item["role"] as? String == "user") {
            activeTurnID = explicitTurn; lastKnownTurnID = explicitTurn; unresolvedStartBoundary = false
        }
        var turnID = explicitTurn ?? activeTurnID
        let receivingTurnID = turnID
        let callID = WorkRecordSupport.string(item, keys: ["call_id", "callId"])
        let nativeID = WorkRecordSupport.string(item, keys: ["id", "item_id", "itemId"]) ?? WorkRecordSupport.string(payload, keys: ["item_id", "itemId"])
        let role = item["role"] as? String ?? ""
        var kind: WorkNodeKind = .other
        var status: WorkStatus = .unknown
        var title = type
        var summary = nested == nil ? "공개 저장 기록" : "구조화된 native 항목"
        var id = nativeID.map { "item:\(sessionID):\($0)" } ?? recordID(offset)
        var linkageCallID: String? = callID
        var relatedSessionID: String?
        var targetPath: String?
        let isResult = ["functioncalloutput", "customtoolcalloutput", "toolresult", "mcpresult"].contains(key)
        let isCall = ["functioncall", "customtoolcall", "toolcall", "collabagenttoolcall", "collabtoolcall", "dynamictoolcall"].contains(key)
        let isNative = ["commandexecution", "mcptoolcall", "collabtoolcall", "dynamictoolcall"].contains(key)
        let nativeCompleted = WorkRecordSupport.normalized(eventType) == "itemcompleted" || WorkRecordSupport.normalized(item["status"] as? String ?? "") == "completed"
        let nativeReceipt = isNative && WorkRecordSupport.hasResult(item, completed: nativeCompleted)
        if isResult {
            kind = .toolResult
            title = "호출 결과 · " + (callID ?? nativeID ?? "ID 미확인")
            status = WorkRecordSupport.outcome(item) ?? .unknown
            if let callID, let callNodeID = callNodes[callID], let index = nodeIndices[callNodeID] { turnID = nodes[index].turnID }
            if nativeID == nil, let callID { id = "result:\(sessionID):\(callID):\(WorkRecordSupport.resultFingerprint(item))" }
            summary = "반환 수신 · " + (WorkRecordSupport.outcome(item)?.label ?? "성공 여부 미확인")
        } else if isCall || isNative {
            kind = key == "commandexecution" ? .command : key == "mcptoolcall" ? .mcp : .toolCall
            linkageCallID = callID ?? nativeID
            // Direct response item IDs (fc_...) identify a representation. The transport call_id
            // can exactly equal the native item's ID; both aliases must resolve to one execution.
            let stableID = isNative ? nativeID ?? callID : callID ?? nativeID
            let existingAlias = stableID.flatMap { callNodes[$0] } ?? nativeID.flatMap { callNodes[$0] } ?? callID.flatMap { callNodes[$0] }
            if let existingAlias { id = existingAlias }
            else if let stableID { id = "call:\(sessionID):\(stableID)" }
            if callID == nil, let existing = nodeIndices[id] { linkageCallID = nodes[existing].callID ?? linkageCallID }
            if let existing = nodeIndices[id], let originalTurn = nodes[existing].turnID { turnID = originalTurn }
            if kind == .command {
                title = WorkRecordSupport.text(item["command"]).map { String($0.prefix(110)) } ?? "명령 실행"
            } else if kind == .mcp {
                title = [WorkRecordSupport.string(item, keys: ["server", "server_name", "serverName"]), WorkRecordSupport.string(item, keys: ["tool", "tool_name", "toolName"])].compactMap { $0 }.joined(separator: ".")
                if title.isEmpty { title = "MCP 실행" }
            } else {
                let name = WorkRecordSupport.string(item, keys: ["name", "tool", "tool_name", "toolName"]) ?? "도구 호출"
                let namespace = item["namespace"] as? String
                title = namespace.map { $0 + "." + name } ?? name
            }
            let rawStatus = WorkRecordSupport.string(item, keys: ["status"]) ?? ""
            status = WorkRecordSupport.activeStatus(rawStatus) ?? .waiting
            summary = "호출 확인 · 결과 미수신"
            if nativeReceipt {
                status = WorkRecordSupport.outcome(item) ?? .ended
                summary = "반환 수신 · " + (WorkRecordSupport.outcome(item)?.label ?? "성공 여부 미확인")
            } else if rawStatus.lowercased() == "completed" { summary = "native 상태 completed · 결과 미수신 · 성공 여부 미확인" }
            if WorkRecordSupport.isWaitingTool(title) { kind = .waiting; summary = "명시된 입력 요청 · 제출·승인 결과는 별도"; status = .waiting }
            if let arguments = WorkRecordSupport.arguments(item) {
                relatedSessionID = WorkRecordSupport.string(arguments, keys: ["thread_id", "threadId", "agent_id"])
                if relatedSessionID == nil, let target = arguments["target"] as? String {
                    targetPath = target
                    relatedSessionID = agentPathMap[target]
                }
                if relatedSessionID == nil, title.lowercased().contains("spawn") { relatedSessionID = WorkRecordSupport.string(item, keys: ["child_thread_id", "childSessionId"]) }
            }
        } else if (key == "message" && role == "user") || key == "usermessage" {
            kind = .prompt; title = "사용자 프롬프트"
            status = .ended
            let text = WorkRecordSupport.messageText(item)
            summary = String(text.prefix(220))
            nodePreview = String(text.prefix(1800))
        } else if (key == "message" && (role == "system" || role == "developer")) || key == "turncontext" {
            kind = .instruction; title = key == "turncontext" ? "저장된 turn 컨텍스트" : "\(role) 지침"
        } else if (key == "message" && role == "assistant") || key == "agentmessage" || key == "assistantmessage" {
            // A private analysis channel is retained as metadata, without extracting its text.
            if (item["channel"] as? String)?.lowercased() == "analysis" || (item["phase"] as? String)?.lowercased() == "analysis" {
                kind = .other; title = "비공개 채널 메타데이터"; summary = "본문을 표시하지 않습니다."
            } else {
                kind = .message; title = (item["channel"] as? String) == "final" || WorkRecordSupport.normalized(item["phase"] as? String ?? "") == "finalanswer" ? "공개 최종 응답" : "공개 진행 보고"
                status = .ended
                summary = String(WorkRecordSupport.messageText(item).prefix(220))
                nodePreview = String(WorkRecordSupport.messageText(item).prefix(1800))
            }
        } else if key == "tokencount" || key == "tokenusagerecord" {
            kind = .usage; title = "직접 기록한 토큰 계측"
        } else if key.contains("compact") {
            kind = .compaction; title = "컨텍스트 압축 기록"; summary = "압축 기록 존재 · 현재 점유율과 내부 입력은 미확인"
        } else if key == "reasoning" || key.contains("reasoning") {
            title = "비공개 reasoning 메타데이터"; summary = "본문·암호화 payload를 표시하지 않습니다."
        } else if key == "taskcomplete" || key == "turncompleted" {
            title = "turn 응답 종료"; status = .ended; summary = "응답 종료 기록 · 목표 충족 여부는 별도"
        } else if key == "turnaborted" || key == "taskcancelled" {
            title = "turn 중단"; status = .cancelled
        } else if key == "taskstarted" || key == "turnstarted" {
            title = "turn 시작 기록"; summary = "기록된 시작 · 현재 실행 여부는 IPC와 별도"
        } else if key == "sessionmeta" {
            title = "세션 메타데이터"
        } else if key == "interagentcommunicationmetadata" {
            title = "세션 간 통신 메타데이터"; summary = "기록된 메타데이터 · 메시지 전달·소비 여부는 별도"
        } else if key == "filechange" {
            kind = .artifact; title = "파일 변경 기록"; summary = "저장된 변경·diff · 현재 파일·hash 검증은 별도"
            status = WorkRecordSupport.outcome(item) ?? WorkRecordSupport.activeStatus(item["status"] as? String ?? "") ?? .ended
        } else if key == "imageview" {
            kind = .artifact; title = "이미지 읽기 참조"; summary = "저장된 이미지 경로 · 이미지 내용·사용자 결과 검증은 별도"; status = .ended
        } else if key.contains("waiting") || key.contains("approval") || key == "requestuserinput" {
            kind = .waiting; status = .waiting; title = "명시된 입력·승인 대기"
        } else { issues.append("알 수 없는 타입 \(type) #\(records)을 보존했습니다.") }

        let usageOwner = WorkRecordSupport.string(item, keys: ["thread_id", "threadId", "session_id"]) ?? sessionID
        if kind == .usage && usageOwner != sessionID {
            turnID = nil
            summary = "직접 기록한 토큰 계측 · 소유자 \(usageOwner) · 선택 세션 합계와 별도"
        }
        if let turnID { ensureTurn(turnID, timestamp: nil) }
        let attribution = (isResult || isCall || isNative) && receivingTurnID != nil && receivingTurnID != turnID ? "call_id/native ID로 원래 호출 turn에 연결 · 수신 turn은 별도" : explicitTurn != nil ? "직접 turn ID" : turnID != nil ? "task 시작·종료 구간" : "turn 소속 미확인"
        let node = WorkNode(id: id, sessionID: sessionID, turnID: turnID, kind: kind, title: title, summary: summary, bodyPreview: nodePreview, status: status, timestamp: timestamp, callID: linkageCallID, relatedSessionID: relatedSessionID, bodyReference: ref, source: source + " · " + attribution, statusHistory: [WorkStatusObservation(timestamp: timestamp, status: status, recordOrdinal: records, summary: summary, bodyPreview: nodePreview, bodyReference: ref)])
        append(node)
        if let turnID {
            relate(source: id, target: turnNodeID(turnID), kind: .belongsToTurn, evidence: source + " · " + attribution)
            if kind == .prompt { turns[turnIndices[turnID]!].promptNodeID = id }
            if key == "turncontext" {
                if let model = item["model"] as? String { turns[turnIndices[turnID]!].model = model }
                if let effort = WorkRecordSupport.string(item, keys: ["effort", "reasoning_effort"]) { turns[turnIndices[turnID]!].effort = effort }
            }
        }
        if isCall || isNative {
            if let linkageCallID {
                callNodes[linkageCallID] = id
                if let nativeID { callNodes[nativeID] = id }
                let pending = Set((resultNodes[linkageCallID] ?? []) + (nativeID.flatMap { resultNodes[$0] } ?? []))
                for resultID in pending {
                    linkResult(resultID, callNodeID: id, evidence: "call_id/native item ID")
                    if let resultIndex = nodeIndices[resultID], let resultRef = nodes[resultIndex].bodyReference {
                        // The retained bounded preview may omit returned IDs. Read the original complete record only for this ID match.
                        if let rawResult = try? readRaw(resultRef), let resultJSON = try? JSONSerialization.jsonObject(with: rawResult) as? [String: Any] {
                            resolveDelegation(callNodeID: id, resultItem: resultJSON["payload"] as? [String: Any] ?? resultJSON, source: source)
                        }
                    }
                }
                if nativeReceipt {
                    let resultID = "native-result:\(sessionID):\(nativeID ?? linkageCallID)"
                    let resultStatus = WorkRecordSupport.outcome(item) ?? .unknown
                    let result = WorkNode(id: resultID, sessionID: sessionID, turnID: turnID, kind: .toolResult, title: "\(title) · 결과", summary: summary, bodyPreview: nodePreview, status: resultStatus, timestamp: timestamp, callID: linkageCallID, bodyReference: ref, source: source, statusHistory: [WorkStatusObservation(timestamp: timestamp, status: resultStatus, recordOrdinal: records, summary: summary, bodyPreview: nodePreview, bodyReference: ref)])
                    append(result)
                    resultNodes[linkageCallID, default: []].append(resultID)
                    linkResult(resultID, callNodeID: id, evidence: "native 항목의 명시된 exit_code/result/output")
                }
            }
            if let turnID { relate(source: turnNodeID(turnID), target: id, kind: .calls, evidence: attribution) }
        }
        if isResult, let callID {
            if !(resultNodes[callID] ?? []).contains(id) { resultNodes[callID, default: []].append(id) }
            if let callNodeID = callNodes[callID] {
                linkResult(id, callNodeID: callNodeID, evidence: "직접 call_id")
                resolveDelegation(callNodeID: callNodeID, resultItem: item, source: source)
            }
        }
        if isResult || isCall || isNative, let receivingTurnID, receivingTurnID != turnID {
            ensureTurn(receivingTurnID, timestamp: nil)
            let evidence = source + (explicitTurn != nil ? " · 결과·상태 갱신의 직접 turn_id" : " · 수신 기록의 task 시작·종료 구간")
            if nativeReceipt, let canonicalID = nativeID ?? linkageCallID {
                relate(source: "native-result:\(sessionID):\(canonicalID)", target: turnNodeID(receivingTurnID), kind: .receivedInTurn, evidence: evidence, observedAt: timestamp)
            } else {
                relate(source: id, target: turnNodeID(receivingTurnID), kind: .receivedInTurn, evidence: evidence, observedAt: timestamp)
            }
        }
        if key == "collabtoolcall" || key == "collabagenttoolcall" {
            if let childID = WorkRecordSupport.string(item, keys: ["newThreadId", "new_thread_id"]) {
                addRelatedSession(childID, turnID: turnID, sourceNodeID: id, kind: .spawnedSession, source: source + " · 명시된 newThreadId")
                if let index = nodeIndices[id] { nodes[index].relatedSessionID = childID }
            }
            if let recipient = WorkRecordSupport.string(item, keys: ["receiverThreadId", "receiver_thread_id"]), recipient != sessionID {
                addRelatedSession(recipient, turnID: turnID, sourceNodeID: id, kind: .sentToSession, source: source + " · 명시된 receiverThreadId · 소비 여부 미확인")
                if let index = nodeIndices[id] { nodes[index].relatedSessionID = recipient }
            }
            if let sender = WorkRecordSupport.string(item, keys: ["senderThreadId", "sender_thread_id"]), sender != sessionID {
                addRelatedSession(sender, turnID: turnID, sourceNodeID: id, kind: .reportedBy, source: source + " · 명시된 senderThreadId · 송신 주체 기록")
            }
        }
        if let relatedSessionID, !relatedSessionID.hasPrefix("/") {
            addRelatedSession(relatedSessionID, turnID: turnID, sourceNodeID: id, kind: .sentToSession, source: source)
        } else if let targetPath {
            queueSessionRelation(sourceNodeID: id, target: targetPath, kind: .sentToSession, source: source)
        }
        if key == "agentmessage" {
            if let author = item["author"] as? String {
                queueSessionRelation(sourceNodeID: id, target: author, kind: .reportedBy, source: source + " · 저장된 author/recipient · 소비 여부 미확인")
            }
            if let recipient = item["recipient"] as? String, agentPathMap[recipient] != nil {
                queueSessionRelation(sourceNodeID: id, target: recipient, kind: .sentToSession, source: source + " · 저장된 recipient · 전달·소비 여부는 별도")
            }
        }
        if key == "filechange" {
            for change in item["changes"] as? [[String: Any]] ?? [] {
                if let artifactPath = change["path"] as? String {
                    addArtifact(path: artifactPath, producerID: id, turnID: turnID, summary: "저장된 파일 변경 경로 · kind=\(WorkRecordSupport.text(change["kind"]) ?? "미확인") · 현재 파일·hash 미검증", preview: change["diff"] as? String ?? artifactPath, reference: ref, source: source)
                }
            }
        } else if key == "imageview", let artifactPath = item["path"] as? String {
            addArtifact(path: artifactPath, producerID: id, turnID: turnID, summary: "저장된 이미지 읽기 경로 · 내용·산출물 생성 미검증", preview: artifactPath, reference: ref, source: source)
        }
        if kind == .usage { appendUsage(payload: item, nodeID: id, turnID: explicitTurn, timestamp: timestamp, source: source) }
        if key == "taskcomplete" || key == "turncompleted" || key == "turnaborted" || key == "taskcancelled" {
            if let turnID, let index = turnIndices[turnID] {
                turns[index].status = status; turns[index].endedAt = timestamp
                if activeTurnID == turnID { activeTurnID = nil }
            }
        }
    }

    private func recordID(_ offset: UInt64) -> String { "record:\(sessionID):\(generation):\(offset)" }
    private func readRaw(_ reference: ContextBodyReference) throws -> Data {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: reference.path)); defer { try? handle.close() }
        try handle.seek(toOffset: reference.offset)
        let data = try handle.read(upToCount: reference.length) ?? Data()
        guard data.count == reference.length, referencePrefix + WorkRecordSupport.fingerprint(data) == reference.fingerprint else { throw MaestroError.message("연결 대상 기록이 변경되었습니다.") }
        return data
    }
    private func turnNodeID(_ turnID: String) -> String { "turn:\(sessionID):\(turnID)" }
    private mutating func ensureTurn(_ id: String, timestamp: Date?) {
        if turnIndices[id] == nil {
            turnIndices[id] = turns.count
            turns.append(WorkTurn(id: id, sessionID: sessionID, startedAt: timestamp))
        }
    }
    private mutating func append(_ node: WorkNode) {
        if let index = nodeIndices[node.id] {
            var updated = node
            if updated.turnID == nil { updated.turnID = nodes[index].turnID }
            updated.timestamp = nodes[index].timestamp ?? node.timestamp
            updated.statusHistory = nodes[index].statusHistory + node.statusHistory
            let preservesNative = node.kind == .toolCall && [WorkNodeKind.command, .mcp].contains(nodes[index].kind)
            if preservesNative {
                // Retain structured execution details while keeping the later direct record inspectable in history.
                updated.kind = nodes[index].kind; updated.title = nodes[index].title
                updated.bodyPreview = nodes[index].bodyPreview; updated.bodyReference = nodes[index].bodyReference
            }
            // A second representation cannot erase a stronger result already linked to the call.
            if [WorkNodeKind.toolCall, .command, .mcp].contains(node.kind), ![WorkStatus.succeeded, .failed, .cancelled].contains(node.status), preservesNative || [WorkStatus.succeeded, .failed, .cancelled].contains(nodes[index].status) {
                updated.status = nodes[index].status; updated.summary = nodes[index].summary
                updated.statusHistory = nodes[index].statusHistory + node.statusHistory.map {
                    WorkStatusObservation(timestamp: $0.timestamp, status: nodes[index].status, recordOrdinal: $0.recordOrdinal, summary: "이전 반환 근거 유지 · 새 기록: " + node.summary, bodyPreview: $0.bodyPreview, bodyReference: $0.bodyReference)
                }
            }
            updated.source = nodes[index].source + "\n갱신: " + node.source
            nodes[index] = updated
        } else {
            nodeIndices[node.id] = nodes.count; nodes.append(node)
            if let lastRecordedNodeID { relate(source: lastRecordedNodeID, target: node.id, kind: .recordedNext, evidence: "원문 기록 순서 · 의존성을 뜻하지 않습니다.") }
            lastRecordedNodeID = node.id
        }
    }
    private mutating func relate(source: String, target: String, kind: WorkRelationKind, evidence: String, observedAt: Date? = nil) {
        let sourceObservation = nodeIndices[source].flatMap { nodes[$0].statusHistory.last?.timestamp }
        let targetObservation = kind == .calls || kind == .observedUsage ? nodeIndices[target].flatMap { nodes[$0].statusHistory.last?.timestamp } : nil
        let edge = WorkRelation(source: source, target: target, kind: kind, evidence: evidence, observedAt: observedAt ?? sourceObservation ?? targetObservation)
        if edgeIDs.insert(edge.id).inserted { edges.append(edge) }
    }
    private mutating func linkResult(_ resultID: String, callNodeID: String, evidence: String) {
        guard let callIndex = nodeIndices[callNodeID], let resultIndex = nodeIndices[resultID] else { return }
        let originalTurn = nodes[resultIndex].turnID
        nodes[resultIndex].turnID = nodes[callIndex].turnID
        if originalTurn != nodes[resultIndex].turnID {
            if let originalTurn { relate(source: resultID, target: turnNodeID(originalTurn), kind: .receivedInTurn, evidence: "결과가 저장된 turn 구간 · 원래 호출 소속과 별도") }
            edges.removeAll { $0.source == resultID && $0.kind == .belongsToTurn }
            edgeIDs = Set(edges.map(\.id))
        }
        if let turnID = nodes[resultIndex].turnID {
            ensureTurn(turnID, timestamp: nil)
            relate(source: resultID, target: turnNodeID(turnID), kind: .belongsToTurn, evidence: "호출의 turn ID · 늦은 결과도 원래 호출에 귀속")
        }
        relate(source: resultID, target: callNodeID, kind: .resultOf, evidence: evidence)
        let resultStatus = nodes[resultIndex].status
        if resultStatus == .failed || resultStatus == .succeeded || resultStatus == .cancelled { nodes[callIndex].status = resultStatus }
        else if nodes[callIndex].status != .failed && nodes[callIndex].status != .succeeded { nodes[callIndex].status = .ended }
        nodes[callIndex].summary = "반환 수신 · " + ([WorkStatus.succeeded, .failed, .cancelled].contains(nodes[callIndex].status) ? nodes[callIndex].status.label : "성공 여부 미확인")
        let observation = nodes[resultIndex].statusHistory.last
        nodes[callIndex].statusHistory.append(WorkStatusObservation(timestamp: observation?.timestamp, status: nodes[callIndex].status, recordOrdinal: observation?.recordOrdinal ?? records, summary: nodes[callIndex].summary, bodyPreview: observation?.bodyPreview ?? nodes[resultIndex].bodyPreview, bodyReference: observation?.bodyReference ?? nodes[resultIndex].bodyReference))
    }
    private mutating func resolveDelegation(callNodeID: String, resultItem: [String: Any], source: String) {
        guard let callIndex = nodeIndices[callNodeID] else { return }
        let call = nodes[callIndex]
        let text = WorkRecordSupport.text(resultItem["output"]) ?? ""
        var result = resultItem["result"] as? [String: Any]
        if result == nil, let data = text.data(using: .utf8) { result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] }
        guard let result else { return }
        if call.title.lowercased().contains("spawn") {
            if let childID = WorkRecordSupport.string(result, keys: ["agent_id", "thread_id", "threadId", "child_thread_id"]) {
                nodes[callIndex].relatedSessionID = childID
                addRelatedSession(childID, turnID: call.turnID, sourceNodeID: callNodeID, kind: .spawnedSession, source: source + " · 도구 반환의 child ID")
            } else if let path = result["task_name"] as? String {
                queueSessionRelation(sourceNodeID: callNodeID, target: path, kind: .spawnedSession, source: source + " · 도구 반환의 task_name과 DB agent_path")
            }
        }
    }
    private mutating func queueSessionRelation(sourceNodeID: String, target: String, kind: WorkRelationKind, source: String) {
        guard let sourceIndex = nodeIndices[sourceNodeID] else { return }
        if let childID = agentPathMap[target] {
            nodes[sourceIndex].relatedSessionID = childID
            addRelatedSession(childID, turnID: nodes[sourceIndex].turnID, sourceNodeID: sourceNodeID, kind: kind, source: source)
            pendingSessionRelations.removeValue(forKey: sourceNodeID + kind.rawValue)
        } else if target.hasPrefix("/") && target != "/root" {
            pendingSessionRelations[sourceNodeID + kind.rawValue] = (target, kind, source)
            issues.append("대상 경로 \(target)의 세션 ID 미확인 · \(source)")
        }
    }
    mutating func resolvePendingSessions() {
        let pending = pendingSessionRelations
        for (key, value) in pending where agentPathMap[value.target] != nil {
            let sourceNodeID = String(key.dropLast(value.kind.rawValue.count))
            queueSessionRelation(sourceNodeID: sourceNodeID, target: value.target, kind: value.kind, source: value.source)
        }
    }
    private mutating func addRelatedSession(_ childID: String, turnID: String?, sourceNodeID: String, kind: WorkRelationKind, source: String) {
        let id = "subsession:\(sessionID):\(turnID ?? "unknown"):\(childID)"
        let observation = nodeIndices[sourceNodeID].flatMap { nodes[$0].statusHistory.last }
        let summary = "명시된 \(kind.label) · 현재 실행·보고 소비 여부는 별도"
        append(WorkNode(id: id, sessionID: sessionID, turnID: turnID, kind: .subsession, title: "하위 세션 \(childID)", summary: summary, bodyPreview: summary, timestamp: observation?.timestamp, relatedSessionID: childID, bodyReference: observation?.bodyReference, source: source, statusHistory: [WorkStatusObservation(timestamp: observation?.timestamp, status: .unknown, recordOrdinal: observation?.recordOrdinal, summary: summary, bodyPreview: summary, bodyReference: observation?.bodyReference)]))
        relate(source: sourceNodeID, target: id, kind: kind, evidence: source)
        if let turnID { relate(source: id, target: turnNodeID(turnID), kind: .belongsToTurn, evidence: "위임·메시지의 turn ID") }
    }
    private mutating func addArtifact(path: String, producerID: String, turnID: String?, summary: String, preview: String, reference: ContextBodyReference, source: String) {
        let id = producerID + ":artifact:" + WorkRecordSupport.fingerprint(Data(path.utf8))
        let observation = nodeIndices[producerID].flatMap { nodes[$0].statusHistory.last }
        let bodyPreview = String(preview.prefix(1800))
        append(WorkNode(id: id, sessionID: sessionID, turnID: turnID, kind: .artifact, title: path, summary: summary, bodyPreview: bodyPreview, timestamp: observation?.timestamp, bodyReference: reference, source: source + " · 기록된 경로 참조", statusHistory: [WorkStatusObservation(timestamp: observation?.timestamp, status: .unknown, recordOrdinal: observation?.recordOrdinal, summary: summary, bodyPreview: bodyPreview, bodyReference: reference)]))
        relate(source: producerID, target: id, kind: .referencesArtifact, evidence: source + " · 직접 path 필드")
        if let turnID { relate(source: id, target: turnNodeID(turnID), kind: .belongsToTurn, evidence: "변경·이미지 참조의 turn ID") }
    }

    private mutating func appendUsage(payload: [String: Any], nodeID: String, turnID: String?, timestamp: Date?, source: String) {
        let info = payload["info"] as? [String: Any] ?? payload
        let owner = WorkRecordSupport.string(payload, keys: ["thread_id", "threadId", "session_id"]) ?? sessionID
        let total = info["total_token_usage"] as? [String: Any]
        let last = info["last_token_usage"] as? [String: Any]
        let window = validatedToken(info["model_context_window"] ?? payload["model_context_window"], key: "model_context_window", source: source)
        let includesChildren = WorkRecordSupport.boolean(info["includes_subsessions"] ?? payload["includes_subsessions"])
        let nativeThread = info["thread_token_usage"] as? [String: Any]
        let nativeTurn = info["turn_token_usage"] as? [String: Any]
        if nativeThread != nil || nativeTurn != nil {
            let request = info["usage"] as? [String: Any]
            let requestInput = request.flatMap { validatedToken($0["input_tokens"], key: "usage.input_tokens", source: source) }
            if let nativeThread {
                let metrics = validatedMetrics(nativeThread, source: source + " · thread_token_usage")
                let segment = nativeCounterSegment(key: "thread:\(owner)", input: metrics.0, output: metrics.2)
                addUsage(WorkUsage(id: nodeID + ":thread", sessionID: owner, input: metrics.0, cachedInput: metrics.1, output: metrics.2, reasoningOutput: metrics.3, lastRequestInput: requestInput, modelContextWindow: window, timestamp: timestamp, source: source + " · thread_token_usage", scope: "세션 누적 · 직접 thread_token_usage · 세대 \(generation) · 구간 \(segment)", includesSubsessions: includesChildren), nodeID: nodeID)
            }
            if let nativeTurn {
                let metrics = validatedMetrics(nativeTurn, source: source + " · turn_token_usage")
                let segment = nativeCounterSegment(key: "turn:\(owner):\(turnID ?? "unknown")", input: metrics.0, output: metrics.2)
                addUsage(WorkUsage(id: nodeID + ":turn", sessionID: owner, turnID: turnID, input: metrics.0, cachedInput: metrics.1, output: metrics.2, reasoningOutput: metrics.3, lastRequestInput: requestInput, modelContextWindow: window, timestamp: timestamp, source: source + " · turn_token_usage", scope: turnID == nil ? "turn 누적 · ID 미확인 · 구간 \(segment)" : "명시된 turn 누적 · 직접 turn_token_usage · 구간 \(segment)", includesSubsessions: includesChildren), nodeID: nodeID)
            }
            if let request {
                let metrics = validatedMetrics(request, source: source + " · usage")
                addUsage(WorkUsage(id: nodeID + ":request", sessionID: owner, turnID: turnID, input: metrics.0, cachedInput: metrics.1, output: metrics.2, reasoningOutput: metrics.3, lastRequestInput: metrics.0, modelContextWindow: window, timestamp: timestamp, source: source + " · usage", scope: "마지막 요청 · 직접 usage · turn 합계 아님", includesSubsessions: includesChildren), nodeID: nodeID)
            }
            return
        }
        if let total {
            let metrics = validatedMetrics(total, source: source)
            if let previousCumulative, (metrics.0 != nil && previousCumulative.input != nil && metrics.0! < previousCumulative.input!) || (metrics.2 != nil && previousCumulative.output != nil && metrics.2! < previousCumulative.output!) {
                cumulativeSegment += 1; issues.append("누적 계측 감소: 새 계측 구간 \(cumulativeSegment)을 보존했습니다. 이전 값과 차감하지 않습니다.")
            }
            previousCumulative = (metrics.0, metrics.2)
            addUsage(WorkUsage(id: nodeID + ":total", sessionID: owner, input: metrics.0, cachedInput: metrics.1, output: metrics.2, reasoningOutput: metrics.3, lastRequestInput: last.flatMap { validatedToken($0["input_tokens"], key: "last_token_usage.input_tokens", source: source) }, modelContextWindow: window, timestamp: timestamp, source: source, scope: "세션 누적 · 세대 \(generation) · 구간 \(cumulativeSegment)", includesSubsessions: includesChildren), nodeID: nodeID)
        }
        if let last {
            let metrics = validatedMetrics(last, source: source)
            addUsage(WorkUsage(id: nodeID + ":last", sessionID: owner, turnID: turnID, input: metrics.0, cachedInput: metrics.1, output: metrics.2, reasoningOutput: metrics.3, lastRequestInput: metrics.0, modelContextWindow: window, timestamp: timestamp, source: source, scope: "마지막 요청 · turn 합계 아님", includesSubsessions: includesChildren), nodeID: nodeID)
        }
        if total == nil && last == nil {
            let values = info["usage"] as? [String: Any] ?? info
            let metrics = validatedMetrics(values, source: source)
            let explicitScope = info["scope"] as? String ?? payload["scope"] as? String
            let isTurn = explicitScope?.lowercased() == "turn" && turnID != nil
            addUsage(WorkUsage(id: nodeID + ":usage", sessionID: owner, turnID: isTurn ? turnID : nil, input: metrics.0, cachedInput: metrics.1, output: metrics.2, reasoningOutput: metrics.3, lastRequestInput: validatedToken(info["last_request_input_tokens"], key: "last_request_input_tokens", source: source), modelContextWindow: window, timestamp: timestamp, source: source, scope: isTurn ? "명시된 turn 계측" : "범위 미확인", includesSubsessions: includesChildren), nodeID: nodeID)
        }
    }
    private mutating func addUsage(_ value: WorkUsage, nodeID: String) {
        if usageIDs.insert(value.id).inserted { usage.append(value) }
        if let turnID = value.turnID, value.sessionID == sessionID { relate(source: turnNodeID(turnID), target: nodeID, kind: .observedUsage, evidence: value.scope) }
        else { relate(source: "session:\(sessionID)", target: nodeID, kind: .observedUsage, evidence: value.scope) }
    }
    private mutating func nativeCounterSegment(key: String, input: Int64?, output: Int64?) -> Int {
        let previous = nativeCumulative[key]
        var segment = previous?.segment ?? 0
        if let previous, (input != nil && previous.input != nil && input! < previous.input!) || (output != nil && previous.output != nil && output! < previous.output!) {
            segment += 1
            issues.append("누적 계측 감소: \(key) 새 구간 \(segment) · 이전 값과 차감하지 않습니다.")
        }
        nativeCumulative[key] = (input, output, segment)
        return segment
    }
    private mutating func validatedToken(_ value: Any?, key: String, source: String) -> Int64? {
        guard let value else { return nil }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let integer = Int64(number.stringValue), integer >= 0 else {
            issues.append("유효하지 않은 토큰 계측 \(key) · \(source)"); return nil
        }
        return integer
    }
    private mutating func validatedMetrics(_ values: [String: Any], source: String) -> (Int64?, Int64?, Int64?, Int64?) {
        let input = validatedToken(values["input_tokens"], key: "input_tokens", source: source)
        var cached = validatedToken(values["cached_input_tokens"], key: "cached_input_tokens", source: source)
        let output = validatedToken(values["output_tokens"], key: "output_tokens", source: source)
        var reasoning = validatedToken(values["reasoning_output_tokens"], key: "reasoning_output_tokens", source: source)
        if let input, let cachedValue = cached, cachedValue > input { cached = nil; issues.append("cached_input_tokens가 input_tokens를 초과합니다. · \(source)") }
        if let output, let reasoningValue = reasoning, reasoningValue > output { reasoning = nil; issues.append("reasoning_output_tokens가 output_tokens를 초과합니다. · \(source)") }
        return (input, cached, output, reasoning)
    }

    func topology(session: Session, catalog: [Session], extraCoverage: [ContextCoverage], stale: Bool = false) -> SessionWorkTopology {
        var resultNodes = nodes
        var resultEdges = edges
        let root = WorkNode(id: "session:\(sessionID)", sessionID: sessionID, kind: .session, title: session.title, summary: session.isLive ? "IPC 관찰 · \(session.status.label)" : "저장된 세션 · 현재 상태 미확인", status: session.isLive && !stale ? WorkRecordSupport.sessionStatus(session.status) : .unknown, timestamp: session.isLive ? session.updatedAt : nil, source: "Codex catalog / IPC")
        resultNodes.insert(root, at: 0)
        for turn in turns {
            var history = [WorkStatusObservation(timestamp: turn.startedAt, status: .running)]
            if turn.endedAt != nil { history.append(WorkStatusObservation(timestamp: turn.endedAt, status: turn.status)) }
            resultNodes.append(WorkNode(id: turnNodeID(turn.id), sessionID: sessionID, turnID: turn.id, kind: .session, title: "메인 세션 · \(turn.id)", summary: "기록 수명주기: \(turn.status.label) · 현재 실행은 IPC와 별도", status: stale ? .unknown : turn.status, timestamp: turn.startedAt, source: "rollout turn ID", statusHistory: history))
        }
        let currentTurn = unresolvedStartBoundary ? nil : activeTurnID ?? lastKnownTurnID ?? turns.last?.id
        for child in catalog where child.parentID == sessionID {
            for candidate in resultNodes.indices where resultNodes[candidate].kind == .subsession && resultNodes[candidate].relatedSessionID == child.id {
                    resultNodes[candidate].title = child.title
                    if resultNodes[candidate].turnID == activeTurnID, child.isLive, !stale {
                        let status = WorkRecordSupport.sessionStatus(child.status)
                        resultNodes[candidate].status = status
                        resultNodes[candidate].summary += " · 자식 IPC 관찰: \(child.status.label)"
                        resultNodes[candidate].source += "\n자식 IPC 상태"
                        resultNodes[candidate].statusHistory.append(WorkStatusObservation(timestamp: Date(), status: status, summary: resultNodes[candidate].summary))
                    }
            }
            if !resultNodes.contains(where: { $0.kind == .subsession && $0.relatedSessionID == child.id && $0.turnID == currentTurn && currentTurn != nil }) {
                let id = "historical-subsession:\(sessionID):\(child.id)"
                resultNodes.append(WorkNode(id: id, sessionID: sessionID, kind: .subsession, title: child.title, summary: "과거 하위 세션 · 현재 turn 참여 미확인", relatedSessionID: child.id, source: "Codex catalog parentID"))
                resultEdges.append(WorkRelation(source: root.id, target: id, kind: .historicalAssociation, evidence: "source.subagent.thread_spawn.parent_thread_id · 현재 위임을 뜻하지 않습니다."))
            }
        }
        var coverage = extraCoverage
        if !path.isEmpty {
            let boundary = ["비공개 reasoning·암호화 본문·기록되지 않은 실행은 표시하지 않습니다.", "하위 세션 포함 여부가 명시되지 않은 계측은 합산하지 않습니다."]
            let tail = pendingBytes > 0 ? ["마지막 줄 \(pendingBytes)바이트가 미완결입니다. 다음 갱신까지 보류했습니다."] : []
            coverage.append(ContextCoverage(source: path, sessionID: sessionID, status: stale ? .error : issues.isEmpty && pendingBytes == 0 ? .complete : .partial, records: records, bytes: Int(completeOffset), issues: issues + tail + boundary))
        }
        return SessionWorkTopology(sessionID: sessionID, title: session.title, nodes: resultNodes, edges: resultEdges, turns: turns, usage: usage, coverage: coverage, currentTurnID: currentTurn)
    }
}

private enum WorkRecordSupport {
    static func normalized(_ value: String) -> String { value.lowercased().filter { $0.isLetter || $0.isNumber } }
    static func string(_ value: [String: Any], keys: [String]) -> String? {
        keys.compactMap { value[$0] as? String }.first { !$0.isEmpty }
    }
    static func date(_ value: Any?) -> Date? {
        if let value = value as? String {
            let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions = [.withInternetDateTime]; return formatter.date(from: value)
        }
        if let value = value as? NSNumber { return Date(timeIntervalSince1970: value.doubleValue) }
        return nil
    }
    static func text(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? [String] { return value.joined(separator: " ") }
        return nil
    }
    static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
    static func messageText(_ item: [String: Any]) -> String {
        guard let safe = sanitize(item) as? [String: Any] else { return "" }
        return text(safe["text"]) ?? text(safe["message"]) ?? text(safe["content"]) ?? (safe["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: "\n") ?? ""
    }
    static func activeStatus(_ status: String) -> WorkStatus? {
        switch normalized(status) {
        case "inprogress", "running", "started": .running
        case "queued", "pending": .queued
        case "waiting", "waitingforinput", "waitingforapproval": .waiting
        case "cancelled", "canceled", "aborted": .cancelled
        case "failed", "error": .failed
        default: nil
        }
    }
    static func hasResult(_ item: [String: Any], completed: Bool) -> Bool {
        if ["exit_code", "exitCode", "error", "newThreadId", "new_thread_id"].contains(where: { item[$0] != nil && !(item[$0] is NSNull) }) || boolean(item["success"]) != nil { return true }
        return completed && ["result", "output", "aggregated_output"].contains { item[$0] != nil && !(item[$0] is NSNull) }
    }
    static func outcome(_ item: [String: Any]) -> WorkStatus? {
        if let success = boolean(item["success"]) { return success ? .succeeded : .failed }
        if let value = item["exit_code"] as? NSNumber ?? item["exitCode"] as? NSNumber { return value.intValue == 0 ? .succeeded : .failed }
        if let error = item["error"], !(error is NSNull) { return .failed }
        if let value = item["isError"] as? Bool { return value ? .failed : .succeeded }
        if let result = item["result"] as? [String: Any] { return outcome(result) }
        if let result = item["Ok"] as? [String: Any] { return outcome(result) }
        if let error = item["Err"], !(error is NSNull) { return .failed }
        if let value = item["output"] as? String, let data = value.data(using: .utf8), let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return outcome(result) }
        if let status = activeStatus(item["status"] as? String ?? ""), status == .failed || status == .cancelled { return status }
        return nil
    }
    static func arguments(_ item: [String: Any]) -> [String: Any]? {
        if let arguments = item["arguments"] as? [String: Any] { return arguments }
        if let raw = item["arguments"] as? String, let data = raw.data(using: .utf8) { return try? JSONSerialization.jsonObject(with: data) as? [String: Any] }
        return nil
    }
    static func isWaitingTool(_ name: String) -> Bool { let key = normalized(name); return key.contains("requestuserinput") || key.contains("approvalrequest") }
    static func sessionStatus(_ value: SessionStatus) -> WorkStatus {
        switch value { case .running: .running; case .waiting: .waiting; case .idle: .ended; case .error: .failed; case .unknown: .unknown }
    }
    static func fingerprint(_ data: Data) -> String {
        var hash: UInt64 = 14695981039346656037
        for byte in data { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return String(hash, radix: 16)
    }
    static func resultFingerprint(_ item: [String: Any]) -> String {
        var contents = item
        for key in ["type", "call_id", "callId", "timestamp", "turn_id", "turnId"] { contents.removeValue(forKey: key) }
        let raw = (try? JSONSerialization.data(withJSONObject: contents, options: [.sortedKeys])) ?? Data()
        return fingerprint(raw)
    }
    static func sanitize(_ value: Any) -> Any {
        if let dict = value as? [String: Any] {
            let type = normalized(dict["type"] as? String ?? "")
            if type.contains("reasoning") || type == "analysis" || (dict["channel"] as? String)?.lowercased() == "analysis" || (dict["phase"] as? String)?.lowercased() == "analysis" {
                return ["type": dict["type"] ?? "private", "id": dict["id"] ?? NSNull(), "boundary": "비공개 reasoning 본문과 암호화 payload를 표시하지 않습니다."] as [String: Any]
            }
            var result: [String: Any] = [:]
            for (key, value) in dict where !["encryptedcontent", "rawreasoning", "reasoningcontent", "reasoningtext", "reasoning", "analysis"].contains(normalized(key)) { result[key] = sanitize(value) }
            return result
        }
        if let array = value as? [Any] { return array.map(sanitize) }
        return value
    }
    static func previewValue(_ value: Any, remaining: Int) -> Any {
        if let text = value as? String { return String(text.prefix(max(remaining, 0))) + (text.count > remaining ? "…" : "") }
        if let dict = value as? [String: Any] {
            let budget = max(remaining / max(dict.count, 1), 60)
            return dict.mapValues { previewValue($0, remaining: budget) }
        }
        if let array = value as? [Any] { return Array(array.prefix(12)).map { previewValue($0, remaining: max(remaining / max(array.count, 1), 40)) } }
        return value
    }
    static func pretty(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]) else { return String(describing: value) }
        return String(decoding: data, as: UTF8.self)
    }
}
