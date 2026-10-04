import Foundation

public enum DecisionQuestionType: String, Codable, CaseIterable, Sendable { case choice, score, noul }
public struct QuestionSpec: Codable, Hashable, Sendable {
    public var type: DecisionQuestionType
    public var instructions: DecisionJSON
    public var criteria: DecisionJSON?
    public init(type: DecisionQuestionType, instructions: DecisionJSON = .null, criteria: DecisionJSON? = nil) {
        self.type = type; self.instructions = instructions; self.criteria = criteria
    }
    private enum CodingKeys: String, CodingKey { case type, instructions, criteria }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        type = try values.decode(DecisionQuestionType.self, forKey: .type)
        instructions = try values.decodeIfPresent(DecisionJSON.self, forKey: .instructions) ?? .null
        criteria = values.contains(.criteria) ? try values.decode(DecisionJSON.self, forKey: .criteria) : nil
    }
    public func validate(path: String = "") throws {
        func invalid(_ field: String, _ detail: String) -> DecisionFailure { .invalid("\(path)/\(field): \(detail)") }
        guard instructions.isEntry else { throw invalid("instructions", "문자열·객체·배열·null이어야 합니다.") }
        switch type {
        case .choice:
            guard let entries = criteria?.object, !entries.isEmpty, entries.count <= 255 else {
                throw invalid("criteria", "Choice에는 1–255개의 선택지 객체가 필요합니다.")
            }
            for key in entries.keys.sorted() {
                guard !key.isEmpty, entries[key]!.isEntry else {
                    throw invalid("criteria/\(key.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1"))", "선택지 ID는 비어 있지 않아야 하며, 설명은 문자열·객체·배열·null이어야 합니다.")
                }
            }
        case .score:
            guard let entries = criteria?.array, (1...10).contains(entries.count) else {
                throw invalid("criteria", "Score에는 순서가 있는 1–10개의 단계 배열이 필요합니다.")
            }
            for (index, entry) in entries.enumerated() where !entry.isState {
                throw invalid("criteria/\(index)", "Score 단계는 문자열·객체·배열이어야 합니다. 단계 자체의 null·숫자·불리언은 지원하지 않습니다.")
            }
        case .noul:
            var definitions: [String: DecisionJSON] = [:]
            if let criteria, criteria != .null {
                guard let entries = criteria.object, Set(entries.keys).isSubset(of: ["true", "false"]), entries.values.allSatisfy(\.isEntry) else {
                    throw invalid("criteria", "Noul에는 true·false 설명 객체 또는 null만 지정할 수 있습니다.")
                }
                definitions = entries
            }
            guard instructions.hasInstructions || definitions.values.contains(where: { $0 != .null }) else {
                throw invalid("instructions", "Noul에는 비어 있지 않은 지시문 또는 null이 아닌 true·false 기준 설명이 필요합니다.")
            }
        }
    }
}
public struct DecisionRequest: Codable, Hashable, Sendable {
    public var state: DecisionJSON
    public var model: String
    public var questions: [String: QuestionSpec]
    public init(state: DecisionJSON, model: String, questions: [String: QuestionSpec]) { self.state = state; self.model = model; self.questions = questions }
    public func validate() throws {
        guard state.isState else { throw DecisionFailure.invalid("state는 문자열·객체·배열이어야 합니다.") }
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !questions.isEmpty,
              questions.keys.allSatisfy({ !$0.isEmpty }) else { throw DecisionFailure.invalid("모델과 질문 ID가 필요합니다.") }
        for id in questions.keys.sorted() {
            let escaped = id.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
            try questions[id]!.validate(path: "/questions/\(escaped)")
        }
    }
    public var cacheableModel: Bool { model.range(of: #"^jev-[0-9]+\.[0-9]+\.[0-9]+(?:[-.][A-Za-z0-9]+)*$"#, options: .regularExpression) != nil }
    public var fingerprint: String { (try? DecisionJSON.value(self).fingerprint) ?? "" }
}
public struct DecisionUsage: Codable, Hashable, Sendable {
    public var input_tokens: Int
    public var output_tokens: Int
    public init(input_tokens: Int, output_tokens: Int) { self.input_tokens = input_tokens; self.output_tokens = output_tokens }
}
public enum DecisionAnswer: Hashable, Sendable {
    case choice(value: String, probabilities: [String: Double], confidence: Double)
    case score(value: Double, probabilities: [String: Double], confidence: Double, legend: [String: DecisionJSON])
    case noul(Double)
    public var confidence: Double? { switch self { case .choice(_, _, let value), .score(_, _, let value, _): value; case .noul: nil } }
    /// Only contract-validated fields are visible to templates and application rules.
    public var json: DecisionJSON {
        switch self {
        case .choice(let value, let probabilities, let confidence):
            .object(["type": .string("choice"), "choice": .string(value), "probabilities": .object(probabilities.mapValues(DecisionJSON.numeric)), "confidence": .numeric(confidence)])
        case .score(let value, let probabilities, let confidence, let legend):
            .object(["type": .string("score"), "score": .numeric(value), "probabilities": .object(probabilities.mapValues(DecisionJSON.numeric)), "confidence": .numeric(confidence), "legend": .object(legend)])
        case .noul(let value): .object(["type": .string("noul"), "noul": .numeric(value)])
        }
    }
    public func normalized(for question: QuestionSpec) throws -> Double {
        switch (self, question.type) {
        case (.noul(let value), .noul): return value
        case (.score(let value, _, _, _), .score):
            guard let count = question.criteria?.array?.count, count >= 2 else { throw DecisionFailure.invalid("Score 정규화와 순위 계산에는 2개 이상의 단계가 필요합니다. 1단계의 원본 결과는 조회할 수 있습니다.") }
            return value / Double(count - 1)
        default: throw DecisionFailure.invalid("후보별 순위와 가중합에는 공통 기준의 Score 또는 Noul이 필요합니다.")
        }
    }
}
public struct DecisionResponse: Sendable {
    public let model: String
    public let answers: [String: DecisionAnswer]
    public let usage: DecisionUsage
    public let raw: DecisionJSON
    public let rawData: Data
    public static func decode(_ data: Data, for request: DecisionRequest) throws -> Self {
        try request.validate()
        do {
            let raw = try JSONDecoder().decode(DecisionJSON.self, from: data)
            guard let model = raw["model"]?.string, !model.isEmpty, let objects = raw["answers"]?.object,
                  let usageJSON = raw["usage"] else { throw DecisionFailure.malformedResponse("model·answers·usage 누락") }
            let usage = try JSONDecoder().decode(DecisionUsage.self, from: usageJSON.data())
            guard usage.input_tokens >= 0, usage.output_tokens >= 0 else { throw DecisionFailure.malformedResponse("음수 사용량") }
            var answers: [String: DecisionAnswer] = [:]
            for (id, question) in request.questions {
                guard let object = objects[id], object["type"]?.string == question.type.rawValue else { throw DecisionFailure.malformedResponse("\(id): 응답 누락 또는 타입 불일치") }
                func number(_ key: String, range: ClosedRange<Double>) throws -> Double {
                    guard let value = object[key]?.double, value.isFinite, range.contains(value) else { throw DecisionFailure.malformedResponse("\(id).\(key): 범위를 벗어났거나 숫자가 아님") }
                    return value
                }
                func distribution(_ keys: Set<String>) throws -> [String: Double] {
                    guard let values = object["probabilities"]?.object, Set(values.keys) == keys else { throw DecisionFailure.malformedResponse("\(id): 전체 확률 분포 누락 또는 선택지 불일치") }
                    var result: [String: Double] = [:]
                    for (key, value) in values {
                        guard let probability = value.double, probability.isFinite, (0...1).contains(probability) else { throw DecisionFailure.malformedResponse("\(id): 잘못된 확률") }
                        result[key] = probability
                    }
                    guard abs(result.values.reduce(0, +) - 1) < 0.001 else { throw DecisionFailure.malformedResponse("\(id): 확률 합이 1이 아님") }
                    return result
                }
                switch question.type {
                case .noul: answers[id] = .noul(try number("noul", range: 0...1))
                case .choice:
                    let keys = Set(question.criteria?.object?.keys.map { $0 } ?? [])
                    guard let value = object["choice"]?.string, keys.contains(value) else { throw DecisionFailure.malformedResponse("\(id): 알 수 없는 선택지") }
                    answers[id] = .choice(value: value, probabilities: try distribution(keys), confidence: try number("confidence", range: 0...1))
                case .score:
                    let count = question.criteria?.array?.count ?? 0
                    let keys = Set((0..<count).map(String.init))
                    guard let legend = object["legend"]?.object, Set(legend.keys) == keys,
                          legend.values.allSatisfy(\.isState) else { throw DecisionFailure.malformedResponse("\(id): legend 누락·단계 불일치 또는 지원하지 않는 단계 설명") }
                    answers[id] = .score(value: try number("score", range: 0...Double(count - 1)), probabilities: try distribution(keys), confidence: try number("confidence", range: 0...1), legend: legend)
                }
            }
            return Self(model: model, answers: answers, usage: usage, raw: raw, rawData: data)
        } catch let error as DecisionFailure { throw error }
        catch { throw DecisionFailure.malformedResponse(error.localizedDescription) }
    }
}
public struct DecisionModel: Codable, Hashable, Sendable, Identifiable {
    public var name: String
    public var description: String
    public var release_date: String
    public var id: String { name }
}
public protocol DecisionService: Sendable {
    func evaluate(_ request: DecisionRequest) async throws -> DecisionResponse
    func models() async throws -> [DecisionModel]
}
public struct DecisionResponseFailure: Error, LocalizedError, Sendable {
    public let failure: DecisionFailure
    public let rawData: Data
    public var errorDescription: String? { failure.errorDescription }
    public init(failure: DecisionFailure, rawData: Data) { self.failure = failure; self.rawData = rawData }
}
