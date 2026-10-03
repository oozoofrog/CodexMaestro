import XCTest
import Foundation
import Darwin
@testable import MaestroCore

final class DesktopBridgeTests: XCTestCase {
    @MainActor func testOwnerRoutedPromptAndLiveStatusRoundTrip() async throws {
        let server = try FakeDesktop()
        defer { server.stop() }
        let client = DesktopBridge()
        let observed = expectation(description: "live state")
        client.onSnapshot = { id, state in if id == "thread-a" && state.status == .running { observed.fulfill() } }
        try await client.connect(socketPath: server.path)
        try client.follow(["thread-a"])
        await fulfillment(of: [observed], timeout: 2)
        let acceptedTurn = try await client.sendPrompt(threadID: "thread-a", prompt: "실제 작업에 영향 없는 fixture prompt\n🐸", messageID: "msg-1")
        XCTAssertEqual(acceptedTurn, "accepted-turn")
        let messages = server.messages
        let turns = messages.filter { $0["method"] as? String == "thread-follower-start-turn" }
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns.first?["targetClientId"] as? String, "desktop-owner")
        XCTAssertEqual(turns.first?["version"] as? Int, 2)
        XCTAssertFalse(messages.contains { $0["method"] as? String == "thread/resume" })
        client.disconnect()
    }
    @MainActor func testMissingOwnerNeverStartsTurn() async throws {
        let server = try FakeDesktop(ownerAvailable: false)
        defer { server.stop() }
        let client = DesktopBridge()
        try await client.connect(socketPath: server.path)
        do { try await client.sendPrompt(threadID: "unopened", prompt: "do not send"); XCTFail("Expected owner failure") }
        catch { XCTAssertTrue(error.localizedDescription.contains("열려 있지")) }
        XCTAssertFalse(server.messages.contains { $0["method"] as? String == "thread-follower-start-turn" })
        client.disconnect()
    }
    @MainActor func testDisconnectedClientRejectsSend() async throws {
        let client = DesktopBridge()
        do { try await client.sendPrompt(threadID: "a", prompt: "test"); XCTFail("Expected disconnection") }
        catch { XCTAssertTrue(error.localizedDescription.contains("연결")) }
    }
    @MainActor func testDesktopPatchUpdatesRuntimeStatus() async throws {
        let server = try FakeDesktop(sendPatch: true)
        defer { server.stop() }
        let client = DesktopBridge()
        let observed = expectation(description: "waiting status from patch")
        client.onSnapshot = { id, state in
            if id == "thread-a" && state.status == .waiting && state.revision == 2 { observed.fulfill() }
        }
        try await client.connect(socketPath: server.path)
        try client.follow(["thread-a"])
        await fulfillment(of: [observed], timeout: 2)
        client.disconnect()
    }
}

private final class FakeDesktop: @unchecked Sendable {
    let path: String
    private let listener: Int32
    private var connection: Int32 = -1
    private let lock = NSLock()
    private var received: [[String: Any]] = []
    private let ownerAvailable: Bool
    private let sendPatch: Bool
    var messages: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return received }
    init(ownerAvailable: Bool = true, sendPatch: Bool = false) throws {
        self.ownerAvailable = ownerAvailable
        self.sendPatch = sendPatch
        path = "/tmp/maestro-test-\(UUID().uuidString.prefix(8)).sock"
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes.map { UInt8(bitPattern: $0) }) }
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard result == 0, listen(listener, 1) == 0 else { throw MaestroError.message("Fake socket failed") }
        DispatchQueue.global().async { [self] in run() }
    }
    private func run() {
        let fd = accept(listener, nil, nil)
        guard fd >= 0 else { return }
        lock.lock(); connection = fd; lock.unlock()
        var one: Int32 = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var decoder = IPCFrameDecoder(); var bytes = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = read(fd, &bytes, bytes.count)
            guard count > 0 else { break }
            guard let messages = try? decoder.append(Data(bytes.prefix(count))) else { break }
            for message in messages {
                lock.lock(); received.append(message); lock.unlock()
                let method = message["method"] as? String ?? ""
                var response: [String: Any] = ["type": "response", "requestId": message["requestId"] ?? "", "resultType": "success", "method": method, "handledByClientId": "desktop-owner"]
                switch method {
                case "initialize": response["result"] = ["clientId": "maestro-test"]
                case "thread-owner-discovery":
                    if !ownerAvailable { response["resultType"] = "error"; response["error"] = "no-client-found" }
                    else { response["result"] = ["supportsUntrustedAppInput": true] }
                case "thread-stream-following-changed":
                    response = ["type": "broadcast", "method": "thread-stream-state-changed", "version": 11, "sourceClientId": "desktop-owner", "params": ["hostId": "local", "conversationId": "thread-a", "change": ["type": "snapshot", "revision": 1, "conversationState": ["threadRuntimeStatus": ["type": "active", "activeFlags": []]]]]]
                case "thread-follower-start-turn": response["result"] = ["result": ["turn": ["id": "accepted-turn", "status": "inProgress"]]]
                default: continue
                }
                guard let wire = try? IPCFrameDecoder.encode(response) else { continue }
                _ = wire.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
                if method == "thread-stream-following-changed" && sendPatch {
                    let patch: [String: Any] = ["type": "broadcast", "method": "thread-stream-state-changed", "version": 11, "sourceClientId": "desktop-owner", "params": ["hostId": "local", "conversationId": "thread-a", "change": ["type": "patches", "baseRevision": 1, "revision": 2, "patches": [["op": "replace", "path": ["threadRuntimeStatus"], "value": ["type": "active", "activeFlags": ["waitingOnUserInput"]]]]]]]
                    if let data = try? IPCFrameDecoder.encode(patch) { _ = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) } }
                }
            }
        }
        Darwin.close(fd)
        lock.lock(); connection = -1; lock.unlock()
    }
    func stop() {
        lock.lock(); if connection >= 0 { shutdown(connection, SHUT_RDWR) }; lock.unlock()
        shutdown(listener, SHUT_RDWR); Darwin.close(listener); unlink(path)
    }
}
