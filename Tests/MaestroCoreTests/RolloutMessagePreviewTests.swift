import Foundation
import XCTest
@testable import MaestroCore

final class RolloutMessagePreviewTests: XCTestCase {
    func testReadsTheLastTextAcrossChunksAndSkipsToolsEmptyMessagesAndMalformedTail() throws {
        let latest = try record(type: "response_item", payload: ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "최신 응답 " + String(repeating: "👨‍👩‍👧‍👦", count: 4_000)]]])
        let tool = try record(type: "response_item", payload: ["type": "function_call_output", "output": String(repeating: "x", count: 140_000)])
        let empty = try record(type: "response_item", payload: ["type": "message", "role": "user", "content": [["text": " \n\t"]]])
        let data = latest + Data("\n".utf8) + tool + Data("\n".utf8) + empty + Data("\n{unfinished".utf8)
        try withRollout(data) { url in
            let result = try XCTUnwrap(RolloutMessagePreviewReader.read(url: url))
            XCTAssertTrue(result.text.hasPrefix("최신 응답 👨‍👩‍👧‍👦"))
            XCTAssertTrue(result.text.hasSuffix("…"))
            XCTAssertEqual(result.text.count, 160)
            XCTAssertEqual(result.role, "assistant")
            XCTAssertEqual(try Data(contentsOf: url), data)
        }
    }

    func testRecognizesUserAndLegacyEventsWithOrWithoutFinalNewline() throws {
        let user = try record(type: "response_item", payload: ["type": "message", "role": "user", "content": [["type": "input_text", "text": "다음"], ["type": "input_text", "text": "질문"]]])
        try withRollout(user) { url in
            XCTAssertEqual(try RolloutMessagePreviewReader.read(url: url)?.displayText, "사용자: 다음 질문")
        }
        let event = try record(type: "event_msg", payload: ["type": "agent_message", "message": "이전 형식의 응답"])
        try withRollout(user + Data("\n".utf8) + event + Data("\n".utf8)) { url in
            XCTAssertEqual(try RolloutMessagePreviewReader.read(url: url)?.displayText, "Codex: 이전 형식의 응답")
        }
        let question = try record(type: "event_msg", payload: ["type": "user_message", "message": "이전 형식의 질문"])
        try withRollout(question) { url in
            XCTAssertEqual(try RolloutMessagePreviewReader.read(url: url)?.role, "user")
        }
    }

    func testNonConversationRecordsAndAnalysisAreNotUsedAsPreviews() throws {
        let message = try record(type: "event_msg", payload: ["type": "user_message", "message": "마지막 질문"])
        let records = [
            try record(type: "response_item", payload: ["type": "message", "role": "developer", "content": [["text": "developer instruction"]]]),
            try record(type: "response_item", payload: ["type": "message", "role": "assistant", "channel": "analysis", "content": [["text": "private reasoning"]]]),
            try record(type: "response_item", payload: ["type": "message", "role": "user", "content": [["type": "input_image", "image_url": "fixture://image"]]]),
            try record(type: "event_msg", payload: ["type": "token_count", "message": "token telemetry"])
        ]
        var data = message
        for item in records { data.append(Data("\n".utf8)); data.append(item) }
        try withRollout(data) { url in XCTAssertEqual(try RolloutMessagePreviewReader.read(url: url)?.text, "마지막 질문") }
        try withRollout(Data()) { url in XCTAssertNil(try RolloutMessagePreviewReader.read(url: url)) }
        try withRollout(records[0]) { url in XCTAssertNil(try RolloutMessagePreviewReader.read(url: url)) }
    }

    private func record(type: String, payload: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["type": type, "payload": payload])
    }
    private func withRollout(_ data: Data, body: (URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url)
    }
}
