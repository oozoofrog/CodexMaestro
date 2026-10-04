import Foundation
import CryptoKit

/// JSON values retain nested structure and array order. Decimal avoids Double rounding of integer IDs.
public enum DecisionJSON: Codable, Hashable, Sendable {
    case null, bool(Bool), number(Decimal), string(String), array([DecisionJSON]), object([String: DecisionJSON])

    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let item = try? value.decode(Bool.self) { self = .bool(item) }
        else if let item = try? value.decode(String.self) { self = .string(item) }
        else if let item = try? value.decode([String: DecisionJSON].self) { self = .object(item) }
        else if let item = try? value.decode([DecisionJSON].self) { self = .array(item) }
        else { self = .number(try value.decode(Decimal.self)) }
    }
    public func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .null: try value.encodeNil()
        case .bool(let item): try value.encode(item)
        case .number(let item): try value.encode(item)
        case .string(let item): try value.encode(item)
        case .array(let item): try value.encode(item)
        case .object(let item): try value.encode(item)
        }
    }
    public static func parse(_ text: String) throws -> Self { try JSONDecoder().decode(Self.self, from: Data(text.utf8)) }
    public static func value<T: Encodable>(_ value: T) throws -> Self { try JSONDecoder().decode(Self.self, from: JSONEncoder().encode(value)) }
    public func data(pretty: Bool = false) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
    public var text: String { (try? String(decoding: data(pretty: true), as: UTF8.self)) ?? "null" }
    public var fingerprint: String { (try? Self.digest(data())) ?? "" }
    public static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    public var string: String? { if case .string(let value) = self { value } else { nil } }
    public var double: Double? { if case .number(let value) = self { NSDecimalNumber(decimal: value).doubleValue } else { nil } }
    public var object: [String: Self]? { if case .object(let value) = self { value } else { nil } }
    public var array: [Self]? { if case .array(let value) = self { value } else { nil } }
    public subscript(_ key: String) -> Self? { object?[key] }
    public static func numeric(_ value: Double) -> Self { .number(Decimal(value)) }
    public func at(_ pointer: String) -> Self? {
        if pointer.isEmpty { return self }
        guard pointer.hasPrefix("/") else { return nil }
        var current = self
        for escaped in pointer.dropFirst().split(separator: "/", omittingEmptySubsequences: false) {
            let key = escaped.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
            if let value = current.object?[key] { current = value }
            else if let values = current.array, let index = Int(key), index >= 0, index < values.count { current = values[index] }
            else { return nil }
        }
        return current
    }
    var isEntry: Bool { switch self { case .null, .string, .object, .array: true; default: false } }
    var isState: Bool { switch self { case .string, .object, .array: true; default: false } }
    // The service treats empty strings/containers and null as absent Noul instructions.
    // Nested values are preserved; whitespace is accepted by the service.
    var hasInstructions: Bool {
        switch self {
        case .string(let value): !value.isEmpty
        case .object(let value): !value.isEmpty
        case .array(let value): !value.isEmpty
        default: false
        }
    }
}

public enum DecisionFailure: Error, LocalizedError, Sendable, Equatable {
    case invalid(String), insufficientInput(String), insufficientJudgment(String), inputAdjustment(String), stale(String)
    case authentication, service(status: Int, body: String), transport(String), malformedResponse(String)
    public var errorDescription: String? {
        switch self {
        case .invalid(let detail): "판단 설정 오류: \(detail)"
        case .insufficientInput(let detail): "입력 부족: \(detail)"
        case .insufficientJudgment(let detail): "판단 부족: \(detail)"
        case .inputAdjustment(let detail): "입력 조정 필요: \(detail)"
        case .stale(let detail): "오래된 결과: \(detail)"
        case .authentication: "TypeSafe API 키가 없거나 유효하지 않습니다."
        case .service(let status, let body): "TypeSafe HTTP \(status): \(Self.serviceDetail(body))"
        case .transport(let detail): "TypeSafe 연결 오류: \(detail)"
        case .malformedResponse(let detail): "TypeSafe 응답 계약 오류: \(detail)"
        }
    }
    private static func serviceDetail(_ body: String) -> String {
        guard let value = try? DecisionJSON.parse(body), let detail = value["detail"] else { return body }
        if let message = detail.string { return message }
        guard let errors = detail.array, !errors.isEmpty else { return body }
        let messages = errors.compactMap { error -> String? in
            guard let message = error["msg"]?.string, let location = error["loc"]?.array else { return nil }
            let path = location.map { ($0.string ?? $0.text).replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1") }.joined(separator: "/")
            return "/\(path): \(message)"
        }
        return messages.count == errors.count ? messages.joined(separator: "\n") : body
    }
}
