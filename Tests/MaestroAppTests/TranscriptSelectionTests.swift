import XCTest
import MaestroCore
@testable import CodexMaestro

private actor TranscriptReadGate {
    let permittedIDs: Set<String>
    private var requests: [String: Int] = [:]
    private var pending: [String: CheckedContinuation<[TranscriptMessage], Error>] = [:]
    private var started: [String: [CheckedContinuation<Void, Never>]] = [:]

    init(permittedIDs: Set<String>) { self.permittedIDs = permittedIDs }

    func read(_ id: String) async throws -> [TranscriptMessage] {
        requests[id, default: 0] += 1
        guard permittedIDs.contains(id), pending[id] == nil else {
            return [TranscriptMessage(id: "unexpected", role: "assistant", text: "Unexpected read: \(id)")]
        }
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            let waiters = started.removeValue(forKey: id) ?? []
            waiters.forEach { $0.resume() }
        }
    }

    func waitForStart(_ id: String) async {
        if pending[id] != nil { return }
        await withCheckedContinuation { started[id, default: []].append($0) }
    }

    func count(_ id: String) -> Int { requests[id] ?? 0 }

    func complete(_ id: String) {
        pending.removeValue(forKey: id)?.resume(returning: [TranscriptMessage(id: id, role: "assistant", text: "Transcript \(id)")])
    }

    func fail(_ id: String) {
        pending.removeValue(forKey: id)?.resume(throwing: MaestroError.message("Read failed: \(id)"))
    }
}

final class TranscriptSelectionTests: XCTestCase {
    @MainActor private func store(gate: TranscriptReadGate) -> MaestroStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("transcript-test-\(UUID().uuidString)")
        let store = MaestroStore(persistence: WorkspacePersistence(url: directory.appendingPathComponent("workspace.json")),
            transcriptReader: { id in try await gate.read(id) })
        store.sessions = [Session(id: "a", title: "A", projectID: nil, cwd: ""), Session(id: "b", title: "B", projectID: nil, cwd: "")]
        return store
    }

    @MainActor func testSelectionImmediatelyClearsPreviousTranscriptAndError() {
        let store = store(gate: TranscriptReadGate(permittedIDs: []))
        store.selectSessionID("a")
        store.transcript = [TranscriptMessage(id: "a", role: "assistant", text: "Private A content")]
        store.transcriptError = "A error"
        store.transcriptLoading = true
        store.selectSessionID("b")
        XCTAssertEqual(store.selectedSessionID, "b")
        XCTAssertTrue(store.transcript.isEmpty)
        XCTAssertNil(store.transcriptError)
        XCTAssertFalse(store.transcriptLoading)
    }

    @MainActor func testBackgroundReadForUnselectedAIsRejectedWithoutInvalidatingB() async {
        let gate = TranscriptReadGate(permittedIDs: ["b"])
        let store = store(gate: gate)
        store.selectSessionID("b")
        let readB = Task { await store.loadTranscript("b") }
        await gate.waitForStart("b")
        XCTAssertTrue(store.transcriptLoading)
        await store.loadTranscript("a")
        let aReads = await gate.count("a")
        XCTAssertEqual(aReads, 0, "Reject an unselected session before calling its reader or changing generation")
        XCTAssertTrue(store.transcriptLoading, "Background A must not clear B's spinner")
        XCTAssertTrue(store.transcript.isEmpty)
        XCTAssertNil(store.transcriptError)
        await gate.complete("b")
        await readB.value
        XCTAssertEqual(store.transcript.map(\.text), ["Transcript b"])
        XCTAssertFalse(store.transcriptLoading)
    }

    @MainActor func testOldACompletionPreservesPendingBAndOnlyBPublishes() async {
        let gate = TranscriptReadGate(permittedIDs: ["a", "b"])
        let store = store(gate: gate)
        store.selectSessionID("a")
        let readA = Task { await store.loadTranscript("a") }
        await gate.waitForStart("a")
        store.selectSessionID("b")
        let readB = Task { await store.loadTranscript("b") }
        await gate.waitForStart("b")
        await gate.complete("a")
        await readA.value
        XCTAssertTrue(store.transcriptLoading)
        XCTAssertTrue(store.transcript.isEmpty, "A content must never appear under B's selection")
        XCTAssertNil(store.transcriptError)
        await gate.complete("b")
        await readB.value
        XCTAssertEqual(store.transcript.map(\.id), ["b"])
        XCTAssertFalse(store.transcriptLoading)
    }

    @MainActor func testOldAErrorDoesNotPublishUnderBOrClearBSpinner() async {
        let gate = TranscriptReadGate(permittedIDs: ["a", "b"])
        let store = store(gate: gate)
        store.selectSessionID("a")
        let readA = Task { await store.loadTranscript("a") }
        await gate.waitForStart("a")
        store.selectSessionID("b")
        let readB = Task { await store.loadTranscript("b") }
        await gate.waitForStart("b")
        await gate.fail("a")
        await readA.value
        XCTAssertNil(store.transcriptError)
        XCTAssertTrue(store.transcriptLoading)
        await gate.complete("b")
        await readB.value
        XCTAssertEqual(store.transcript.map(\.text), ["Transcript b"])
        XCTAssertNil(store.transcriptError)
        XCTAssertFalse(store.transcriptLoading)
    }

}
