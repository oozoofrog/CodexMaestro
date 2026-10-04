import SwiftUI
import MaestroCore

struct DecisionWorkbenchView: View {
    @Bindable var maestro: MaestroStore
    @State private var store: DecisionWorkbenchStore
    @State private var tab = 0
    @State private var selectedStageID = ""
    @Environment(\.dismiss) private var dismiss
    init(maestro: MaestroStore) { self.maestro = maestro; _store = State(initialValue: DecisionWorkbenchStore(maestro: maestro)) }
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                profileList.frame(minWidth: 175, idealWidth: 200, maxWidth: 230)
                VStack(spacing: 0) {
                    Picker("화면", selection: $tab) { Text("실행").tag(0); Text("질문과 계획").tag(1); Text("결과 조합").tag(2); Text("원본 JSON").tag(3) }.pickerStyle(.segmented).padding()
                    Group {
                        switch tab { case 1: planEditor; case 2: DecisionCompositionEditor(composition: $store.profile.composition, stages: store.profile.plan.stages)
                        case 3: rawInspector; default: execution }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider()
            HStack {
                if store.running { ProgressView().controlSize(.small); Text(store.progress) }
                else if let error = store.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                else { Text(store.notice ?? "저장한 Profile을 선택하고 입력을 불러오세요.").foregroundStyle(.secondary) }
                Spacer()
                Button("닫기") { store.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
            }.font(.callout).padding(12)
        }.frame(width: 1130, height: 800)
            .onDisappear { store.cancel() }
            .onChange(of: store.sourceKind) { store.invalidateInput() }
            .onChange(of: store.sessionID) { store.recordID = ""; store.sourceNodes = []; store.invalidateInput() }
            .onChange(of: store.projectID) { store.invalidateInput() }
            .onChange(of: store.recordID) { store.invalidateInput() }
            .onChange(of: store.goal) { store.invalidateInput() }
            .onChange(of: store.manualJSON) { store.invalidateInput() }
    }
    private var header: some View {
        HStack {
            Image(systemName: "slider.horizontal.3").font(.title2)
            Text("사용자 정의 판단").font(.title2)
            Spacer()
            TextField("Profile 이름", text: $store.profile.name).textFieldStyle(.roundedBorder).frame(width: 260)
            Button("저장") { store.save() }.disabled(store.running)
            Button("복제") { store.clone() }.disabled(store.running)
        }.padding(16)
    }
    private var profileList: some View {
        VStack(alignment: .leading) {
            HStack { Text("저장한 Profile").font(.headline); Spacer(); Button { store.newProfile() } label: { Image(systemName: "plus") }.help("새 Profile") }
            List(selection: Binding<UUID?>(get: { store.profile.id }, set: { id in if let value = store.profiles.first(where: { $0.id == id }) { store.profile = value } })) {
                ForEach(store.profiles) { profile in VStack(alignment: .leading) { Text(profile.name); Text("v\(profile.revision) · \(profile.plan.stages.count) 단계").font(.caption).foregroundStyle(.secondary) }.tag(profile.id) }
            }.disabled(store.running)
            HStack { Button("가져오기") { store.importProfile() }; Button("내보내기") { store.exportProfile() } }.controlSize(.small)
            Button("선택한 Profile 삭제", role: .destructive) { store.delete() }.controlSize(.small).disabled(!store.profiles.contains(where: { $0.id == store.profile.id }) || store.running)
        }.padding(12)
    }
    private var execution: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("TypeSafe 연결") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack { SecureField("API 키", text: $store.apiKey).textFieldStyle(.roundedBorder); Button("키 불러오기") { store.loadKey() }; Button("키 저장") { store.saveKey() }; Button("키 삭제") { store.deleteKey() } }
                        HStack { TextField("모델 ID 또는 alias", text: $store.profile.model).textFieldStyle(.roundedBorder); Button("모델 목록 조회") { store.loadModels() }; if !store.models.isEmpty { Menu("모델 선택") { ForEach(store.models) { model in Button(model.name) { store.profile.model = model.name } } } } }
                        Text("실행은 TypeSafe API에 입력을 전달합니다. 키는 Keychain에 저장할 수 있으며 Profile에는 포함하지 않습니다.").font(.caption).foregroundStyle(.secondary)
                    }.padding(8)
                }
                GroupBox("분석할 입력") {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("입력", selection: $store.sourceKind) { ForEach(DecisionSourceKind.allCases) { kind in Text(kind.label).tag(kind) } }
                        if store.sourceKind == .project { Picker("프로젝트", selection: $store.projectID) { ForEach(maestro.projects) { project in Text(project.name).tag(project.id) } } }
                        if [.session, .record, .draft].contains(store.sourceKind) { Picker("세션", selection: $store.sessionID) { ForEach(maestro.sessions) { session in Text(session.title).tag(session.id) } } }
                        if store.sourceKind == .record, !store.sourceNodes.isEmpty {
                            Picker("기록", selection: $store.recordID) { Text("기록 선택").tag(""); ForEach(store.sourceNodes) { node in Text("\(node.kind.label) · \(node.title)").tag(node.id) } }
                        }
                        if store.sourceKind == .manual { TextEditor(text: $store.manualJSON).font(.system(.body, design: .monospaced)).frame(minHeight: 125).border(.separator) }
                        else { TextField("분석 목표", text: $store.goal).textFieldStyle(.roundedBorder) }
                        HStack {
                            Button(store.sourceKind == .record && store.sourceNodes.isEmpty ? "기록 목록 불러오기" : "입력 불러오기") { store.loadInput(maestro: maestro) }.disabled(store.loadingInput || store.running)
                            if store.loadingInput { ProgressView().controlSize(.small) }
                            if let input = store.input { Text("\(input.evidence.count)개 근거 · \(input.state.text.utf8.count.formatted()) bytes").font(.caption).foregroundStyle(.secondary) }
                        }
                        if [.project, .session].contains(store.sourceKind) { Text("기본 입력에는 자료 요약과 목록이 포함됩니다. 본문은 ‘질문과 계획’에서 후속 자료 ID를 지정한 단계가 읽습니다.").font(.caption).foregroundStyle(.secondary) }
                        if let input = store.input { DisclosureGroup("전달할 입력 확인") { DecisionReadOnlyJSON(text: input.state.text).frame(height: 180) } }
                    }.padding(8)
                }
                HStack {
                    Button("Profile 실행") { store.run(maestro: maestro) }.buttonStyle(.borderedProminent).disabled(store.running || store.loadingInput || store.input == nil)
                    Button("취소") { store.cancel() }.disabled(!store.running && !store.loadingInput)
                    Button("결과 캐시 비우기") { store.clearCache() }.disabled(store.running)
                    Text("\(store.profile.plan.stages.count) 단계 · \(store.profile.plan.stages.reduce(0) { $0 + $1.questions.count }) 질문").font(.caption).foregroundStyle(.secondary)
                }
                if let result = store.result { DecisionResultView(result: result, status: store.status(maestro: maestro) ?? result.status, store: store, maestro: maestro, onDismissWorkbench: { store.cancel(); dismiss() }) }
            }.padding(16)
        }
    }
    private var planEditor: some View {
        HSplitView {
            VStack {
                List(selection: $selectedStageID) { ForEach(store.profile.plan.stages) { stage in VStack(alignment: .leading) { Text(stage.id); Text("\(stage.questions.count) 질문 · 의존 \(stage.dependencies.count)").font(.caption).foregroundStyle(.secondary) }.tag(stage.id) } }
                Button("단계 추가") {
                    let id = "stage_" + UUID().uuidString.prefix(8)
                    store.profile.plan.stages.append(.init(id: String(id), questions: [.init(id: "question", spec: .init(type: .noul, instructions: .string("판단할 질문")))])); selectedStageID = String(id)
                }
            }.frame(minWidth: 160, idealWidth: 175, maxWidth: 200)
            if let index = store.profile.plan.stages.firstIndex(where: { $0.id == selectedStageID }) {
                DecisionStageEditor(stage: $store.profile.plan.stages[index], allStages: store.profile.plan.stages, onDelete: { store.profile.plan.stages.remove(at: index); selectedStageID = store.profile.plan.stages.first?.id ?? "" }).id(index)
            } else { ContentUnavailableView("단계를 선택하세요", systemImage: "arrow.triangle.branch") }
        }.onAppear { if selectedStageID.isEmpty { selectedStageID = store.profile.plan.stages.first?.id ?? "" } }.disabled(store.running)
    }
    private var rawInspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Profile 정의").font(.headline)
                DecisionReadOnlyJSON(text: (try? String(decoding: DecisionProfileRepository.encodeProfile(store.profile), as: UTF8.self)) ?? "설정 오류를 수정하세요.").frame(height: 220)
                if let result = store.result {
                    Text("입력 fingerprint: \(result.inputFingerprint)").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    ForEach(Array(result.traces.enumerated()), id: \.offset) { index, trace in
                        DisclosureGroup("요청 \(index + 1) · \(trace.response?.model ?? trace.request.model)\(trace.cached ? " · 캐시" : "")") {
                            Text("실제 요청 JSON").font(.headline)
                            DecisionReadOnlyJSON(text: (try? DecisionJSON.value(trace.request).text) ?? "").frame(height: 220)
                            Text("전체 응답").font(.headline)
                            DecisionReadOnlyJSON(text: trace.response.map { String(decoding: $0.rawData, as: UTF8.self) } ?? trace.rawErrorResponse.map { String(decoding: $0, as: UTF8.self) } ?? trace.error ?? "응답 없음").frame(height: 220)
                        }
                    }
                    DisclosureGroup("근거 확인 범위") { ForEach(Array(result.consultedEvidence.enumerated()), id: \.offset) { _, evidence in VStack(alignment: .leading) { Text(evidence.id); Text(evidence.coverage).foregroundStyle(.secondary); Text(evidence.fingerprint).font(.system(.caption2, design: .monospaced)) }.textSelection(.enabled) } }
                }
            }.padding(16)
        }
    }
}
struct DecisionReadOnlyJSON: View {
    let text: String
    var body: some View { ScrollView([.horizontal, .vertical]) { Text(text).font(.system(.callout, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .topLeading).padding(8) }.background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6)) }
}
struct DecisionJSONEditor: View {
    let title: String
    @Binding var value: DecisionJSON
    @State private var draft: String
    @State private var error: String?
    private var validate: ((DecisionJSON) throws -> Void)?
    init(_ title: String, value: Binding<DecisionJSON>, validate: ((DecisionJSON) throws -> Void)? = nil) { self.title = title; _value = value; _draft = State(initialValue: value.wrappedValue.text); self.validate = validate }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack { Text(title).font(.callout.weight(.medium)); Spacer(); Button("JSON 적용") { do { let parsed = try DecisionJSON.parse(draft); try validate?(parsed); value = parsed; error = nil } catch { self.error = error.localizedDescription } }.controlSize(.small) }
            TextEditor(text: $draft).font(.system(.callout, design: .monospaced)).frame(minHeight: 86, idealHeight: 110).border(.separator)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }.onChange(of: value) { draft = value.text }
    }
}
