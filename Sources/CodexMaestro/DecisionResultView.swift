import SwiftUI
import MaestroCore

struct DecisionResultView: View {
    let result: DecisionResult
    let status: DecisionResultStatus
    @Bindable var store: DecisionWorkbenchStore
    @Bindable var maestro: MaestroStore
    var onDismissWorkbench: () -> Void = {}
    @State private var allowedSessionID = ""
    @State private var allowedProjectID = ""
    @State private var comparisonSessionID = ""
    @State private var applying = false
    @State private var applyTask: Task<Void, Never>?
    @State private var comparison: DecisionSessionComparison?
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack { Text(status.label).font(.headline).foregroundStyle(status == .succeeded ? Color.primary : Color.orange); Spacer(); Text("\(result.usage.input_tokens) 입력 · \(result.usage.output_tokens) 출력 tokens").font(.caption).foregroundStyle(.secondary) }
                if let detail = result.detail { Text(detail).font(.callout).textSelection(.enabled) }
                if status == .stale { Text("입력 또는 Profile이 변경되었습니다. 현재 입력을 불러온 뒤 다시 실행하세요.").font(.callout) }
                ForEach(result.stages.keys.sorted(), id: \.self) { id in
                    if let stage = result.stages[id] {
                        Text("\(id)\(stage.skipped ? " · 조건 분기에서 생략" : "")").font(.headline)
                        ForEach(stage.answers.keys.sorted(), id: \.self) { key in HStack(alignment: .top) {
                            Text(key).font(.system(.callout, design: .monospaced)).frame(width: 140, alignment: .leading)
                            if let answer = stage.answers[key] { Text(answer.description).textSelection(.enabled) }
                        } }
                    }
                }
                if !result.composed.labels.isEmpty { Text("라벨: " + result.composed.labels.joined(separator: ", ")) }
                ForEach(Array(result.composed.ranks.enumerated()), id: \.offset) { _, rank in HStack { Text(rank.id); Spacer(); Text(rank.score.formatted(.number.precision(.fractionLength(3)))); Text(rank.eligible ? "조건 충족" : "조건 미충족").foregroundStyle(rank.eligible ? Color.secondary : Color.orange) } }
                ForEach(Array(result.composed.selectedValues.enumerated()), id: \.offset) { index, value in DisclosureGroup("선택한 원본 \(index + 1)") { DecisionReadOnlyJSON(text: value.string ?? value.text).frame(height: 100) } }
                if !result.composed.bindings.isEmpty {
                    Divider()
                    Text("사용자가 허용할 적용 대상").font(.headline)
                    Picker("세션", selection: $allowedSessionID) { Text("대상 선택").tag(""); ForEach(maestro.sessions) { session in Text(session.title).tag(session.id) } }
                    Picker("프로젝트", selection: $allowedProjectID) { Text("대상 선택").tag(""); ForEach(maestro.projects) { project in Text(project.name).tag(project.id) } }
                    if result.composed.bindings.contains(where: { $0.handler == "compareSessions" }) {
                        Picker("비교할 세션", selection: $comparisonSessionID) { Text("대상 선택").tag(""); ForEach(maestro.sessions) { session in Text(session.title).tag(session.id) } }
                    }
                    ForEach(Array(result.composed.bindings.enumerated()), id: \.offset) { _, binding in HStack(alignment: .top) {
                        VStack(alignment: .leading) { Text(binding.handler).font(.headline); Text(binding.arguments.text).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                        Spacer()
                        Button("이 handler 적용") {
                            applying = true
                            applyTask = Task {
                                let effect = await store.apply(binding, maestro: maestro, allowedSessionID: allowedSessionID, allowedProjectID: allowedProjectID, comparisonSessionID: comparisonSessionID)
                                applying = false
                                switch effect { case .dismissWorkbench: onDismissWorkbench(); case .comparison(let value): comparison = value; default: break }
                            }
                        }.disabled(status != .succeeded || applying)
                    } }
                }
            }.padding(8)
        }.sheet(item: $comparison) { value in DecisionSessionComparisonView(comparison: value, catalog: maestro.catalog, demo: maestro.demo) }
            .onDisappear { applyTask?.cancel() }
    }
}
private extension DecisionAnswer {
    var description: String { switch self {
        case .choice(let value, _, let confidence): "Choice \(value) · confidence \(confidence.formatted(.number.precision(.fractionLength(3))))"
        case .score(let value, _, let confidence, _): "Score \(value.formatted(.number.precision(.fractionLength(3)))) · confidence \(confidence.formatted(.number.precision(.fractionLength(3))))"
        case .noul(let value): "Noul yes \(value.formatted(.number.precision(.fractionLength(3))))"
    } }
}
private struct DecisionSessionComparisonView: View {
    let comparison: DecisionSessionComparison
    let catalog: CodexCatalog
    let demo: Bool
    @State private var left: [TranscriptMessage] = []
    @State private var right: [TranscriptMessage] = []
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack {
            HStack { Text("세션 비교").font(.title2); Spacer(); Button("닫기") { dismiss() } }
            HSplitView { column(comparison.source.title, messages: left); column(comparison.target.title, messages: right) }
            if let error { Text(error).foregroundStyle(.red) }
        }.padding(16).frame(width: 1050, height: 720).task {
            do {
                if demo { left = [.init(id: "a", role: "assistant", text: comparison.source.preview)]; right = [.init(id: "b", role: "assistant", text: comparison.target.preview)] }
                else {
                    let catalog = catalog, a = comparison.source.id, b = comparison.target.id
                    let pair = try await Task.detached { (try catalog.transcript(threadID: a, limit: Int.max), try catalog.transcript(threadID: b, limit: Int.max)) }.value
                    left = pair.0; right = pair.1
                }
            } catch { self.error = error.localizedDescription }
        }
    }
    private func column(_ title: String, messages: [TranscriptMessage]) -> some View {
        VStack(alignment: .leading) { Text(title).font(.headline); ScrollView { LazyVStack(alignment: .leading, spacing: 16) { ForEach(messages) { message in VStack(alignment: .leading) { Text(message.role).font(.caption).foregroundStyle(.secondary); Text(message.text).textSelection(.enabled) } } }.frame(maxWidth: .infinity, alignment: .leading).padding(8) } }.frame(minWidth: 450)
    }
}
