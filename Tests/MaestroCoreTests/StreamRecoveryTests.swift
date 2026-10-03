import XCTest
import Foundation
import Darwin
@testable import MaestroCore

final class StreamRecoveryTests: XCTestCase {
    @MainActor func testMalformedRevisionAndIndexedPatchInvalidateAndResubscribe() async throws {
        for malformed in [
            ["type": "patches", "baseRevision": 1, "patches": []] as [String: Any],
            ["type": "patches", "baseRevision": 1, "revision": 1, "patches": []],
            ["type": "patches", "baseRevision": 1, "revision": 2, "patches": [["op": "remove", "path": ["threadRuntimeStatus", "activeFlags", 9]]]],
            ["type": "future-stream-shape", "revision": 2]
        ] {
            let server = try RecoveryDesktop(change: malformed)
            defer { server.stop() }
            let bridge = DesktopBridge()
            let recovered = expectation(description: "invalidated then fresh snapshot")
            var invalidated = false
            bridge.onSnapshot = { id, state in
                guard id == "test-thread" else { return }
                if state.owner.isEmpty { invalidated = true }
                if invalidated && state.owner == "owner" && state.revision == 3 { recovered.fulfill() }
            }
            try await bridge.connect(socketPath: server.path)
            try bridge.follow(["test-thread"])
            await fulfillment(of: [recovered], timeout: 2)
            XCTAssertTrue(invalidated)
            bridge.disconnect()
        }
    }
}

/// Socket peer for recovery verification; never connects to the user's desktop endpoint.
private final class RecoveryDesktop: @unchecked Sendable {
    let path = "/tmp/maestro-recovery-\(UUID().uuidString.prefix(8)).sock"
    private let listener: Int32
    private let lock = NSLock()
    private var connection: Int32 = -1
    private let change: [String: Any]

    init(change: [String: Any]) throws {
        self.change = change
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.utf8CString.map { UInt8(bitPattern: $0) }) }
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard result == 0, listen(listener, 1) == 0 else { Darwin.close(listener); unlink(path); throw MaestroError.message("Recovery fixture socket failed") }
        DispatchQueue.global().async { [self] in run() }
    }

    private func run() {
        let fd = accept(listener, nil, nil)
        guard fd >= 0 else { return }
        lock.lock(); connection = fd; lock.unlock()
        defer { lock.lock(); connection = -1; lock.unlock(); Darwin.close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var decoder = IPCFrameDecoder(), bytes = [UInt8](repeating: 0, count: 8192)
        var subscriptions = 0
        while true {
            let count = read(fd, &bytes, bytes.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0, let messages = try? decoder.append(Data(bytes.prefix(count))) else { return }
            for message in messages {
                if message["method"] as? String == "initialize" {
                    send(["type": "response", "requestId": message["requestId"] ?? "", "resultType": "success", "result": ["clientId": "recovery-client"]], fd: fd)
                } else if message["method"] as? String == "thread-stream-following-changed" {
                    guard (message["params"] as? [String: Any])?["following"] as? Bool == true else { continue }
                    subscriptions += 1
                    let snapshot: [String: Any] = ["type": "snapshot", "revision": subscriptions == 1 ? 1 : 3, "conversationState": ["threadRuntimeStatus": ["type": "idle"]]]
                    broadcast(snapshot, fd: fd)
                    if subscriptions == 1 { broadcast(change, fd: fd) }
                }
            }
        }
    }

    private func broadcast(_ change: [String: Any], fd: Int32) {
        send(["type": "broadcast", "method": "thread-stream-state-changed", "version": 11, "sourceClientId": "owner", "params": ["hostId": "local", "conversationId": "test-thread", "change": change]], fd: fd)
    }
    private func send(_ object: [String: Any], fd: Int32) {
        guard let data = try? IPCFrameDecoder.encode(object) else { return }
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return }
                offset += count
            }
        }
    }
    func stop() {
        lock.lock(); if connection >= 0 { shutdown(connection, SHUT_RDWR) }; lock.unlock()
        shutdown(listener, SHUT_RDWR); Darwin.close(listener); unlink(path)
    }
}
