import XCTest
import Foundation
@testable import MaestroCore

final class DecisionContractTests: XCTestCase {
    func testJSONRoundTripPreservesUnicodeLargeIntegerAndArrayOrder() throws {
        let input = try DecisionJSON.parse(#"{"id":9007199254740993,"nested":[{"문장":"한글 👨‍👩‍👧‍👦"},null,false,[3,2,1]],"decimal":0.1234567890123456789}"#)
        let decoded = try JSONDecoder().decode(DecisionJSON.self, from: input.data())
        XCTAssertEqual(input, decoded)
        XCTAssertEqual(input["id"], .number(Decimal(string: "9007199254740993")!))
        XCTAssertEqual(input.at("/nested/3/1"), .number(2))
        XCTAssertEqual(try DecisionJSON.parse(#"{"a/b":{"~key":"exact"}}"#).at("/a~1b/~0key"), .string("exact"))
        XCTAssertNil(input.at("/nested/-1"))
    }
    func testAllWireInputShapesAndMixedQuestions() throws {
        let choice = QuestionSpec(type: .choice, instructions: .object(["question": .string("route"), "facts": .array([.string("a")])]), criteria: .object(["null": .null, "structured": .object(["role": .string("review")])]))
        let score = QuestionSpec(type: .score, instructions: .array([.string("evaluate"), .object(["rubric": .string("ordered")])]), criteria: .array([.object(["level": .string("low"), "example": .null]), .object(["level": .string("high")])]))
        let noul = QuestionSpec(type: .noul, instructions: .null, criteria: .object(["true": .null, "false": .array([.string("absent")])]))
        for state in [DecisionJSON.string("plain"), .object(["facts": .array([.number(3), .null])]), .array([.string("ordered"), .bool(true)])] {
            let request = DecisionRequest(state: state, model: "jev-latest", questions: ["route": choice, "score": score, "yes": noul, "implicit": .init(type: .noul, instructions: .string("yes?"))])
            try request.validate()
            let json = try DecisionJSON.value(request)
            XCTAssertEqual(json["state"], state)
            XCTAssertEqual(json.at("/questions/route/criteria/null"), .null)
            XCTAssertEqual(json.at("/questions/score/criteria"), score.criteria)
            XCTAssertNil(json.at("/questions/implicit/criteria"))
            XCTAssertEqual(try JSONDecoder().decode(DecisionRequest.self, from: json.data()), request)
        }
    }
    func testOnlyServiceRubricLimitsAreEnforced() throws {
        let entries = Dictionary(uniqueKeysWithValues: (0..<255).map { (String($0), DecisionJSON.null) })
        try QuestionSpec(type: .choice, instructions: .string("pick"), criteria: .object(entries)).validate()
        var tooMany = entries; tooMany["extra"] = .null
        XCTAssertThrowsError(try QuestionSpec(type: .choice, instructions: .string("pick"), criteria: .object(tooMany)).validate())
        for count in [1, 2, 10] { try QuestionSpec(type: .score, instructions: .string("rate"), criteria: .array(Array(repeating: .string("level"), count: count))).validate() }
        for count in [0, 11] { XCTAssertThrowsError(try QuestionSpec(type: .score, instructions: .string("rate"), criteria: .array(Array(repeating: .string("level"), count: count))).validate()) }
        XCTAssertThrowsError(try DecisionRequest(state: .null, model: "jev-latest", questions: ["q": .init(type: .noul, instructions: .string("q"))]).validate())
    }
    func testFullTypedResponseAndUnknownFieldsAreRetainedWithoutExecutionExposure() throws {
        let request = DecisionRequest(state: .string("input"), model: "jev-latest", questions: [
            "route": .init(type: .choice, instructions: .string("pick"), criteria: .object(["a": .null, "b": .null])),
            "rank": .init(type: .score, instructions: .string("rank"), criteria: .array([.object(["low": .null]), .object(["high": .bool(true)])])),
            "label": .init(type: .noul, instructions: .string("label"))])
        let data = Data(#"{"model":"jev-1.13.0","answers":{"route":{"type":"choice","choice":"a","probabilities":{"a":0.8,"b":0.2},"confidence":0.7,"future":"ignored"},"rank":{"type":"score","score":0.8,"probabilities":{"0":0.2,"1":0.8},"confidence":0.7,"legend":{"0":{"low":null},"1":{"high":true}}},"label":{"type":"noul","noul":0.9},"futureQuestion":{"type":"future","arbitrary":true}},"usage":{"input_tokens":100,"output_tokens":20,"new_usage":1},"future_top":[1,2]}"#.utf8)
        let response = try DecisionResponse.decode(data, for: request)
        XCTAssertEqual(response.rawData, data)
        XCTAssertEqual(response.model, "jev-1.13.0")
        XCTAssertEqual(response.answers.count, 3)
        XCTAssertNil(response.answers["label"]?.confidence)
        XCTAssertEqual(response.raw.at("/answers/route/future"), .string("ignored"))
        XCTAssertNil(response.answers["route"]?.json["future"])
        XCTAssertEqual(response.raw["future_top"], .array([.number(1), .number(2)]))
        XCTAssertEqual(try response.answers["rank"]?.normalized(for: request.questions["rank"]!), 0.8)
        XCTAssertThrowsError(try response.answers["route"]?.normalized(for: request.questions["route"]!))
    }
    func testMissingWrongTypeMalformedDistributionAndNoulRangeFail() throws {
        let request = DecisionRequest(state: .string("input"), model: "jev-latest", questions: ["q": .init(type: .noul, instructions: .string("q"))])
        for answer in [#"{}"#, #"{"q":{"type":"score","score":1}}"#, #"{"q":{"type":"noul","noul":"0.9"}}"#, #"{"q":{"type":"noul","noul":1.1}}"#] {
            let data = Data("{\"model\":\"jev-1.13.0\",\"answers\":\(answer),\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}".utf8)
            XCTAssertThrowsError(try DecisionResponse.decode(data, for: request))
        }
        let choice = DecisionRequest(state: .string("input"), model: "jev-latest", questions: ["q": .init(type: .choice, instructions: .string("pick"), criteria: .object(["a": .null, "b": .null]))])
        let invalid = Data(#"{"model":"jev-1.13.0","answers":{"q":{"type":"choice","choice":"a","probabilities":{"a":0.8},"confidence":0.7}},"usage":{"input_tokens":1,"output_tokens":1}}"#.utf8)
        XCTAssertThrowsError(try DecisionResponse.decode(invalid, for: choice))
    }
    func testModelAliasesNeverProduceReproducibleCacheKeys() {
        for model in ["jev-latest", "jev-preview", "future-alias"] { XCTAssertFalse(DecisionRequest(state: .string("s"), model: model, questions: [:]).cacheableModel) }
        XCTAssertTrue(DecisionRequest(state: .string("s"), model: "jev-1.13.0", questions: [:]).cacheableModel)
    }
    func testOptionalInstructionsDecodeAndExplicitNullCriteriaRoundTrip() throws {
        let request = try JSONDecoder().decode(DecisionRequest.self, from: Data(#"{"state":"synthetic","model":"jev-latest","questions":{"choice":{"type":"choice","criteria":{"synthetic":null}},"score":{"type":"score","criteria":["only level"]},"noul":{"type":"noul","criteria":{"true":"synthetic"}},"nullable":{"type":"noul","instructions":"Is this synthetic?","criteria":null}}}"#.utf8))
        try request.validate()
        XCTAssertEqual(request.questions["choice"]?.instructions, .null)
        XCTAssertEqual(request.questions["nullable"]?.criteria, .null)
        XCTAssertEqual(try JSONDecoder().decode(DecisionRequest.self, from: DecisionJSON.value(request).data()), request)
        XCTAssertNil(try DecisionJSON.value(QuestionSpec(type: .noul, instructions: .string("question")))["criteria"])
    }
    func testScoreRejectsNullAndScalarLevelsWithEscapedQuestionAndIndexPath() throws {
        for level in [DecisionJSON.null, .number(0), .bool(false)] {
            let request = DecisionRequest(state: .string("synthetic"), model: "jev-latest", questions: ["a/b~c": .init(type: .score, criteria: .array([.string("low"), level]))])
            XCTAssertThrowsError(try request.validate()) { error in
                XCTAssertTrue(error.localizedDescription.contains("/questions/a~1b~0c/criteria/1"))
            }
        }
        try QuestionSpec(type: .score, criteria: .array([.object(["example": .null]), .array([.null, .number(1), .bool(true)])])).validate()
    }
    func testNoulDefinitionMatchesObservedNullAndEmptyBoundaries() throws {
        for instructions in [DecisionJSON.null, .string(""), .array([]), .object([:])] {
            for criteria in [Optional<DecisionJSON>.none, .null, .object([:]), .object(["true": .null, "false": .null])] {
                XCTAssertThrowsError(try QuestionSpec(type: .noul, instructions: instructions, criteria: criteria).validate())
            }
        }
        for criteria in [Optional<DecisionJSON>.none, .null, .object([:]), .object(["true": .null, "false": .null])] {
            try QuestionSpec(type: .noul, instructions: .string("Is this synthetic?"), criteria: criteria).validate()
        }
        for value in [DecisionJSON.string(""), .object([:]), .array([]), .string("synthetic"), .object(["marker": .null]), .array([.null])] {
            try QuestionSpec(type: .noul, criteria: .object(["true": value, "false": .null])).validate()
        }
        try QuestionSpec(type: .noul, criteria: .object(["false": .string("actual")])).validate()
        try QuestionSpec(type: .noul, instructions: .string("   ")).validate()
    }
    func testSingleLevelScoreDecodesButCannotBeNormalized() throws {
        let spec = QuestionSpec(type: .score, criteria: .array([.string("only level")]))
        let request = DecisionRequest(state: .string("synthetic"), model: "jev-latest", questions: ["q": spec])
        let response = try DecisionResponse.decode(DecisionFixtureService.response(for: request).data(), for: request)
        guard case .score(let value, _, _, _) = response.answers["q"] else { return XCTFail("missing score") }
        XCTAssertEqual(value, 0)
        XCTAssertThrowsError(try response.answers["q"]!.normalized(for: spec))
    }
    func testScoreLegendRejectsNullAndScalarDescriptions() throws {
        let request = DecisionRequest(state: .string("synthetic"), model: "jev-latest", questions: ["q": .init(type: .score, criteria: .array([.string("only level")]))])
        for description in [DecisionJSON.null, .number(0), .bool(false)] {
            var response = try DecisionFixtureService.response(for: request)
            var root = response.object!, answers = root["answers"]!.object!, answer = answers["q"]!.object!
            answer["legend"] = .object(["0": description]); answers["q"] = .object(answer); root["answers"] = .object(answers); response = .object(root)
            XCTAssertThrowsError(try DecisionResponse.decode(response.data(), for: request))
        }
    }
}

/// Synthesizes protocol fixtures, not semantic judgments. No network connection is used.
actor DecisionFixtureService: DecisionService {
    var requests: [DecisionRequest] = []
    let transform: @Sendable (DecisionRequest, Int) async throws -> DecisionJSON
    init(transform: @escaping @Sendable (DecisionRequest, Int) async throws -> DecisionJSON = { request, _ in try DecisionFixtureService.response(for: request) }) { self.transform = transform }
    func evaluate(_ request: DecisionRequest) async throws -> DecisionResponse {
        requests.append(request)
        return try DecisionResponse.decode(try await transform(request, requests.count).data(), for: request)
    }
    func models() async throws -> [DecisionModel] { [] }
    static func response(for request: DecisionRequest, model: String? = nil, noul: Double = 0.9) throws -> DecisionJSON {
        var answers: [String: DecisionJSON] = [:]
        for (id, spec) in request.questions {
            switch spec.type {
            case .noul: answers[id] = .object(["type": .string("noul"), "noul": .numeric(noul)])
            case .choice:
                let keys = (spec.criteria?.object ?? [:]).keys.sorted(), selected = keys[0]
                answers[id] = .object(["type": .string("choice"), "choice": .string(selected), "probabilities": .object(Dictionary(uniqueKeysWithValues: keys.map { ($0, .numeric($0 == selected ? 1 : 0)) })), "confidence": .numeric(1)])
            case .score:
                let values = spec.criteria!.array!, last = values.count - 1
                answers[id] = .object(["type": .string("score"), "score": .numeric(Double(last)), "confidence": .numeric(1), "legend": .object(Dictionary(uniqueKeysWithValues: values.enumerated().map { (String($0.offset), $0.element) })), "probabilities": .object(Dictionary(uniqueKeysWithValues: values.indices.map { (String($0), .numeric($0 == last ? 1 : 0)) }))])
            }
        }
        return .object(["model": .string(model ?? (request.cacheableModel ? request.model : "jev-1.13.0")), "answers": .object(answers), "usage": .object(["input_tokens": .number(10), "output_tokens": .number(5)])])
    }
}
