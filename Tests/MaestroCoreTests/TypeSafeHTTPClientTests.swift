import XCTest
import Foundation
@testable import MaestroCore

private final class TypeSafeProtocolState: @unchecked Sendable {
    let lock = NSLock()
    var handler: @Sendable (URLRequest) throws -> (Int, [String: String], Data) = { _ in throw URLError(.badServerResponse) }
    func set(_ handler: @escaping @Sendable (URLRequest) throws -> (Int, [String: String], Data)) { lock.lock(); self.handler = handler; lock.unlock() }
    func respond(_ request: URLRequest) throws -> (Int, [String: String], Data) { lock.lock(); let handler = handler; lock.unlock(); return try handler(request) }
}
private final class TypeSafeTestProtocol: URLProtocol, @unchecked Sendable {
    static let state = TypeSafeProtocolState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, headers, data) = try Self.state.respond(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
private final class TypeSafeRequestLog: @unchecked Sendable {
    let lock = NSLock()
    private var requests: [URLRequest] = []
    func add(_ request: URLRequest) -> Int { lock.lock(); defer { lock.unlock() }; requests.append(request); return requests.count }
    var values: [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
}
@MainActor final class TypeSafeHTTPClientTests: XCTestCase {
    private let request = DecisionRequest(state: .string("synthetic only"), model: "jev-latest", questions: ["q": .init(type: .noul, instructions: .string("fixture?"))])
    private func client(key: String = "synthetic-test-key", retries: Int = 2) -> TypeSafeHTTPClient {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [TypeSafeTestProtocol.self]
        return .init(apiKey: key, session: URLSession(configuration: configuration), retry: .init(retries: retries, initialDelay: 0))
    }
    func testAuthenticatedRequestAndModelListingUseDocumentedEndpoints() async throws {
        let log = TypeSafeRequestLog()
        TypeSafeTestProtocol.state.set { request in
            _ = log.add(request)
            if request.url?.lastPathComponent == "models" { return (200, [:], Data(#"{"models":[{"name":"jev-latest","description":"fixture","release_date":"2026-01-01"}]}"#.utf8)) }
            return (200, [:], Data(#"{"model":"jev-1.13.0","answers":{"q":{"type":"noul","noul":0.9}},"usage":{"input_tokens":10,"output_tokens":5}}"#.utf8))
        }
        let client = client()
        let response = try await client.evaluate(request), models = try await client.models()
        XCTAssertEqual(response.answers["q"], .noul(0.9)); XCTAssertEqual(models.first?.name, "jev-latest")
        XCTAssertEqual(log.values.map { $0.url?.absoluteString }, ["https://api.typesafe.ai/v1/systemone", "https://api.typesafe.ai/v1/models"])
        XCTAssertEqual(log.values.map(\.httpMethod), ["POST", "GET"])
        XCTAssertTrue(log.values.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-test-key" })
    }
    func testRateLimitAndOverloadRetryButValidationDoesNot() async throws {
        let log = TypeSafeRequestLog()
        TypeSafeTestProtocol.state.set { request in
            let count = log.add(request)
            if count <= 2 { return (count == 1 ? 429 : 529, ["Retry-After": "0"], Data(#"{"error":"busy"}"#.utf8)) }
            return (200, [:], Data(#"{"model":"jev-1.13.0","answers":{"q":{"type":"noul","noul":0.9}},"usage":{"input_tokens":10,"output_tokens":5}}"#.utf8))
        }
        _ = try await client().evaluate(request)
        XCTAssertEqual(log.values.count, 3)
        let validation = TypeSafeRequestLog()
        TypeSafeTestProtocol.state.set { request in _ = validation.add(request); return (422, [:], Data(#"{"error":"invalid question"}"#.utf8)) }
        do { _ = try await client().evaluate(request); XCTFail("expected failure") }
        catch let error as DecisionResponseFailure {
            guard case .service(status: 422, body: _) = error.failure else { return XCTFail("wrong failure: \(error)") }
            XCTAssertEqual(error.rawData, Data(#"{"error":"invalid question"}"#.utf8))
        }
        XCTAssertEqual(validation.values.count, 1)
    }
    func testMissingKeyNeverMakesARequestAndUnauthorizedIsDistinct() async {
        let log = TypeSafeRequestLog()
        TypeSafeTestProtocol.state.set { request in _ = log.add(request); return (401, [:], Data()) }
        do { _ = try await client(key: "").evaluate(request); XCTFail("expected authentication") }
        catch { XCTAssertEqual(error as? DecisionFailure, .authentication) }
        XCTAssertTrue(log.values.isEmpty)
        do { _ = try await client().evaluate(request); XCTFail("expected authentication") }
        catch { XCTAssertEqual(error as? DecisionFailure, .authentication) }
        XCTAssertEqual(log.values.count, 1)
    }
    func testOnlyExplicitServiceInputLimitTriggersAdjustment() async {
        TypeSafeTestProtocol.state.set { _ in (422, [:], Data(#"{"error":{"code":"context_length_exceeded"}}"#.utf8)) }
        do { _ = try await client().evaluate(request); XCTFail("expected input limit") }
        catch let failure as DecisionFailure { guard case .inputAdjustment = failure else { return XCTFail("wrong status") } }
        catch { XCTFail("unexpected: \(error)") }
    }
    func testMalformedResponseRetainsOriginalBytes() async {
        let malformed = Data(#"{"model":"jev-1.13.0","answers":{},"usage":{"input_tokens":1,"output_tokens":1},"future":true}"#.utf8)
        TypeSafeTestProtocol.state.set { _ in (200, [:], malformed) }
        do { _ = try await client().evaluate(request); XCTFail("expected malformed") }
        catch let error as DecisionResponseFailure { XCTAssertEqual(error.rawData, malformed) }
        catch { XCTFail("unexpected error") }
    }
    func testInvalidQuestionNeverMakesAnHTTPCall() async {
        let log = TypeSafeRequestLog()
        TypeSafeTestProtocol.state.set { request in _ = log.add(request); return (200, [:], Data()) }
        let invalid = DecisionRequest(state: .string("synthetic"), model: "jev-latest", questions: ["broken": .init(type: .score, criteria: .array([.null, .string("high")]))])
        do { _ = try await client().evaluate(invalid); XCTFail("invalid question reached service") }
        catch { XCTAssertTrue(error.localizedDescription.contains("/questions/broken/criteria/0")) }
        XCTAssertTrue(log.values.isEmpty)
    }
    func testHTTPValidationLocationIsReadableAndRawBytesAreRetained() async {
        let data = Data(#"{"detail":[{"loc":["body","questions","q","score","criteria",0,"str"],"msg":"Input should be a valid string","type":"string_type","input":null}],"future":true}"#.utf8)
        let log = TypeSafeRequestLog()
        TypeSafeTestProtocol.state.set { request in _ = log.add(request); return (422, [:], data) }
        do { _ = try await client().evaluate(request); XCTFail("expected service rejection") }
        catch let failure as DecisionResponseFailure {
            XCTAssertEqual(failure.rawData, data)
            XCTAssertTrue(failure.localizedDescription.contains("/body/questions/q/score/criteria/0/str: Input should be a valid string"))
            guard case .service(status: 422, body: let body) = failure.failure else { return XCTFail("wrong failure") }
            XCTAssertEqual(Data(body.utf8), data)
        } catch { XCTFail("unexpected error: \(error)") }
        XCTAssertEqual(log.values.count, 1)
    }
    func testCancellationInterruptsRetryAfterSleep() async {
        let log = TypeSafeRequestLog()
        TypeSafeTestProtocol.state.set { request in _ = log.add(request); return (429, ["Retry-After": "60"], Data()) }
        let client = client(), request = request
        let task = Task { try await client.evaluate(request) }
        while log.values.isEmpty { await Task.yield() }
        task.cancel()
        do { _ = try await task.value; XCTFail("cancelled task succeeded") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(log.values.count, 1)
    }
}
