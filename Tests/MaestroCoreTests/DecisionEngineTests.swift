import XCTest
import Foundation
@testable import MaestroCore

@MainActor final class DecisionEngineTests: XCTestCase {
    func testSingleLevelScoreIsQueryableButStaticAndDynamicRankingAreBlockedBeforeHTTP() async throws {
        var profile = DecisionProfile(plan: .init(stages: [.init(id: "evaluate", questions: [.init(id: "score", spec: .init(type: .score, criteria: .array([.string("only level")])))] )]))
        let input = DecisionInput(state: .object(["rubric": .array([.string("only level")])]))
        let service = DecisionFixtureService()
        let raw = await DecisionEngine().execute(profile: profile, input: input, service: service)
        XCTAssertEqual(raw.status, .succeeded)
        XCTAssertEqual(raw.stages["evaluate"]?.answers["score"]?.json["score"], .number(0))
        profile.composition.candidates = [.init(id: "candidate", value: .string("source"), axes: [.init(answer: .init(stage: "evaluate", question: "score"))])]
        let blockedService = DecisionFixtureService()
        let fixed = await DecisionEngine().execute(profile: profile, input: input, service: blockedService)
        XCTAssertEqual(fixed.status, .invalidProfile)
        profile.plan.stages[0].questions[0].spec.criteria = .object(["$ref": .string("/input/rubric")])
        try profile.validate()
        let dynamic = await DecisionEngine().execute(profile: profile, input: input, service: blockedService)
        XCTAssertEqual(dynamic.status, .invalidProfile)
        XCTAssertTrue(dynamic.detail?.contains("evaluate/score") == true)
        let requests = await blockedService.requests
        XCTAssertTrue(requests.isEmpty)
    }
    func testResolvedInvalidNoulDefinitionStopsBeforeHTTPAndReportsTheQuestion() async {
        let profile = DecisionProfile(plan: .init(stages: [.init(id: "evaluate", questions: [.init(id: "missing", spec: .init(type: .noul, instructions: .object(["$ref": .string("/input/question")])))] )]))
        let service = DecisionFixtureService()
        let result = await DecisionEngine().execute(profile: profile, input: .init(state: .object(["question": .null])), service: service)
        XCTAssertEqual(result.status, .invalidProfile)
        XCTAssertTrue(result.detail?.contains("질문 missing/instructions") == true)
        let requests = await service.requests
        XCTAssertTrue(requests.isEmpty)
    }
    func testHTTPFailurePreservesRawTraceAndAPIErrorStatus() async {
        let data = Data(#"{"detail":"Noul question must have criteria or instructions: q0"}"#.utf8)
        let service = DecisionFixtureService { _, _ in throw DecisionResponseFailure(failure: .service(status: 400, body: String(decoding: data, as: UTF8.self)), rawData: data) }
        let result = await DecisionEngine().execute(profile: .starter, input: .init(state: .string("synthetic")), service: service)
        XCTAssertEqual(result.status, .apiError)
        XCTAssertEqual(result.traces.first?.rawErrorResponse, data)
        XCTAssertTrue(result.detail?.contains("Noul question must have criteria or instructions") == true)
        XCTAssertTrue(result.composed.bindings.isEmpty)
    }
    private func yes(_ id: String = "q", instruction: String = "question") -> DecisionQuestion { .init(id: id, spec: .init(type: .noul, instructions: .string(instruction))) }
    private let input = DecisionInput(state: .object(["goal": .string("검토"), "records": .array([.string("본문")])]))
    func testSameStateIndependentStagesBecomeOneMixedBatchWithoutIDCollisions() async {
        let profile = DecisionProfile(plan: .init(stages: [.init(id: "a", questions: [yes()]), .init(id: "b", questions: [.init(id: "q", spec: .init(type: .score, instructions: .string("rate"), criteria: .array([.string("low"), .string("high")]))), .init(id: "route", spec: .init(type: .choice, instructions: .string("route"), criteria: .object(["target": .null])))])]))
        let service = DecisionFixtureService(), result = await DecisionEngine().execute(profile: profile, input: input, service: service)
        let requests = await service.requests
        XCTAssertEqual(result.status, .succeeded)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].questions.count, 3)
        XCTAssertNotNil(result.stages["a"]?.answers["q"])
        XCTAssertNotNil(result.stages["b"]?.answers["q"])
        XCTAssertEqual(result.usage.input_tokens, 10)
    }
    func testDifferentStatesRunInParallel() async {
        actor Gate {
            var arrived = 0
            var waiters: [CheckedContinuation<Void, Never>] = []
            func enter() async { arrived += 1; if arrived == 2 { for waiter in waiters { waiter.resume() }; waiters.removeAll() } else { await withCheckedContinuation { waiters.append($0) } } }
        }
        let gate = Gate()
        let service = DecisionFixtureService { request, _ in await gate.enter(); return try DecisionFixtureService.response(for: request) }
        let profile = DecisionProfile(plan: .init(stages: [.init(id: "a", state: .string("A"), questions: [yes()]), .init(id: "b", state: .string("B"), questions: [yes()])]))
        let result = await DecisionEngine().execute(profile: profile, input: input, service: service)
        XCTAssertEqual(result.status, .succeeded)
        let count = await service.requests.count; XCTAssertEqual(count, 2)
    }
    func testHierarchyLoadsSelectedFullMaterialAndBuildsDynamicFollowupCriteria() async {
        let profile = DecisionProfile(plan: .init(stages: [
            .init(id: "choose", questions: [.init(id: "source", spec: .init(type: .choice, instructions: .string("pick"), criteria: .object(["$ref": .string("/input/candidates")])))]),
            .init(id: "verify", dependencies: ["choose"], state: .object(["selected": .object(["$ref": .string("/steps/choose/answers/source/choice")]), "goal": .object(["$ref": .string("/input/goal")])]), materialIDs: .object(["$ref": .string("/steps/choose/answers/source/choice")]), questions: [yes("verified")])
        ]), composition: .init(selections: [.init(answer: .init(stage: "choose", question: "source"), values: .object(["$ref": .string("/input/originals")]))], bindings: [.init(handler: "known-handler", arguments: .object(["$ref": .string("/steps/choose/answers/source/choice")]))]))
        let full = String(repeating: "전체 원문👨‍👩‍👧‍👦\n", count: 5000)
        let input = DecisionInput(state: .object(["goal": .string("검증"), "candidates": .object(["record": .object(["summary": .string("요약")])]), "originals": .object(["record": .string("원문 그대로")])]), materials: ["record": .string(full)], evidence: [.init(id: "record", coverage: "full", fingerprint: DecisionJSON.string(full).fingerprint)])
        let service = DecisionFixtureService(), result = await DecisionEngine().execute(profile: profile, input: input, service: service)
        let requests = await service.requests
        XCTAssertEqual(result.status, .succeeded)
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[1].state.at("/evidence/0/body"), .string(full))
        XCTAssertEqual(requests[1].state.at("/base/goal"), .string("검증"))
        XCTAssertEqual(result.composed.selectedValues, [.string("원문 그대로")])
        XCTAssertEqual(result.composed.bindings.first?.handler, "known-handler")
        XCTAssertEqual(result.evidence, input.evidence)
    }
    func testBranchingAndIndependentLabelsUseExplicitRules() async {
        let rule = DecisionCondition.predicate(.init(lhs: .object(["$ref": .string("/steps/base/answers/q/noul")]), rhs: .numeric(0.8)))
        let profile = DecisionProfile(plan: .init(stages: [.init(id: "base", questions: [yes()]), .init(id: "yesBranch", dependencies: ["base"], when: rule, questions: [yes()]), .init(id: "noBranch", dependencies: ["base"], when: .not(rule), questions: [yes()])]), composition: .init(labels: [.init(label: "제약", when: rule), .init(label: "검증", when: rule)]))
        let result = await DecisionEngine().execute(profile: profile, input: input, service: DecisionFixtureService())
        XCTAssertEqual(result.status, .succeeded)
        XCTAssertEqual(result.stages["noBranch"]?.skipped, true)
        XCTAssertEqual(result.stages["yesBranch"]?.skipped, false)
        XCTAssertEqual(result.composed.labels, ["제약", "검증"])
    }
    func testHierarchicalLookupBuildsNextCandidateSetFromPreviousChoice() async throws {
        func ref(_ pointer: String) -> DecisionJSON { .object(["$ref": .string(pointer)]) }
        let children = DecisionJSON.object(["$lookup": .object(["source": ref("/input/children"), "key": ref("/steps/project/answers/target/choice")])])
        let profile = DecisionProfile(plan: .init(stages: [
            .init(id: "project", questions: [.init(id: "target", spec: .init(type: .choice, instructions: .string("project"), criteria: ref("/input/projects")))]),
            .init(id: "record", dependencies: ["project"], state: children, questions: [.init(id: "target", spec: .init(type: .choice, instructions: .string("record"), criteria: children))])
        ]), composition: .init(selections: [.init(answer: .init(stage: "record", question: "target"), values: children)]))
        let source = DecisionInput(state: .object(["projects": .object(["p": .string("selected project")]), "children": .object(["p": .object(["r": .object(["text": .string("원문 그대로")])]), "other": .object(["unrelated": .null])])]))
        let service = DecisionFixtureService()
        let result = await DecisionEngine().execute(profile: profile, input: source, service: service)
        XCTAssertEqual(result.status, .succeeded)
        let requests = await service.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[1].questions.values.first?.criteria?.object?.keys.sorted(), ["r"])
        XCTAssertNil(requests[1].state["unrelated"])
        XCTAssertEqual(result.composed.selectedValues, [.object(["text": .string("원문 그대로")])])
        let arrayLookup = DecisionJSON.object(["$lookup": .object(["source": .array([.string("exact")]), "key": .number(0)])])
        XCTAssertEqual(try DecisionTemplate.resolve(arrayLookup, in: .null), .string("exact"))
        XCTAssertThrowsError(try DecisionTemplate.resolve(.object(["$lookup": .object(["source": .object([:]), "key": .string("missing")])]), in: .null))
        XCTAssertThrowsError(try DecisionTemplate.resolve(.object(["$lookup": .object(["source": .array([])])]), in: .null))
    }
    func testServiceLimitSplitsQuestionsAndPreservesEveryStateByte() async {
        let full = DecisionJSON.string(String(repeating: "goal+evidence 한글\n", count: 8000))
        let service = DecisionFixtureService { request, _ in
            if request.questions.count > 1 { throw DecisionFailure.inputAdjustment("token_limit_exceeded") }
            return try DecisionFixtureService.response(for: request)
        }
        let profile = DecisionProfile(plan: .init(stages: [.init(id: "batch", questions: (0..<9).map { yes("q\($0)") })]))
        let result = await DecisionEngine().execute(profile: profile, input: .init(state: full), service: service)
        let requests = await service.requests
        XCTAssertEqual(result.status, .succeeded)
        XCTAssertEqual(result.stages["batch"]?.answers.count, 9)
        XCTAssertTrue(requests.allSatisfy { $0.state == full })
        XCTAssertEqual(result.traces.count, 17)
    }
    func testIndivisibleLimitAndValidationFailureAreDistinct() async {
        let profile = DecisionProfile(plan: .init(stages: [.init(id: "one", questions: [yes()])]))
        let limited = DecisionFixtureService { _, _ in throw DecisionFailure.inputAdjustment("one question too large") }
        let result = await DecisionEngine().execute(profile: profile, input: input, service: limited)
        XCTAssertEqual(result.status, .inputAdjustment)
        let validation = DecisionFixtureService { _, _ in throw DecisionFailure.service(status: 422, body: "invalid rubric") }
        let error = await DecisionEngine().execute(profile: profile, input: input, service: validation)
        XCTAssertEqual(error.status, .apiError)
        let count = await validation.requests.count; XCTAssertEqual(count, 1)
    }
    func testPinnedVersionCacheRespectsInputRubricVersionAndAlias() async {
        let engine = DecisionEngine(), service = DecisionFixtureService()
        var profile = DecisionProfile(model: "jev-1.13.0", plan: .init(stages: [.init(id: "stage", questions: [yes()])]))
        _ = await engine.execute(profile: profile, input: input, service: service)
        let cached = await engine.execute(profile: profile, input: input, service: service)
        XCTAssertTrue(cached.traces[0].cached); XCTAssertEqual(cached.usage.input_tokens, 0)
        profile.plan.stages[0].questions[0].criteriaRevision += 1
        _ = await engine.execute(profile: profile, input: input, service: service)
        _ = await engine.execute(profile: profile, input: .init(state: .string("changed")), service: service)
        profile.model = "jev-latest"
        _ = await engine.execute(profile: profile, input: input, service: service)
        _ = await engine.execute(profile: profile, input: input, service: service)
        let count = await service.requests.count; XCTAssertEqual(count, 5)
        XCTAssertFalse(cached.isCurrent(input: .init(state: .string("changed")), profile: cached.profile))
        XCTAssertFalse(cached.isCurrent(input: input, profile: profile))
    }
    func testReturnedModelMismatchPreventsPinnedCacheReuse() async {
        let service = DecisionFixtureService { request, _ in try DecisionFixtureService.response(for: request, model: "jev-1.14.0") }
        let engine = DecisionEngine(), profile = DecisionProfile(model: "jev-1.13.0", plan: .init(stages: [.init(id: "s", questions: [yes()])]))
        _ = await engine.execute(profile: profile, input: input, service: service)
        let second = await engine.execute(profile: profile, input: input, service: service)
        XCTAssertFalse(second.traces[0].cached)
        let count = await service.requests.count; XCTAssertEqual(count, 2)
    }
    func testEvidenceFingerprintChangeInvalidatesCacheEvenWhenSummaryIsUnchanged() async {
        let engine = DecisionEngine(), service = DecisionFixtureService()
        let profile = DecisionProfile(model: "jev-1.13.0", plan: .init(stages: [.init(id: "s", questions: [yes()])]))
        var source = input
        source.evidence = [.init(id: "record", coverage: "summary", fingerprint: "original")]
        _ = await engine.execute(profile: profile, input: source, service: service)
        let same = await engine.execute(profile: profile, input: source, service: service)
        XCTAssertTrue(same.traces[0].cached)
        source.evidence[0].fingerprint = "changed"
        let fresh = await engine.execute(profile: profile, input: source, service: service)
        XCTAssertFalse(fresh.traces[0].cached)
        let count = await service.requests.count; XCTAssertEqual(count, 2)
    }
    func testReadCoverageIsPreservedWhenServiceFailsAfterMaterialLoading() async {
        let source = DecisionInput(state: input.state, materials: ["record": .string("full body")],
                                   evidence: [.init(id: "record", coverage: "summary", fingerprint: "content")])
        let profile = DecisionProfile(plan: .init(stages: [.init(id: "s", materialIDs: .string("record"), questions: [yes()])]))
        let service = DecisionFixtureService { _, _ in throw DecisionFailure.service(status: 529, body: "overloaded") }
        let result = await DecisionEngine().execute(profile: profile, input: source, service: service)
        XCTAssertEqual(result.status, .apiError)
        XCTAssertEqual(result.consultedEvidence.first?.coverage, "full")
        XCTAssertEqual(result.readMaterialIDs, ["record"])
        XCTAssertTrue(result.stages.isEmpty)
    }
    func testCancellationAndConfidenceInsufficiencyNeverBecomeSuccess() async {
        let service = DecisionFixtureService { request, _ in try await Task.sleep(for: .seconds(60)); return try DecisionFixtureService.response(for: request) }
        let engine = DecisionEngine(), profile = DecisionProfile(plan: .init(stages: [.init(id: "s", questions: [yes()])]))
        let task = Task { await engine.execute(profile: profile, input: input, service: service) }
        while await service.requests.isEmpty { await Task.yield() }
        task.cancel()
        let cancelled = await task.value; XCTAssertEqual(cancelled.status, .cancelled)
        var uncertain = DecisionProfile.starter; uncertain.plan.stages[0].questions[0].minimumConfidence = 0.9
        let low = DecisionFixtureService { request, _ in
            var root = try DecisionFixtureService.response(for: request).object!
            var answers = root["answers"]!.object!
            for (id, spec) in request.questions where spec.type == .score { var answer = answers[id]!.object!; answer["confidence"] = .numeric(0.2); answers[id] = .object(answer) }
            root["answers"] = .object(answers); return .object(root)
        }
        let result = await engine.execute(profile: uncertain, input: input, service: low)
        XCTAssertEqual(result.status, .insufficientJudgment)
        XCTAssertFalse(result.traces.isEmpty)
    }
    func testMissingMaterialMissingReferenceAndCyclicPlanFailBeforeInference() async {
        let service = DecisionFixtureService()
        let missing = DecisionProfile(plan: .init(stages: [.init(id: "s", materialIDs: .string("missing"), questions: [yes()])]))
        let result = await DecisionEngine().execute(profile: missing, input: input, service: service)
        XCTAssertEqual(result.status, .insufficientInput)
        let cyclic = DecisionProfile(plan: .init(stages: [.init(id: "a", dependencies: ["b"], questions: [yes()]), .init(id: "b", dependencies: ["a"], questions: [yes()])]))
        let invalid = await DecisionEngine().execute(profile: cyclic, input: input, service: service)
        XCTAssertEqual(invalid.status, .invalidProfile)
        let count = await service.requests.count; XCTAssertEqual(count, 0)
        XCTAssertThrowsError(try DecisionTemplate.resolve(.object(["$ref": .string("/input/missing")]), in: .object(["input": input.state])))
    }
    func testWeightedRanksNormalizeScoresAndMandatoryRuleCannotBeCompensated() async {
        var profile = DecisionProfile.starter
        let high = DecisionAxis(answer: .init(stage: "evaluate", question: "relevance"), weight: 100)
        let required = DecisionCondition.predicate(.init(lhs: .object(["$ref": .string("/steps/evaluate/answers/constraints/noul")]), rhs: .numeric(0.95)))
        profile.composition = .init(candidates: [.init(id: "blocked", value: .string("a"), axes: [high], required: [required]), .init(id: "eligible", value: .string("b"), axes: [.init(answer: .init(stage: "evaluate", question: "constraints"))])])
        let result = await DecisionEngine().execute(profile: profile, input: input, service: DecisionFixtureService())
        XCTAssertEqual(result.status, .succeeded)
        XCTAssertEqual(result.composed.ranks.map(\.id), ["eligible", "blocked"])
        XCTAssertEqual(result.composed.ranks[1].score, 1)
        XCTAssertFalse(result.composed.ranks[1].eligible)
        XCTAssertEqual(result.composed.ranks[0].score, 0.9)
    }
    func testChoiceCannotBeConfiguredForGlobalRankingAndNoulHasNoConfidenceGate() throws {
        var profile = DecisionProfile(plan: .init(stages: [.init(id: "s", questions: [.init(id: "route", spec: .init(type: .choice, instructions: .string("pick"), criteria: .object(["a": .null])))])]), composition: .init(candidates: [.init(id: "a", value: .string("a"), axes: [.init(answer: .init(stage: "s", question: "route"))])]))
        XCTAssertThrowsError(try profile.validate())
        profile.composition = .init(); profile.plan.stages[0].questions = [yes()]
        profile.plan.stages[0].questions[0].minimumConfidence = 0.5
        XCTAssertThrowsError(try profile.validate())
    }
    func testProfilePersistenceCloneExportAndCorruptionPreservation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = DecisionProfileRepository(url: directory.appendingPathComponent("profiles.json"))
        let profile = DecisionProfile.starter
        try repository.save([profile])
        XCTAssertEqual(try repository.load(), [profile])
        XCTAssertEqual(try DecisionProfileRepository.decodeProfile(DecisionProfileRepository.encodeProfile(profile)), profile)
        let permissions = try FileManager.default.attributesOfItem(atPath: repository.url.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
        let corrupt = Data("bad existing file".utf8); try corrupt.write(to: repository.url)
        XCTAssertThrowsError(try repository.save([]))
        XCTAssertEqual(try Data(contentsOf: repository.url), corrupt)
    }
}
