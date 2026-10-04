import Foundation

public struct DecisionEvidence: Codable, Hashable, Sendable {
    public var id: String
    public var coverage: String
    public var fingerprint: String
    public init(id: String, coverage: String, fingerprint: String) { self.id = id; self.coverage = coverage; self.fingerprint = fingerprint }
}
public struct DecisionInput: Codable, Hashable, Sendable {
    public var state: DecisionJSON
    public var materials: [String: DecisionJSON]
    public var evidence: [DecisionEvidence]
    public init(state: DecisionJSON, materials: [String: DecisionJSON] = [:], evidence: [DecisionEvidence] = []) {
        self.state = state; self.materials = materials; self.evidence = evidence
    }
    public var fingerprint: String { (try? DecisionJSON.value(self).fingerprint) ?? "" }
}
/// A template object containing only "$ref" resolves a JSON Pointer into /input or /steps.
/// "$lookup" selects an existing source entry with a key resolved from the current context.
/// Literal objects with other keys stay objects; no string interpolation or implicit truncation occurs.
public enum DecisionTemplate {
    public static func resolve(_ template: DecisionJSON, in context: DecisionJSON) throws -> DecisionJSON {
        if let object = template.object, object.count == 1, let pointer = object["$ref"]?.string {
            guard let value = context.at(pointer) else { throw DecisionFailure.insufficientInput("참조를 찾지 못했습니다: \(pointer)") }
            return value
        }
        if let object = template.object, object.count == 1, let lookup = object["$lookup"] {
            guard let fields = lookup.object, Set(fields.keys) == ["source", "key"],
                  let sourceTemplate = fields["source"], let keyTemplate = fields["key"] else {
                throw DecisionFailure.invalid("$lookup에는 source와 key가 필요합니다.")
            }
            let source = try resolve(sourceTemplate, in: context), key = try resolve(keyTemplate, in: context)
            if let entries = source.object, let id = key.string, let value = entries[id] { return value }
            if let entries = source.array, let numeric = key.double, numeric.isFinite, numeric >= 0,
               numeric < Double(entries.count), numeric.rounded(.towardZero) == numeric { return entries[Int(numeric)] }
            throw DecisionFailure.insufficientInput("$lookup으로 선택할 원본 항목이 없습니다.")
        }
        switch template {
        case .array(let values): return .array(try values.map { try resolve($0, in: context) })
        case .object(let values): return .object(try values.mapValues { try resolve($0, in: context) })
        default: return template
        }
    }
    public static func pointers(in template: DecisionJSON) -> [String] {
        if let object = template.object, object.count == 1, let pointer = object["$ref"]?.string { return [pointer] }
        switch template { case .array(let values): return values.flatMap(pointers); case .object(let values): return values.values.flatMap(pointers); default: return [] }
    }
}
public enum DecisionComparison: String, Codable, CaseIterable, Sendable { case equal, notEqual, greaterOrEqual, lessOrEqual, greater, less, exists }
public struct DecisionPredicate: Codable, Hashable, Sendable {
    public var lhs: DecisionJSON
    public var comparison: DecisionComparison
    public var rhs: DecisionJSON
    public init(lhs: DecisionJSON, comparison: DecisionComparison = .greaterOrEqual, rhs: DecisionJSON = .numeric(0.5)) { self.lhs = lhs; self.comparison = comparison; self.rhs = rhs }
    public func evaluate(in context: DecisionJSON) throws -> Bool {
        if comparison == .exists {
            guard let pointer = lhs["$ref"]?.string else { throw DecisionFailure.invalid("exists에는 $ref가 필요합니다.") }
            return context.at(pointer) != nil
        }
        let left = try DecisionTemplate.resolve(lhs, in: context), right = try DecisionTemplate.resolve(rhs, in: context)
        switch comparison {
        case .equal: return left == right
        case .notEqual: return left != right
        case .exists: return false
        default:
            guard let a = left.double, let b = right.double else { throw DecisionFailure.invalid("수치 비교에는 두 숫자가 필요합니다.") }
            switch comparison { case .greaterOrEqual: return a >= b; case .lessOrEqual: return a <= b; case .greater: return a > b; case .less: return a < b; default: return false }
        }
    }
}
public indirect enum DecisionCondition: Codable, Hashable, Sendable {
    case predicate(DecisionPredicate), all([DecisionCondition]), any([DecisionCondition]), not(DecisionCondition)
    public func evaluate(in context: DecisionJSON) throws -> Bool {
        switch self {
        case .predicate(let predicate): return try predicate.evaluate(in: context)
        case .all(let conditions): for condition in conditions { if try !condition.evaluate(in: context) { return false } }; return true
        case .any(let conditions): for condition in conditions { if try condition.evaluate(in: context) { return true } }; return false
        case .not(let condition): return try !condition.evaluate(in: context)
        }
    }
    var pointers: [String] {
        switch self { case .predicate(let value): DecisionTemplate.pointers(in: value.lhs) + DecisionTemplate.pointers(in: value.rhs)
        case .all(let values), .any(let values): values.flatMap(\.pointers); case .not(let value): value.pointers }
    }
}
public struct DecisionQuestion: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var revision: Int
    public var criteriaRevision: Int
    public var spec: QuestionSpec
    public var minimumConfidence: Double?
    public init(id: String, revision: Int = 1, criteriaRevision: Int = 1, spec: QuestionSpec, minimumConfidence: Double? = nil) {
        self.id = id; self.revision = revision; self.criteriaRevision = criteriaRevision; self.spec = spec; self.minimumConfidence = minimumConfidence
    }
}
public struct DecisionStage: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var dependencies: [String]
    public var when: DecisionCondition?
    public var state: DecisionJSON
    /// Resolves to a string or array of registered material IDs. Only these materials enter this stage.
    public var materialIDs: DecisionJSON?
    public var questions: [DecisionQuestion]
    public init(id: String, dependencies: [String] = [], when: DecisionCondition? = nil, state: DecisionJSON = .object(["$ref": .string("/input")]), materialIDs: DecisionJSON? = nil, questions: [DecisionQuestion]) {
        self.id = id; self.dependencies = dependencies; self.when = when; self.state = state; self.materialIDs = materialIDs; self.questions = questions
    }
}
public struct DecisionPlan: Codable, Hashable, Sendable {
    public var stages: [DecisionStage]
    public init(stages: [DecisionStage]) { self.stages = stages }
    public func validate() throws {
        let ids = Set(stages.map(\.id))
        guard !stages.isEmpty, ids.count == stages.count, !ids.contains(""), stages.allSatisfy({ !$0.id.contains("/") && !$0.id.contains("~") }) else { throw DecisionFailure.invalid("단계 ID는 고유하고 비어 있지 않아야 합니다. /와 ~는 사용할 수 없습니다.") }
        for (stageIndex, stage) in stages.enumerated() {
            guard Set(stage.dependencies).count == stage.dependencies.count, Set(stage.dependencies).isSubset(of: ids), !stage.dependencies.contains(stage.id),
                  !stage.questions.isEmpty, Set(stage.questions.map(\.id)).count == stage.questions.count else { throw DecisionFailure.invalid("\(stage.id): 질문 ID 또는 의존 단계 오류") }
            var pointers = DecisionTemplate.pointers(in: stage.state) + (stage.materialIDs.map(DecisionTemplate.pointers) ?? []) + (stage.when?.pointers ?? [])
            for (questionIndex, question) in stage.questions.enumerated() {
                guard !question.id.isEmpty, !question.id.contains("/"), !question.id.contains("~"), question.revision > 0, question.criteriaRevision > 0 else { throw DecisionFailure.invalid("\(stage.id): 질문 ID와 버전 오류") }
                if let minimum = question.minimumConfidence {
                    guard question.spec.type != .noul, minimum.isFinite, (0...1).contains(minimum) else { throw DecisionFailure.invalid("\(question.id): Noul에는 confidence가 없으며, 임계값은 0–1이어야 합니다.") }
                }
                pointers += DecisionTemplate.pointers(in: question.spec.instructions) + (question.spec.criteria.map(DecisionTemplate.pointers) ?? [])
                if DecisionTemplate.pointers(in: question.spec.instructions).isEmpty,
                   (question.spec.criteria.map(DecisionTemplate.pointers) ?? []).isEmpty {
                    try question.spec.validate(path: "/plan/stages/\(stageIndex)/questions/\(questionIndex)/spec")
                }
            }
            // A later stage must explicitly depend on every answer it reads.
            for pointer in pointers where pointer.hasPrefix("/steps/") {
                let parts = pointer.split(separator: "/")
                guard parts.count >= 2, stage.dependencies.contains(String(parts[1])) else { throw DecisionFailure.invalid("\(stage.id): \(pointer)의 의존 단계를 명시해야 합니다.") }
            }
        }
        var complete: Set<String> = []
        while complete.count < stages.count {
            let ready = stages.filter { !complete.contains($0.id) && Set($0.dependencies).isSubset(of: complete) }
            guard !ready.isEmpty else { throw DecisionFailure.invalid("실행 계획에 순환 의존 관계가 있습니다.") }
            complete.formUnion(ready.map(\.id))
        }
    }
}
public struct DecisionAnswerReference: Codable, Hashable, Sendable {
    public var stage: String
    public var question: String
    public init(stage: String, question: String) { self.stage = stage; self.question = question }
}
public struct DecisionAxis: Codable, Hashable, Sendable {
    public var answer: DecisionAnswerReference
    public var weight: Double
    public init(answer: DecisionAnswerReference, weight: Double = 1) { self.answer = answer; self.weight = weight }
}
public struct DecisionCandidate: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var value: DecisionJSON
    public var axes: [DecisionAxis]
    public var required: [DecisionCondition]
    public init(id: String, value: DecisionJSON, axes: [DecisionAxis], required: [DecisionCondition] = []) { self.id = id; self.value = value; self.axes = axes; self.required = required }
}
public struct DecisionLabel: Codable, Hashable, Sendable {
    public var label: String
    public var when: DecisionCondition
    public init(label: String, when: DecisionCondition) { self.label = label; self.when = when }
}
public struct DecisionSelection: Codable, Hashable, Sendable {
    public var answer: DecisionAnswerReference
    /// Value candidates are built by code or entered by the user; the model never generates them.
    public var values: DecisionJSON
    public init(answer: DecisionAnswerReference, values: DecisionJSON) { self.answer = answer; self.values = values }
}
public struct DecisionBinding: Codable, Hashable, Sendable {
    public var handler: String
    public var arguments: DecisionJSON
    public var when: DecisionCondition?
    public init(handler: String, arguments: DecisionJSON, when: DecisionCondition? = nil) { self.handler = handler; self.arguments = arguments; self.when = when }
}
public struct DecisionComposition: Codable, Hashable, Sendable {
    public var candidates: [DecisionCandidate]
    public var labels: [DecisionLabel]
    public var selections: [DecisionSelection]
    public var bindings: [DecisionBinding]
    public var minimumScore: Double?
    public init(candidates: [DecisionCandidate] = [], labels: [DecisionLabel] = [], selections: [DecisionSelection] = [], bindings: [DecisionBinding] = [], minimumScore: Double? = nil) {
        self.candidates = candidates; self.labels = labels; self.selections = selections; self.bindings = bindings; self.minimumScore = minimumScore
    }
}
public struct DecisionProfile: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var revision: Int
    public var model: String
    public var plan: DecisionPlan
    public var composition: DecisionComposition
    public init(id: UUID = UUID(), name: String = "새 판단", revision: Int = 1, model: String = "jev-latest", plan: DecisionPlan, composition: DecisionComposition = .init()) {
        self.id = id; self.name = name; self.revision = revision; self.model = model; self.plan = plan; self.composition = composition
    }
    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, revision > 0, !model.isEmpty else { throw DecisionFailure.invalid("Profile 이름·버전·모델이 필요합니다.") }
        try plan.validate()
        let questions = Dictionary(uniqueKeysWithValues: plan.stages.map { ($0.id, Dictionary(uniqueKeysWithValues: $0.questions.map { ($0.id, $0.spec) })) })
        func lookup(_ ref: DecisionAnswerReference) throws -> QuestionSpec {
            guard let spec = questions[ref.stage]?[ref.question] else { throw DecisionFailure.invalid("결과 참조가 없습니다: \(ref.stage)/\(ref.question)") }; return spec
        }
        guard Set(composition.candidates.map(\.id)).count == composition.candidates.count else { throw DecisionFailure.invalid("후보 ID 중복") }
        for candidate in composition.candidates {
            guard !candidate.axes.isEmpty, candidate.axes.allSatisfy({ $0.weight.isFinite && $0.weight >= 0 }), candidate.axes.reduce(0, { $0 + $1.weight }) > 0 else { throw DecisionFailure.invalid("후보의 가중치 합은 양수여야 합니다.") }
            for axis in candidate.axes {
                let spec = try lookup(axis.answer)
                guard spec.type != .choice else { throw DecisionFailure.invalid("Choice 확률을 후보별 전역 순위에 사용할 수 없습니다.") }
                if spec.type == .score, spec.criteria?.array?.count == 1 {
                    throw DecisionFailure.invalid("\(axis.answer.stage)/\(axis.answer.question): 순위 계산에는 2개 이상의 Score 단계가 필요합니다.")
                }
            }
        }
        for selection in composition.selections { guard try lookup(selection.answer).type == .choice else { throw DecisionFailure.invalid("값 선택에는 Choice가 필요합니다.") } }
        if let threshold = composition.minimumScore { guard threshold.isFinite, (0...1).contains(threshold) else { throw DecisionFailure.invalid("정규화 점수 임계값은 0–1이어야 합니다.") } }
    }
    public static var starter: Self {
        .init(name: "관련성과 제약 점검", plan: .init(stages: [.init(id: "evaluate", questions: [
            .init(id: "relevance", spec: .init(type: .score, instructions: .string("state의 자료가 state의 목표와 얼마나 관련 있습니까? 자료가 없으면 가장 낮은 단계로 평가하세요."), criteria: .array([.string("관련 없음 또는 근거 없음"), .string("부분 관련"), .string("직접 관련")]))),
            .init(id: "constraints", spec: .init(type: .noul, instructions: .string("state에 목표 달성에 적용되는 명시적인 제약이 있습니까?")))
        ])]))
    }
}
