import SwiftUI
import MaestroCore

struct DecisionStageEditor: View {
    @Binding var stage: DecisionStage
    let allStages: [DecisionStage]
    let onDelete: () -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack { Text("단계 \(stage.id)").font(.headline); Spacer(); Button("단계 삭제", role: .destructive, action: onDelete) }
                Text("의존 단계가 없는 질문은 병렬로 실행합니다. 같은 state를 사용하는 독립 단계의 질문은 한 요청으로 묶습니다.").font(.caption).foregroundStyle(.secondary)
                if allStages.count > 1 {
                    GroupBox("먼저 완료할 단계") { VStack(alignment: .leading) { ForEach(allStages.filter { $0.id != stage.id }) { other in
                        Toggle(other.id, isOn: Binding(get: { stage.dependencies.contains(other.id) }, set: { selected in if selected { stage.dependencies.append(other.id) } else { stage.dependencies.removeAll { $0 == other.id } } }))
                    } }.frame(maxWidth: .infinity, alignment: .leading).padding(6) }
                }
                Toggle("조건이 맞을 때만 실행", isOn: Binding(get: { stage.when != nil }, set: { stage.when = $0 ? .predicate(.init(lhs: .numeric(1), rhs: .numeric(0.5))) : nil }))
                if stage.when != nil { DecisionConditionEditor(condition: Binding(get: { stage.when! }, set: { stage.when = $0 })) }
                DecisionJSONEditor("state · /input 또는 이전 답 참조", value: $stage.state)
                Text(#"참조 예: {"$ref":"/input"}, {"$ref":"/steps/evaluate/answers/relevance/score"}. 이전 답을 읽는 단계는 해당 의존 단계를 지정하세요."#).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Text(#"이전 선택값으로 후보 조회: {"$lookup":{"source":{"$ref":"/input/children"},"key":{"$ref":"/steps/select/answers/target/choice"}}}"#).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Toggle("후속 자료 본문 읽기", isOn: Binding(get: { stage.materialIDs != nil }, set: { stage.materialIDs = $0 ? .array([]) : nil }))
                if stage.materialIDs != nil {
                    DecisionJSONEditor("등록한 자료 ID · 문자열, 배열 또는 $ref", value: Binding(get: { stage.materialIDs! }, set: { stage.materialIDs = $0 }))
                }
                Divider()
                ForEach(stage.questions.indices, id: \.self) { index in
                    DecisionQuestionEditor(question: $stage.questions[index], onDelete: { stage.questions.remove(at: index) })
                }
                Menu("질문 추가") { ForEach(DecisionQuestionType.allCases, id: \.self) { type in Button(type.rawValue.capitalized) {
                    stage.questions.append(.init(id: "q_" + UUID().uuidString.prefix(8), spec: QuestionSpec.defaultSpec(type)))
                } } }
            }.padding(16)
        }
    }
}
struct DecisionQuestionEditor: View {
    @Binding var question: DecisionQuestion
    let onDelete: () -> Void
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    TextField("질문 ID", text: $question.id).textFieldStyle(.roundedBorder)
                    Picker("종류", selection: $question.spec.type) { ForEach(DecisionQuestionType.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }.frame(width: 180)
                    Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }.help("질문 삭제")
                }
                if question.spec.instructions.string != nil {
                    Text("질문").font(.callout.weight(.medium))
                    TextEditor(text: Binding(get: { question.spec.instructions.string ?? "" }, set: { question.spec.instructions = .string($0) })).frame(height: 70).border(.separator)
                }
                DisclosureGroup("구조화된 instructions 편집") { DecisionJSONEditor("문자열·객체·배열·null", value: $question.spec.instructions) }
                if question.spec.type != .noul || question.spec.criteria != nil {
                    DecisionJSONEditor(question.spec.type == .score ? "순서가 있는 단계 배열 · 1–10개" : question.spec.type == .choice ? "선택지 ID → 설명 객체 · 최대 255개" : "true·false 기준 객체 또는 null", value: Binding(get: { question.spec.criteria ?? .object([:]) }, set: { question.spec.criteria = $0 }))
                }
                if question.spec.type == .score {
                    Text("각 단계에는 문자열·객체·배열 설명이 필요합니다. 단계 자체의 null은 지원하지 않습니다. 1단계 결과는 조회할 수 있으며, 순위와 가중 평균에는 2단계 이상이 필요합니다.").font(.caption).foregroundStyle(.secondary)
                }
                if let validationMessage { Text(validationMessage).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                if question.spec.type == .noul { Toggle("true·false 기준 지정", isOn: Binding(get: { question.spec.criteria != nil }, set: { question.spec.criteria = $0 ? .object(["true": .null, "false": .null]) : nil })) }
                else {
                    HStack {
                        Toggle("최소 confidence 검사", isOn: Binding(get: { question.minimumConfidence != nil }, set: { question.minimumConfidence = $0 ? 0.7 : nil }))
                        if question.minimumConfidence != nil { TextField("0–1", value: Binding(get: { question.minimumConfidence! }, set: { question.minimumConfidence = $0 }), format: .number).textFieldStyle(.roundedBorder).frame(width: 90) }
                    }
                }
                Text("질문 v\(question.revision) · 기준 v\(question.criteriaRevision)").font(.caption).foregroundStyle(.secondary)
            }.padding(6)
        }.onChange(of: question.spec.type) { _, type in question.spec.criteria = QuestionSpec.defaultSpec(type).criteria; question.minimumConfidence = nil }
    }
    private var validationMessage: String? {
        // References are checked after resolution by the execution plan.
        guard DecisionTemplate.pointers(in: question.spec.instructions).isEmpty,
              (question.spec.criteria.map(DecisionTemplate.pointers) ?? []).isEmpty else { return nil }
        do { try question.spec.validate(path: "질문 \(question.id)"); return nil }
        catch { return error.localizedDescription }
    }
}
struct DecisionConditionEditor: View {
    @Binding var condition: DecisionCondition
    @State private var advanced = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if case .predicate = condition, !advanced {
                DecisionJSONEditor("조건의 왼쪽 값 또는 $ref", value: Binding(get: { predicate.lhs }, set: { var value = predicate; value.lhs = $0; condition = .predicate(value) }))
                Picker("비교", selection: Binding(get: { predicate.comparison }, set: { var value = predicate; value.comparison = $0; condition = .predicate(value) })) { ForEach(DecisionComparison.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                if predicate.comparison != .exists { DecisionJSONEditor("조건의 오른쪽 값", value: Binding(get: { predicate.rhs }, set: { var value = predicate; value.rhs = $0; condition = .predicate(value) })) }
            } else {
                DecisionJSONEditor("복합 조건 · all / any / not", value: Binding(get: { (try? DecisionJSON.value(condition)) ?? .null }, set: { if let value = try? JSONDecoder().decode(DecisionCondition.self, from: $0.data()) { condition = value } }), validate: { _ = try JSONDecoder().decode(DecisionCondition.self, from: $0.data()) })
                Text("복합 조건은 Profile JSON의 DecisionCondition 형식으로 입력합니다.").font(.caption).foregroundStyle(.secondary)
            }
            Toggle("복합 조건 JSON 편집", isOn: $advanced).controlSize(.small)
        }.padding(8).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
    }
    private var predicate: DecisionPredicate { if case .predicate(let value) = condition { return value }; return .init(lhs: .numeric(1)) }
}
struct DecisionCompositionEditor: View {
    @Binding var composition: DecisionComposition
    let stages: [DecisionStage]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("판단값과 결과 규칙").font(.headline)
                Text("순위는 정규화한 Score 또는 Noul의 가중 평균을 사용합니다. 필수 조건은 가중합과 별도로 검사합니다. Choice는 지정한 후보에서 원본 값을 선택할 때 사용합니다.").font(.callout).foregroundStyle(.secondary)
                HStack { Toggle("최소 순위 점수", isOn: Binding(get: { composition.minimumScore != nil }, set: { composition.minimumScore = $0 ? 0.5 : nil })); if composition.minimumScore != nil { TextField("0–1", value: Binding(get: { composition.minimumScore! }, set: { composition.minimumScore = $0 }), format: .number).frame(width: 100).textFieldStyle(.roundedBorder) } }
                ForEach(composition.candidates.indices, id: \.self) { index in candidateEditor(index) }
                Button("순위 후보 추가") {
                    if let ref = numericReferences.first { composition.candidates.append(.init(id: "candidate_" + UUID().uuidString.prefix(8), value: .null, axes: [.init(answer: ref)])) }
                }.disabled(numericReferences.isEmpty)
                Divider()
                Text("독립 라벨").font(.headline)
                ForEach(composition.labels.indices, id: \.self) { index in GroupBox { VStack(alignment: .leading) {
                    HStack { TextField("라벨", text: $composition.labels[index].label); Button("삭제", role: .destructive) { composition.labels.remove(at: index) } }
                    DecisionConditionEditor(condition: $composition.labels[index].when)
                }.padding(6) } }
                Button("라벨 추가") { composition.labels.append(.init(label: "새 라벨", when: .predicate(.init(lhs: .numeric(1))))) }
                Divider()
                Text("원본 값 선택").font(.headline)
                ForEach(composition.selections.indices, id: \.self) { index in GroupBox { VStack {
                    HStack { referencePicker("Choice", reference: $composition.selections[index].answer, references: choiceReferences); Button("삭제", role: .destructive) { composition.selections.remove(at: index) } }
                    DecisionJSONEditor("선택지 ID → 원본 값 또는 $ref", value: $composition.selections[index].values)
                }.padding(6) } }
                Button("원본 선택 추가") { if let ref = choiceReferences.first { composition.selections.append(.init(answer: ref, values: .object([:]))) } }.disabled(choiceReferences.isEmpty)
                Divider()
                Text("업무 handler 연결").font(.headline)
                Text("handler 실행은 결과 화면에서 직접 요청합니다. 초안 준비는 사용자가 선택한 대상과 기존 초안을 검사합니다.").font(.caption).foregroundStyle(.secondary)
                ForEach(composition.bindings.indices, id: \.self) { index in GroupBox { VStack(alignment: .leading) {
                    HStack { TextField("handler 이름", text: $composition.bindings[index].handler); Menu("앱 handler") { ForEach(["copyValue", "openContext", "compareSessions", "prepareDraft"], id: \.self) { handler in Button(handler) { composition.bindings[index].handler = handler } } }; Button("삭제", role: .destructive) { composition.bindings.remove(at: index) } }
                    DecisionJSONEditor("인수 · 알려진 값 또는 $ref", value: $composition.bindings[index].arguments)
                    Toggle("사용 조건 지정", isOn: Binding(get: { composition.bindings[index].when != nil }, set: { composition.bindings[index].when = $0 ? .predicate(.init(lhs: .numeric(1))) : nil }))
                    if composition.bindings[index].when != nil { DecisionConditionEditor(condition: Binding(get: { composition.bindings[index].when! }, set: { composition.bindings[index].when = $0 })) }
                }.padding(6) } }
                Button("handler 추가") { composition.bindings.append(.init(handler: "copyValue", arguments: .object(["value": .string("선택할 원본")])) ) }
            }.padding(16)
        }
    }
    private func candidateEditor(_ index: Int) -> some View {
        GroupBox { VStack(alignment: .leading, spacing: 10) {
            HStack { TextField("후보 ID", text: $composition.candidates[index].id); Button("후보 삭제", role: .destructive) { composition.candidates.remove(at: index) } }
            DecisionJSONEditor("후보 원본 값", value: $composition.candidates[index].value)
            ForEach(composition.candidates[index].axes.indices, id: \.self) { axis in HStack {
                referencePicker("평가 질문", reference: $composition.candidates[index].axes[axis].answer, references: numericReferences)
                Text("가중치"); TextField("가중치", value: $composition.candidates[index].axes[axis].weight, format: .number).frame(width: 90).textFieldStyle(.roundedBorder)
                Button { composition.candidates[index].axes.remove(at: axis) } label: { Image(systemName: "minus.circle") }.help("평가 축 삭제")
            } }
            Button("평가 축 추가") { if let ref = numericReferences.first { composition.candidates[index].axes.append(.init(answer: ref)) } }.controlSize(.small)
            ForEach(composition.candidates[index].required.indices, id: \.self) { rule in VStack(alignment: .leading) {
                HStack { Text("필수 조건 \(rule + 1)"); Spacer(); Button("조건 삭제") { composition.candidates[index].required.remove(at: rule) }.controlSize(.small) }
                DecisionConditionEditor(condition: $composition.candidates[index].required[rule])
            } }
            Button("필수 조건 추가") { composition.candidates[index].required.append(.predicate(.init(lhs: .numeric(1)))) }.controlSize(.small)
        }.padding(6) }
    }
    private var numericReferences: [DecisionAnswerReference] { references { $0 != .choice } }
    private var choiceReferences: [DecisionAnswerReference] { references { $0 == .choice } }
    private func references(_ filter: (DecisionQuestionType) -> Bool) -> [DecisionAnswerReference] { stages.flatMap { stage in stage.questions.filter { filter($0.spec.type) }.map { .init(stage: stage.id, question: $0.id) } } }
    private func referencePicker(_ title: String, reference: Binding<DecisionAnswerReference>, references: [DecisionAnswerReference]) -> some View {
        Picker(title, selection: reference) { ForEach(references, id: \.self) { ref in Text("\(ref.stage) / \(ref.question)").tag(ref) } }
    }
}
private extension QuestionSpec {
    static func defaultSpec(_ type: DecisionQuestionType) -> Self {
        .init(type: type, instructions: .string("판단할 질문"), criteria: type == .choice ? .object(["a": .null, "b": .null]) : type == .score ? .array([.string("낮음"), .string("높음")]) : nil)
    }
}
