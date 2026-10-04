import Foundation

private final class DecisionRedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // Never forward the bearer credential to a redirect destination.
        completionHandler(nil)
    }
}
public struct DecisionRetryPolicy: Sendable {
    public var retries: Int
    public var initialDelay: TimeInterval
    public init(retries: Int = 3, initialDelay: TimeInterval = 1) { self.retries = max(0, retries); self.initialDelay = max(0, initialDelay) }
}
public actor TypeSafeHTTPClient: DecisionService {
    private let apiKey: String
    private let session: URLSession
    private let retry: DecisionRetryPolicy
    public init(apiKey: String, session: URLSession? = nil, retry: DecisionRetryPolicy = .init()) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 600
        self.session = session ?? URLSession(configuration: configuration, delegate: DecisionRedirectGuard(), delegateQueue: nil)
        self.retry = retry
    }
    public func evaluate(_ request: DecisionRequest) async throws -> DecisionResponse {
        try request.validate()
        let data = try await call(path: "systemone", body: DecisionJSON.value(request).data())
        do { return try DecisionResponse.decode(data, for: request) }
        catch let failure as DecisionFailure { throw DecisionResponseFailure(failure: failure, rawData: data) }
    }
    public func models() async throws -> [DecisionModel] {
        let data = try await call(path: "models", body: nil)
        do {
            struct Catalog: Decodable { var models: [DecisionModel] }
            return try JSONDecoder().decode(Catalog.self, from: data).models
        } catch { throw DecisionFailure.malformedResponse("모델 목록: \(error.localizedDescription)") }
    }
    private func call(path: String, body: Data?) async throws -> Data {
        guard !apiKey.isEmpty, !apiKey.contains("\r"), !apiKey.contains("\n") else { throw DecisionFailure.authentication }
        var request = URLRequest(url: URL(string: "https://api.typesafe.ai/v1/\(path)")!)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body { request.httpBody = body; request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        var attempt = 0
        while true {
            try Task.checkCancellation()
            let data: Data, response: URLResponse
            do { (data, response) = try await session.data(for: request) }
            catch {
                if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                throw DecisionFailure.transport(error.localizedDescription)
            }
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else { throw DecisionFailure.transport("HTTP 응답이 아닙니다.") }
            if (200..<300).contains(http.statusCode) { return data }
            if http.statusCode == 401 { throw DecisionFailure.authentication }
            if [429, 529].contains(http.statusCode), attempt < retry.retries {
                let delay = Self.retryAfter(http.value(forHTTPHeaderField: "Retry-After")) ?? retry.initialDelay * pow(2, Double(attempt))
                attempt += 1
                try await Task.sleep(for: .seconds(max(0, delay)))
                continue
            }
            let text = String(decoding: data, as: UTF8.self)
            if [413, 422].contains(http.statusCode), Self.isInputLimit(data, status: http.statusCode) { throw DecisionFailure.inputAdjustment(text) }
            throw DecisionResponseFailure(failure: .service(status: http.statusCode, body: text), rawData: data)
        }
    }
    static func retryAfter(_ header: String?) -> TimeInterval? {
        guard let header else { return nil }
        if let seconds = Double(header), seconds.isFinite { return max(0, seconds) }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        return formatter.date(from: header).map { max(0, $0.timeIntervalSinceNow) }
    }
    static func isInputLimit(_ data: Data, status: Int) -> Bool {
        if status == 413 { return true }
        guard let value = try? JSONDecoder().decode(DecisionJSON.self, from: data) else { return false }
        let codes = [value["code"]?.string, value["error"]?["code"]?.string].compactMap { $0 }
        return codes.contains { ["context_length_exceeded", "input_too_long", "token_limit_exceeded", "request_too_large"].contains($0) }
    }
}
