import XCTest
import Foundation
import Darwin
@testable import MaestroCore

final class StalledPeerTests: XCTestCase {
    @MainActor func testBackpressuredPromptDoesNotBlockMainActorAndDisconnectUnblocksWriter() async throws {
        let peer = try StalledDesktopPeer()
        defer { peer.stop() }
        let bridge = DesktopBridge()
        try await bridge.connect(socketPath: peer.path)
        let started = ContinuousClock.now
        let promptTask = Task { @MainActor () -> Bool in
            do {
                try await bridge.sendPrompt(threadID: "fixture-thread", prompt: String(repeating: "x", count: 4 * 1024 * 1024))
                return false
            } catch { return true }
        }
        try await Task.sleep(for: .milliseconds(150))
        let heartbeatDelay = started.duration(to: .now)
        XCTAssertLessThan(heartbeatDelay, .milliseconds(1500), "A stalled IPC writer must not block the MainActor heartbeat")
        XCTAssertTrue(peer.ownerAnswered, "Fixture must complete owner discovery before stalling")
        let disconnected = ContinuousClock.now
        bridge.disconnect()
        let rejected = await promptTask.value
        XCTAssertTrue(rejected, "Disconnected backpressured send must fail instead of reporting acceptance")
        XCTAssertLessThan(disconnected.duration(to: .now), .seconds(1), "Disconnect must release a queued or active writer promptly")
        XCTAssertFalse(bridge.isConnected)
        print("IPC_BACKPRESSURE heartbeat=\(heartbeatDelay); disconnect=\(disconnected.duration(to: .now)); fixture prompt never accepted")
    }
}

/// Answers initialization and owner discovery, then stops draining the socket.
/// A watchdog closes the peer after three seconds so regressions fail without hanging the suite.
private final class StalledDesktopPeer: @unchecked Sendable {
    let path: String
    private let listener: Int32
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var connection: Int32 = -1
    private var stopped = false
    private var answered = false
    var ownerAnswered: Bool { lock.lock(); defer { lock.unlock() }; return answered }
    init() throws {
        path = "/tmp/maestro-stall-\(UUID().uuidString.prefix(8)).sock"
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw MaestroError.message("Fixture socket failed") }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString).map { UInt8(bitPattern: $0) }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard bound == 0, listen(listener, 1) == 0 else { Darwin.close(listener); unlink(path); throw MaestroError.message("Fixture listen failed") }
        DispatchQueue.global(qos: .utility).async { [self] in run() }
    }
    private func run() {
        let fd = accept(listener, nil, nil)
        guard fd >= 0 else { return }
        lock.lock(); connection = fd; let alreadyStopped = stopped; lock.unlock()
        defer { lock.lock(); connection = -1; Darwin.close(fd); lock.unlock() }
        guard !alreadyStopped else { return }
        var one: Int32 = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var receiveBuffer: Int32 = 4096; setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &receiveBuffer, socklen_t(MemoryLayout<Int32>.size))
        var decoder = IPCFrameDecoder(); var bytes = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = Darwin.read(fd, &bytes, bytes.count)
            guard count > 0, let messages = try? decoder.append(Data(bytes.prefix(count))) else { return }
            for message in messages {
                let method = message["method"] as? String ?? ""
                guard method == "initialize" || method == "thread-owner-discovery" else { continue }
                let result: [String: Any] = method == "initialize" ? ["clientId": "fixture-client"] : ["supportsUntrustedAppInput": true]
                let response: [String: Any] = ["type": "response", "requestId": message["requestId"] ?? "", "resultType": "success", "method": method, "handledByClientId": "fixture-owner", "result": result]
                guard let data = try? IPCFrameDecoder.encode(response) else { return }
                let sent = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
                guard sent == data.count else { return }
                if method == "thread-owner-discovery" {
                    lock.lock(); answered = true; lock.unlock()
                    _ = release.wait(timeout: .now() + 3)
                    shutdown(fd, SHUT_RDWR)
                    return
                }
            }
        }
    }
    func stop() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        if connection >= 0 { shutdown(connection, SHUT_RDWR) }
        lock.unlock()
        release.signal(); shutdown(listener, SHUT_RDWR); Darwin.close(listener); unlink(path)
    }
}
