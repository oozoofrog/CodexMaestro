import Foundation

public enum DecisionResultStatus: String, Codable, Sendable {
    case succeeded, insufficientInput, insufficientJudgment, inputAdjustment, apiError, invalidProfile, cancelled, stale
}
public struct DecisionTrace: Sendable {
    public let request: DecisionRequest
    public let response: DecisionResponse?
    public let error: String?
    public let cached: Bool
    public let rawErrorResponse: Data?
    public init(request: DecisionRequest, response: DecisionResponse? = nil, error: String? = nil, cached: Bool = false, rawErrorResponse: Data? = nil) {
        self.request = request; self.response = response; self.error = error; self.cached = cached; self.rawErrorResponse = rawErrorResponse
    }
}
public struct DecisionStageResult: Sendable {
    public var questions: [String: DecisionQuestion]
    public var answers: [String: DecisionAnswer]
    public var materialIDs: [String]
    public var skipped: Bool
    public var json: DecisionJSON { .object(["answers": .object(answers.mapValues(\.json)), "skipped": .bool(skipped), "materialIDs": .array(materialIDs.map(DecisionJSON.string))]) }
}
public struct DecisionRank: Sendable {
    public var id: String
    public var value: DecisionJSON
    public var score: Double
    public var eligible: Bool
}
public struct DecisionComposedResult: Sendable {
    public var ranks: [DecisionRank] = []
    public var labels: [String] = []
    public var selectedValues: [DecisionJSON] = []
    public var bindings: [DecisionBinding] = []
}
public struct DecisionResult: Sendable {
    public var status: DecisionResultStatus
    public var detail: String?
    public let profile: DecisionProfile
    public let inputFingerprint: String
    public let evidence: [DecisionEvidence]
    public var readMaterialIDs: Set<String> = []
    public var consultedEvidence: [DecisionEvidence] {
        let fullIDs = readMaterialIDs.union(stages.values.flatMap(\.materialIDs))
        return evidence.map { value in var value = value; if fullIDs.contains(value.id) { value.coverage = "full" }; return value }
    }
    public var stages: [String: DecisionStageResult]
    public var traces: [DecisionTrace]
    public var composed: DecisionComposedResult
    public let startedAt: Date
    public var completedAt: Date
    public var usage: DecisionUsage {
        traces.filter { !$0.cached }.compactMap(\.response?.usage).reduce(.init(input_tokens: 0, output_tokens: 0)) { .init(input_tokens: $0.input_tokens + $1.input_tokens, output_tokens: $0.output_tokens + $1.output_tokens) }
    }
    public func isCurrent(input: DecisionInput, profile: DecisionProfile) -> Bool { inputFingerprint == input.fingerprint && self.profile == profile }
    public func context(input: DecisionJSON) -> DecisionJSON { .object(["input": input, "steps": .object(stages.mapValues(\.json))]) }
}
public enum DecisionComposer {
    public static func compose(_ composition: DecisionComposition, stages: [String: DecisionStageResult], context: DecisionJSON) throws -> DecisionComposedResult {
        func answer(_ reference: DecisionAnswerReference) throws -> (DecisionAnswer, QuestionSpec) {
            guard let result = stages[reference.stage], let answer = result.answers[reference.question], let question = result.questions[reference.question] else { throw DecisionFailure.insufficientJudgment("결과 없음: \(reference.stage)/\(reference.question)") }
            return (answer, question.spec)
        }
        var output = DecisionComposedResult()
        for candidate in composition.candidates {
            let value = try DecisionTemplate.resolve(candidate.value, in: context)
            var score = 0.0, weights = 0.0
            for axis in candidate.axes {
                let (value, question) = try answer(axis.answer)
                score += try value.normalized(for: question) * axis.weight; weights += axis.weight
            }
            guard weights.isFinite, weights > 0, score.isFinite else { throw DecisionFailure.invalid("가중치 합 또는 점수 오류") }
            score /= weights
            var eligible = composition.minimumScore.map { score >= $0 } ?? true
            for rule in candidate.required { if try !rule.evaluate(in: context) { eligible = false } }
            output.ranks.append(.init(id: candidate.id, value: value, score: score, eligible: eligible))
        }
        output.ranks.sort { $0.eligible != $1.eligible ? $0.eligible : ($0.score != $1.score ? $0.score > $1.score : $0.id < $1.id) }
        for label in composition.labels where try label.when.evaluate(in: context) { output.labels.append(label.label) }
        for selection in composition.selections {
            let (result, _) = try answer(selection.answer)
            guard case .choice(let id, _, _) = result, let value = try DecisionTemplate.resolve(selection.values, in: context).object?[id] else { throw DecisionFailure.insufficientJudgment("선택한 ID의 원본 후보가 없습니다.") }
            output.selectedValues.append(value)
        }
        for binding in composition.bindings {
            if let when = binding.when, try !when.evaluate(in: context) { continue }
            output.bindings.append(.init(handler: binding.handler, arguments: try DecisionTemplate.resolve(binding.arguments, in: context)))
        }
        return output
    }
}
private struct DecisionPreparedStage: Sendable {
    var id: String
    var state: DecisionJSON
    var questions: [DecisionQuestion]
    var materialIDs: [String]
}
private struct DecisionBatch: Sendable {
    var request: DecisionRequest
    var locations: [String: (stage: String, question: String)]
    var versionKey: String
}
private struct DecisionBatchOutcome: Sendable {
    var responses: [(DecisionRequest, DecisionResponse)] = []
    var traces: [DecisionTrace] = []
    var failure: DecisionFailure?
    var cancelled = false
}
public struct DecisionProgress: Sendable {
    public let completedStages: Int
    public let totalStages: Int
    public let message: String
}
public actor DecisionEngine {
    private var cache: [String: DecisionResponse] = [:]
    public init() {}
    public func clearCache() { cache.removeAll() }
    public func execute(profile: DecisionProfile, input: DecisionInput, service: any DecisionService,
                        progress: (@Sendable (DecisionProgress) async -> Void)? = nil,
                        materialResolver: (@Sendable (String) async throws -> DecisionJSON)? = nil) async -> DecisionResult {
        let start = Date()
        var result = DecisionResult(status: .succeeded, profile: profile, inputFingerprint: input.fingerprint, evidence: input.evidence,
                                    stages: [:], traces: [], composed: .init(), startedAt: start, completedAt: start)
        do {
            try profile.validate()
            guard input.state.isState else { throw DecisionFailure.insufficientInput("문자열·객체·배열 입력이 필요합니다.") }
            var completed: Set<String> = []
            while completed.count < profile.plan.stages.count {
                try Task.checkCancellation()
                let context = result.context(input: input.state)
                let ready = profile.plan.stages.filter { !completed.contains($0.id) && Set($0.dependencies).isSubset(of: completed) }
                var prepared: [DecisionPreparedStage] = []
                for stage in ready {
                    if let when = stage.when, try !when.evaluate(in: context) {
                        result.stages[stage.id] = .init(questions: [:], answers: [:], materialIDs: [], skipped: true); completed.insert(stage.id); continue
                    }
                    var state = try DecisionTemplate.resolve(stage.state, in: context)
                    var ids: [String] = []
                    if let template = stage.materialIDs {
                        let resolved = try DecisionTemplate.resolve(template, in: context)
                        if let id = resolved.string { ids = [id] }
                        else if let array = resolved.array, array.allSatisfy({ $0.string != nil }) { ids = array.compactMap(\.string) }
                        else { throw DecisionFailure.insufficientInput("\(stage.id): 자료 ID는 문자열 또는 문자열 배열이어야 합니다.") }
                        var materials: [DecisionJSON] = []
                        for id in ids {
                            let body: DecisionJSON
                            if let loaded = input.materials[id] { body = loaded }
                            else if input.evidence.contains(where: { $0.id == id }), let materialResolver { body = try await materialResolver(id) }
                            else { throw DecisionFailure.insufficientInput("등록하지 않았거나 읽을 수 없는 자료: \(id)") }
                            result.readMaterialIDs.insert(id)
                            materials.append(.object(["id": .string(id), "body": body]))
                        }
                        state = .object(["base": state, "evidence": .array(materials)])
                    }
                    var questions = stage.questions
                    for index in questions.indices {
                        questions[index].spec.instructions = try DecisionTemplate.resolve(questions[index].spec.instructions, in: context)
                        if let criteria = questions[index].spec.criteria { questions[index].spec.criteria = try DecisionTemplate.resolve(criteria, in: context) }
                        let question = questions[index]
                        try question.spec.validate(path: "단계 \(stage.id), 질문 \(question.id)")
                        if question.spec.type == .score, question.spec.criteria?.array?.count == 1,
                           profile.composition.candidates.contains(where: { candidate in candidate.axes.contains { $0.answer.stage == stage.id && $0.answer.question == question.id } }) {
                            throw DecisionFailure.invalid("\(stage.id)/\(question.id): 순위 계산에는 2개 이상의 Score 단계가 필요합니다.")
                        }
                    }
                    guard state.isState else { throw DecisionFailure.insufficientInput("\(stage.id): state 형식 오류") }
                    prepared.append(.init(id: stage.id, state: state, questions: questions, materialIDs: ids))
                }
                guard !prepared.isEmpty || !ready.isEmpty else { throw DecisionFailure.invalid("실행할 수 있는 단계가 없습니다.") }
                // Same-state independent stages share one mixed request. Other states run concurrently.
                var buckets: [DecisionJSON: [DecisionPreparedStage]] = [:]
                for stage in prepared { buckets[stage.state, default: []].append(stage) }
                let batches = buckets.values.sorted { ($0.first?.id ?? "") < ($1.first?.id ?? "") }.map { stages -> DecisionBatch in
                    var questions: [String: QuestionSpec] = [:], locations: [String: (stage: String, question: String)] = [:]
                    for stage in stages.sorted(by: { $0.id < $1.id }) {
                        for question in stage.questions { let id = "q\(questions.count)"; questions[id] = question.spec; locations[id] = (stage.id, question.id) }
                    }
                    let versions = stages.sorted(by: { $0.id < $1.id }).flatMap { stage in stage.questions.map { "\(stage.id)/\($0.id):\($0.revision):\($0.criteriaRevision)" } }.joined(separator: "|")
                    return .init(request: .init(state: stages[0].state, model: profile.model, questions: questions), locations: locations, versionKey: versions)
                }
                await progress?(.init(completedStages: completed.count, totalStages: profile.plan.stages.count, message: "\(batches.count)개 요청 실행"))
                let outcomes = await withTaskGroup(of: (Int, DecisionBatchOutcome).self) { group in
                    for (index, batch) in batches.enumerated() {
                        let cached = batch.request.cacheableModel ? cache[input.fingerprint + batch.request.fingerprint + batch.versionKey] : nil
                        group.addTask {
                            if let cached { return (index, .init(responses: [(batch.request, cached)], traces: [.init(request: batch.request, response: cached, cached: true)])) }
                            return (index, await Self.evaluate(batch.request, service: service))
                        }
                    }
                    var values: [(Int, DecisionBatchOutcome)] = []
                    for await value in group { values.append(value); if value.1.failure != nil || value.1.cancelled { group.cancelAll() } }
                    return values.sorted { $0.0 < $1.0 }
                }
                for (index, outcome) in outcomes {
                    let batch = batches[index]
                    result.traces += outcome.traces
                    for (request, response) in outcome.responses {
                        if request.cacheableModel, request.model == response.model { cache[input.fingerprint + request.fingerprint + batch.versionKey] = response }
                        for (key, answer) in response.answers {
                            guard let location = batch.locations[key], let stage = prepared.first(where: { $0.id == location.stage }) else { continue }
                            if result.stages[stage.id] == nil { result.stages[stage.id] = .init(questions: Dictionary(uniqueKeysWithValues: stage.questions.map { ($0.id, $0) }), answers: [:], materialIDs: stage.materialIDs, skipped: false) }
                            result.stages[stage.id]?.answers[location.question] = answer
                        }
                    }
                }
                if let failure = outcomes.compactMap({ $0.1.failure }).first { throw failure }
                if outcomes.contains(where: { $0.1.cancelled }) { throw CancellationError() }
                try Task.checkCancellation()
                for stage in prepared {
                    for question in stage.questions {
                        guard let answer = result.stages[stage.id]?.answers[question.id] else { throw DecisionFailure.malformedResponse("질문 누락: \(stage.id)/\(question.id)") }
                        if let minimum = question.minimumConfidence, let confidence = answer.confidence, confidence < minimum { throw DecisionFailure.insufficientJudgment("\(stage.id)/\(question.id): confidence \(confidence) < \(minimum)") }
                    }
                    completed.insert(stage.id)
                }
                await progress?(.init(completedStages: completed.count, totalStages: profile.plan.stages.count, message: "\(completed.count)/\(profile.plan.stages.count) 단계 완료"))
            }
            result.composed = try DecisionComposer.compose(profile.composition, stages: result.stages, context: result.context(input: input.state))
        } catch is CancellationError { result.status = .cancelled; result.detail = "판단을 취소했습니다." }
        catch let error as DecisionFailure {
            result.detail = error.localizedDescription
            switch error { case .invalid: result.status = .invalidProfile; case .insufficientInput: result.status = .insufficientInput
            case .insufficientJudgment: result.status = .insufficientJudgment; case .inputAdjustment: result.status = .inputAdjustment
            case .stale: result.status = .stale
            default: result.status = .apiError }
        } catch { result.status = .apiError; result.detail = error.localizedDescription }
        result.completedAt = Date()
        return result
    }
    private static func evaluate(_ request: DecisionRequest, service: any DecisionService) async -> DecisionBatchOutcome {
        do {
            try Task.checkCancellation()
            let response = try await service.evaluate(request)
            try Task.checkCancellation()
            return .init(responses: [(request, response)], traces: [.init(request: request, response: response)])
        } catch is CancellationError { return .init(traces: [.init(request: request, error: "취소")], cancelled: true) }
        catch let error as DecisionResponseFailure { return .init(traces: [.init(request: request, error: error.localizedDescription, rawErrorResponse: error.rawData)], failure: error.failure) }
        catch let failure as DecisionFailure {
            let failedTrace = DecisionTrace(request: request, error: failure.localizedDescription)
            if case .inputAdjustment = failure, request.questions.count > 1 {
                // Only split independent questions after an actual service input-limit response.
                // Every split retains the complete state; one indivisible question requires user adjustment.
                let ids = request.questions.keys.sorted(), middle = ids.count / 2
                var combined = DecisionBatchOutcome(traces: [failedTrace])
                for slice in [Array(ids[..<middle]), Array(ids[middle...])] {
                    let part = DecisionRequest(state: request.state, model: request.model, questions: Dictionary(uniqueKeysWithValues: slice.map { ($0, request.questions[$0]!) }))
                    let outcome = await evaluate(part, service: service)
                    combined.responses += outcome.responses; combined.traces += outcome.traces
                    if let failure = outcome.failure { combined.failure = failure; break }
                    if outcome.cancelled { combined.cancelled = true; break }
                }
                return combined
            }
            return .init(traces: [failedTrace], failure: failure)
        } catch { return .init(traces: [.init(request: request, error: error.localizedDescription)], failure: .transport(error.localizedDescription)) }
    }
}
