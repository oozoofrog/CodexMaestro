import Foundation
import Darwin

/// The desktop coordination protocol is private. Keep all versioned wire details here.
/// No app-server resume fallback: it could create a competing owner for the same thread.
@MainActor
public final class DesktopBridge {
    public var onSnapshot: ((String, LiveSession) -> Void)?
    public var onDisconnect: ((String) -> Void)?
    public var onActivity: ((String, String) -> Void)?
    public private(set) var isConnected = false
    private var transport: UnixTransport?
    private var clientID = "initializing-client"
    private var pending: [String: CheckedContinuation<[String: Any], Error>] = [:]
    private var timeouts: [String: Task<Void, Never>] = [:]
    private var followed: Set<String> = []
    private var live: [String: LiveSession] = [:]
    private var incompatibleThreads: Set<String> = []
    private var generation = UUID()
    public init() {}

    public func connect(socketPath: String) async throws {
        disconnect()
        let generation = UUID(); self.generation = generation
        let transport = try UnixTransport(path: socketPath)
        self.transport = transport
        transport.start { [weak self] message in
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                self.receive(message)
            }
        } onClose: { [weak self] error in
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                self.disconnect(reason: error)
            }
        }
        do {
            let response = try await request("initialize", params: ["clientType": "codex-maestro"], version: 0)
            guard let result = response["result"] as? [String: Any], let id = result["clientId"] as? String else { throw MaestroError.message("Codex IPC 초기화 응답이 호환되지 않습니다.") }
            clientID = id; isConnected = true
        } catch { disconnect(); throw error }
    }
    public func disconnect(reason: String? = nil) {
        generation = UUID()
        transport?.close(); transport = nil
        isConnected = false; clientID = "initializing-client"; followed.removeAll(); live.removeAll(); incompatibleThreads.removeAll()
        let requests = pending; pending.removeAll()
        timeouts.values.forEach { $0.cancel() }; timeouts.removeAll()
        for continuation in requests.values { continuation.resume(throwing: MaestroError.message(reason ?? "Codex 연결이 종료되었습니다.")) }
        if let reason { onDisconnect?(reason) }
    }
    public func follow(_ ids: [String], refresh: Bool = false) throws {
        guard isConnected else { return }
        let wanted = Set(ids)
        for id in followed.subtracting(wanted) { try broadcastFollowing(id, following: false); live[id] = nil }
        for id in wanted where refresh || !followed.contains(id) { try broadcastFollowing(id, following: true) }
        followed = wanted
    }
    private func broadcastFollowing(_ id: String, following: Bool) throws {
        try transport?.send([
            "type": "broadcast", "method": "thread-stream-following-changed", "version": 1,
            "sourceClientId": clientID,
            "params": ["hostId": "local", "conversationId": id, "following": following]
        ])
    }
    public func discoverOwner(threadID: String) async throws -> String {
        let response = try await request("thread-owner-discovery", params: ["hostId": "local", "conversationId": threadID], version: 1)
        guard let owner = response["handledByClientId"] as? String, !owner.isEmpty else { throw MaestroError.message("세션 소유자를 확인할 수 없습니다.") }
        return owner
    }
    public static func turnParameters(threadID: String, prompt: String, messageID: String) -> [String: Any] {
        ["conversationId": threadID, "turnStart": [
            "request": ["threadId": threadID, "input": [["type": "text", "text": prompt, "text_elements": []]], "clientUserMessageId": messageID],
            "context": ["inheritThreadSettings": true]
        ]]
    }
    /// Exactly one request, never an automatic retry after an uncertain outcome.
    @discardableResult
    public func sendPrompt(threadID: String, prompt: String, messageID: String = UUID().uuidString) async throws -> String {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MaestroError.message("프롬프트를 입력하세요.") }
        guard isConnected else { throw MaestroError.message("Codex에 연결되어 있지 않습니다.") }
        let owner = try await discoverOwner(threadID: threadID)
        let response = try await request("thread-follower-start-turn", params: Self.turnParameters(threadID: threadID, prompt: prompt, messageID: messageID), version: 2, target: owner, timeout: 30)
        let result = response["result"] as? [String: Any]
        let accepted = result?["result"] as? [String: Any]
        guard let turn = accepted?["turn"] as? [String: Any], let id = turn["id"] as? String, !id.isEmpty else {
            throw MaestroError.message("Codex 응답에서 전송 수락을 확인하지 못했습니다. 원래 세션을 확인한 뒤 재전송하세요.")
        }
        return id
    }
    private func request(_ method: String, params: [String: Any], version: Int, target: String? = nil, timeout: Double = 5) async throws -> [String: Any] {
        guard let transport else { throw MaestroError.message("Codex 연결이 없습니다.") }
        let id = UUID().uuidString
        var message: [String: Any] = ["type": "request", "requestId": id, "sourceClientId": clientID, "method": method, "params": params, "version": version, "timeoutMs": Int(timeout * 1000)]
        if let target { message["targetClientId"] = target }
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            timeouts[id] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard !Task.isCancelled, let self, let pending = self.pending.removeValue(forKey: id) else { return }
                self.timeouts[id] = nil
                let detail = method == "thread-follower-start-turn" ? "전달 결과가 아직 확인되지 않았습니다. Codex의 원래 세션을 확인한 뒤 재전송하세요." : "Codex 요청 시간이 초과되었습니다."
                pending.resume(throwing: MaestroError.message(detail))
                // Stop queued or partial frames from being delivered after their request timed out.
                self.disconnect(reason: detail)
            }
            do { try transport.send(message, timeout: timeout) }
            catch { pending[id] = nil; timeouts.removeValue(forKey: id)?.cancel(); continuation.resume(throwing: error) }
        }
    }
    private func receive(_ message: [String: Any]) {
        switch message["type"] as? String {
        case "response":
            guard let id = message["requestId"] as? String, let continuation = pending.removeValue(forKey: id) else { return }
            timeouts.removeValue(forKey: id)?.cancel()
            if message["resultType"] as? String == "success" { continuation.resume(returning: message) }
            else {
                let code = message["error"] as? String ?? "알 수 없는 IPC 오류"
                let description = code == "no-client-found" ? "이 세션이 Codex에서 열려 있지 않습니다. ‘Codex에서 열기’ 후 다시 전송하세요." : "Codex: \(code)"
                continuation.resume(throwing: MaestroError.message(description))
            }
        case "client-discovery-request":
            // Maestro never claims ownership of other clients' requests.
            if let id = message["requestId"] as? String { try? transport?.send(["type": "client-discovery-response", "requestId": id, "response": ["canHandle": false]]) }
        case "request":
            if let id = message["requestId"] as? String { try? transport?.send(["type": "response", "requestId": id, "resultType": "error", "error": "no-handler-for-request"]) }
        case "broadcast": receiveBroadcast(message)
        default: break
        }
    }
    private func receiveBroadcast(_ message: [String: Any]) {
        if let targets = message["targetClientIds"] as? [String], !targets.contains(clientID) { return }
        guard let params = message["params"] as? [String: Any] else { return }
        let method = message["method"] as? String
        if method == "thread-stream-following-status-requested",
           params["hostId"] as? String == "local",
           let id = params["conversationId"] as? String, followed.contains(id) {
            try? broadcastFollowing(id, following: true)
            return
        }
        if method == "client-status-changed", params["status"] as? String == "disconnected", let owner = params["clientId"] as? String {
            for (id, state) in live where state.owner == owner { live[id] = nil; onSnapshot?(id, .unavailable) }
            return
        }
        guard method == "thread-stream-state-changed", let id = params["conversationId"] as? String, followed.contains(id), params["hostId"] as? String == "local" else { return }
        guard message["version"] as? Int == 11 else {
            live[id] = nil; onSnapshot?(id, .unavailable)
            if incompatibleThreads.insert(id).inserted { onActivity?(id, "Codex 상태 프로토콜 버전이 호환되지 않습니다.") }
            return
        }
        guard let change = params["change"] as? [String: Any], let owner = message["sourceClientId"] as? String, !owner.isEmpty else {
            live[id] = nil; onSnapshot?(id, .unavailable); try? broadcastFollowing(id, following: true); return
        }
        if change["type"] as? String == "snapshot", let state = change["conversationState"] as? [String: Any],
           let revision = change["revision"] as? Int, revision >= 0 {
            incompatibleThreads.remove(id)
            let summary = LiveSession(snapshot: state, owner: owner, revision: revision)
            live[id] = summary; onSnapshot?(id, summary)
        } else if change["type"] as? String == "patches", var summary = live[id] {
            guard summary.owner == owner, summary.revision == change["baseRevision"] as? Int,
                  let revision = change["revision"] as? Int, revision > summary.revision,
                  let patches = change["patches"] as? [[String: Any]], summary.apply(patches: patches) else {
                live[id] = nil; onSnapshot?(id, .unavailable); try? broadcastFollowing(id, following: true); return
            }
            summary.revision = revision
            live[id] = summary; onSnapshot?(id, summary)
        } else {
            // Unknown change shape must not leave a stale status looking live.
            live[id] = nil; onSnapshot?(id, .unavailable); try? broadcastFollowing(id, following: true)
        }
    }
}

public struct LiveSession: Sendable {
    public var status: SessionStatus
    public var model: String?
    public var effort: String?
    public var title: String?
    public var parentID: String?
    public var owner: String
    public var revision: Int
    public var observedAt: Date
    private var runtimeType: String
    private var activeFlags: [String]
    public static var unavailable: Self { .init(snapshot: [:], owner: "", revision: 0) }
    public init(snapshot: [String: Any], owner: String, revision: Int) {
        let runtime = snapshot["threadRuntimeStatus"] as? [String: Any]
        runtimeType = runtime?["type"] as? String ?? "notLoaded"
        activeFlags = runtime?["activeFlags"] as? [String] ?? []
        status = SessionStatus.parse(runtime); model = snapshot["latestModel"] as? String
        effort = snapshot["latestReasoningEffort"] as? String; title = snapshot["title"] as? String
        parentID = snapshot["forkedFromId"] as? String
        self.owner = owner; self.revision = revision; observedAt = Date()
    }
    /// Apply the displayed projection transactionally. Invalid relevant patches need a fresh snapshot.
    @discardableResult
    public mutating func apply(patches: [[String: Any]]) -> Bool {
        var next = self
        for patch in patches {
            guard let path = patch["path"] as? [Any], let root = path.first as? String,
                  let op = patch["op"] as? String, ["add", "replace", "remove"].contains(op) else { return false }
            let value = op == "remove" ? nil : patch["value"]
            switch root {
            case "threadRuntimeStatus":
                if path.count == 1 {
                    guard op == "remove" || value is [String: Any] else { return false }
                    let runtime = value as? [String: Any]
                    next.runtimeType = runtime?["type"] as? String ?? "notLoaded"
                    next.activeFlags = runtime?["activeFlags"] as? [String] ?? []
                } else if path[1] as? String == "type" {
                    guard path.count == 2, op == "remove" || value is String else { return false }
                    next.runtimeType = value as? String ?? "notLoaded"
                } else if path[1] as? String == "activeFlags" {
                    if path.count == 2 {
                        guard op == "remove" || value is [String] else { return false }
                        next.activeFlags = value as? [String] ?? []
                    } else {
                        guard path.count == 3, let index = path[2] as? Int, index >= 0 else { return false }
                        switch op {
                        case "add":
                            guard index <= next.activeFlags.count, let flag = value as? String else { return false }
                            next.activeFlags.insert(flag, at: index)
                        case "replace":
                            guard next.activeFlags.indices.contains(index), let flag = value as? String else { return false }
                            next.activeFlags[index] = flag
                        default:
                            guard next.activeFlags.indices.contains(index) else { return false }
                            next.activeFlags.remove(at: index)
                        }
                    }
                }
            case "latestModel", "latestReasoningEffort", "title", "forkedFromId":
                guard path.count == 1, op == "remove" || value == nil || value is NSNull || value is String else { return false }
                switch root {
                case "latestModel": next.model = value as? String
                case "latestReasoningEffort": next.effort = value as? String
                case "title": next.title = value as? String
                default: next.parentID = value as? String
                }
            default: break
            }
        }
        next.status = SessionStatus.parse(["type": next.runtimeType, "activeFlags": next.activeFlags])
        next.observedAt = Date()
        self = next
        return true
    }

}

/// Each frame is a 32-bit little-endian byte count followed by UTF-8 JSON.
public struct IPCFrameDecoder {
    public static let maxFrameBytes = 268_435_456
    private var buffer = Data()
    public init() {}
    public mutating func append(_ data: Data) throws -> [[String: Any]] {
        buffer.append(data)
        var offset = 0
        var messages: [[String: Any]] = []
        while buffer.count - offset >= 4 {
            let size = Int(buffer[offset]) | Int(buffer[offset + 1]) << 8 | Int(buffer[offset + 2]) << 16 | Int(buffer[offset + 3]) << 24
            guard size > 0 && size <= Self.maxFrameBytes else { throw MaestroError.message("IPC 프레임 길이가 유효하지 않습니다.") }
            guard buffer.count - offset >= size + 4 else { break }
            let data = buffer.subdata(in: (offset + 4)..<(offset + 4 + size))
            guard let message = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw MaestroError.message("IPC 메시지가 객체가 아닙니다.") }
            messages.append(message); offset += 4 + size
        }
        if offset > 0 { buffer = Data(buffer.dropFirst(offset)) }
        return messages
    }
    public static func encode(_ message: [String: Any]) throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: message)
        guard data.count <= maxFrameBytes else { throw MaestroError.message("IPC 메시지가 너무 큽니다.") }
        var size = UInt32(data.count).littleEndian
        var frame = Data(bytes: &size, count: 4); frame.append(data); return frame
    }
}

private final class UnixTransport: @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()
    private let writeQueue = DispatchQueue(label: "CodexMaestro.IPC.write", qos: .utility)
    private var closed = false
    private var closeHandler: ((String) -> Void)?
    init(path: String) throws {
        var metadata = stat()
        guard lstat(path, &metadata) == 0, metadata.st_uid == getuid(), (metadata.st_mode & S_IFMT) == S_IFSOCK else { throw MaestroError.message("Codex 데스크톱 연결을 찾을 수 없습니다. Codex를 실행한 뒤 다시 연결하세요.") }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw MaestroError.message("IPC 소켓 생성에 실패했습니다.") }
        var initialized = false
        defer { if !initialized { Darwin.close(descriptor) } }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw MaestroError.message("IPC 경로가 너무 깁니다.") }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in raw.copyBytes(from: bytes.map { UInt8(bitPattern: $0) }) }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        var one: Int32 = 1; setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let result = withUnsafePointer(to: &address) { ptr in ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard result == 0 else { throw MaestroError.message("Codex IPC 연결 실패: \(String(cString: strerror(errno)))") }
        fd = descriptor; initialized = true
    }
    func start(onMessage: @escaping ([String: Any]) -> Void, onClose: @escaping (String) -> Void) {
        lock.lock(); closeHandler = onClose; lock.unlock()
        DispatchQueue.global(qos: .utility).async { [self] in
            var decoder = IPCFrameDecoder()
            var bytes = [UInt8](repeating: 0, count: 65536)
            while true {
                let count = Darwin.read(fd, &bytes, bytes.count)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { break }
                do { for message in try decoder.append(Data(bytes.prefix(count))) { onMessage(message) } }
                catch { fail(error.localizedDescription); return }
            }
            fail("Codex 데스크톱 연결이 종료되었습니다.")
        }
    }
    func send(_ message: [String: Any], timeout: Double = 5) throws {
        let data = try IPCFrameDecoder.encode(message)
        lock.lock(); let stopped = closed; lock.unlock()
        guard !stopped else { throw MaestroError.message("Codex IPC 연결이 종료되었습니다.") }
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(0.001, timeout) * 1_000_000_000)
        // Serialize frames off the main actor. A stalled peer must not block UI or request timeouts.
        writeQueue.async { [self] in
            do {
                try data.withUnsafeBytes { raw in
                    var offset = 0
                    while offset < raw.count {
                        lock.lock(); let stopped = closed; lock.unlock()
                        if stopped { return }
                        let now = DispatchTime.now().uptimeNanoseconds
                        guard now < deadline else { throw MaestroError.message("Codex IPC 쓰기 시간이 초과되었습니다.") }
                        let count = Darwin.send(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset, MSG_DONTWAIT)
                        if count > 0 { offset += count; continue }
                        if count < 0 && errno == EINTR { continue }
                        if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                            var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                            let remaining = Int32(min((deadline - now) / 1_000_000 + 1, UInt64(Int32.max)))
                            let ready = poll(&descriptor, 1, remaining)
                            if ready > 0 || (ready < 0 && errno == EINTR) { continue }
                            throw MaestroError.message(ready == 0 ? "Codex IPC 쓰기 시간이 초과되었습니다." : "Codex IPC 쓰기 대기 실패")
                        }
                        throw MaestroError.message("Codex IPC 쓰기 실패")
                    }
                }
            } catch { fail(error.localizedDescription) }
        }
    }
    private func fail(_ reason: String) {
        lock.lock()
        let handler = closed ? nil : closeHandler
        lock.unlock()
        close()
        handler?(reason)
    }
    func close() {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }; closed = true
        shutdown(fd, SHUT_RDWR)
    }
    deinit {
        // Reader and queued writer closures retain this object. Close the descriptor only after
        // both exit; reconnect must never reuse its number while old I/O is still in flight.
        close(); Darwin.close(fd)
    }
}
