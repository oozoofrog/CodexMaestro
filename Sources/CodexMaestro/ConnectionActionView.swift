import SwiftUI
import MaestroCore

private struct ActionPreviewKey: Hashable {
    let link: NodeLink
    let configuration: ConnectionActionConfiguration
}

@MainActor struct ConnectionActionView: View {
    @Bindable var store: MaestroStore
    let linkID: UUID
    var onPrepared: () -> Void
    @State private var configuration: ConnectionActionConfiguration
    @State private var preview = ""
    @State private var previewConfiguration: ConnectionActionConfiguration?
    @State private var previewLink: NodeLink?
    @State private var previewLoading = false
    @State private var previewError: String?
    @State private var operationError: String?
    @State private var resultMessage: String?
    @State private var preparing = false
    @Environment(\.dismiss) private var dismiss

    init(store: MaestroStore, linkID: UUID, onPrepared: @escaping () -> Void = {}) {
        self.store = store; self.linkID = linkID
        self.onPrepared = onPrepared
        _configuration = State(initialValue: store.connectionAction(for: linkID).sessionManagedSkills())
    }
    private var link: NodeLink? { store.workspace.allNodeLinks.first { $0.id == linkID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("요청").font(.system(size: 17, weight: .medium))
                Spacer()
                Button("닫기") { dismiss() }.keyboardShortcut(.cancelAction).disabled(preparing).help("연결은 그대로 유지합니다")
            }
            if let link { actionContent(link) }
            else {
                Text("연결을 찾을 수 없습니다.").font(.system(size: 12)).foregroundStyle(Palette.muted)
                Spacer()
            }
        }.padding(22).frame(width: 580).background(Palette.panel).foregroundStyle(Palette.text)
    }
    private func actionContent(_ link: NodeLink) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("작업", selection: $configuration.function) {
                ForEach(ConnectionFunction.availableFunctions, id: \.self) { Text($0.label).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().accessibilityIdentifier("connection-function")
            VStack(alignment: .leading, spacing: 6) {
                Text("요청 내용").font(.system(size: 12, weight: .medium))
                TextEditor(text: $configuration.prompt).font(.system(size: 12)).scrollContentBackground(.hidden).padding(6)
                    .frame(height: 92).background(Palette.card, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Palette.border))
                    .accessibilityIdentifier("connection-action-prompt")
            }
            routing(link)
            DisclosureGroup {
                ScrollView {
                    Text(previewConfiguration == configuration && previewLink == link && !preview.isEmpty ? preview : "보낼 내용을 준비하고 있습니다.")
                        .font(.system(size: 11)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(10)
                }.frame(height: 170).background(Palette.card, in: RoundedRectangle(cornerRadius: 7))
            } label: {
                HStack {
                    Text("보낼 내용").font(.system(size: 12))
                    if previewLoading { ProgressView().controlSize(.mini) }
                }
            }.accessibilityIdentifier("connection-action-preview")
            if let previewError { Text(previewError).font(.system(size: 11)).foregroundStyle(Palette.amber) }
            if let operationError { Text(operationError).font(.system(size: 11)).foregroundStyle(Palette.amber).accessibilityIdentifier("connection-action-error") }
            if let resultMessage { Text(resultMessage).font(.system(size: 11)).foregroundStyle(Palette.mint) }
            HStack {
                Text("초안을 확인하고 전송하면 실행됩니다.").font(.system(size: 11)).foregroundStyle(Palette.muted)
                Spacer()
                Button("저장") { save(link) }.disabled(preparing).accessibilityIdentifier("save-connection-action")
                Button("초안 준비") { Task { await prepare(link) } }
                    .buttonStyle(.borderedProminent).tint(Palette.blue)
                    .disabled(preparing || previewLoading || previewConfiguration != configuration || previewLink != link || preview.isEmpty || previewError != nil)
                    .accessibilityIdentifier("prepare-connection-action")
            }
        }
        .onAppear { synchronizeRecipient(link) }
        .onChange(of: configuration.function) { _, function in
            configuration.executionSide = function.defaultExecutionSide
            configuration.recipientSessionID = nil
            synchronizeRecipient(link)
        }
        .onChange(of: configuration.executionSide) { _, _ in
            configuration.recipientSessionID = nil
            synchronizeRecipient(link)
        }
        .task(id: ActionPreviewKey(link: link, configuration: configuration)) { await refreshPreview(link) }
        .disabled(preparing)
    }
    private func routing(_ link: NodeLink) -> some View {
        let execution = configuration.executionEndpoint(for: link)
        let reference = configuration.executionSide == .source ? link.target : link.source
        let candidates = store.actionRecipientCandidates(link: link, config: configuration)
        return VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("담당").font(.system(size: 12, weight: .medium))
                Picker("담당", selection: $configuration.executionSide) {
                    Text("출발 쪽").tag(ConnectionExecutionSide.source)
                    Text("도착 쪽").tag(ConnectionExecutionSide.target)
                }.pickerStyle(.segmented).labelsHidden().accessibilityIdentifier("connection-execution-side")
            }
            routeLabel("작업", endpoint: execution)
            routeLabel("참고", endpoint: reference)
            if execution.kind == .project {
                Picker("실행 세션", selection: $configuration.recipientSessionID) {
                    Text("담당 세션 선택").tag(Optional<String>.none)
                    ForEach(candidates) { session in Text(session.title).tag(Optional(session.id)) }
                    if let selected = configuration.recipientSessionID, !candidates.contains(where: { $0.id == selected }) {
                        Text("다시 선택하세요").tag(Optional(selected))
                    }
                }.accessibilityIdentifier("connection-action-recipient")
                if candidates.isEmpty { Text("이 프로젝트에 담당 세션이 없습니다.").font(.system(size: 11)).foregroundStyle(Palette.muted) }
            }
        }.padding(12).background(Palette.card, in: RoundedRectangle(cornerRadius: 8))
    }
    private func routeLabel(_ title: String, endpoint: LinkEndpoint) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(title).font(.system(size: 11)).foregroundStyle(Palette.muted).frame(width: 28, alignment: .leading)
            Label(store.endpointTitle(endpoint), systemImage: endpoint.kind.symbol).font(.system(size: 12))
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func synchronizeRecipient(_ link: NodeLink) {
        let endpoint = configuration.executionEndpoint(for: link)
        if endpoint.kind == .session { configuration.recipientSessionID = endpoint.id }
    }
    private func refreshPreview(_ link: NodeLink) async {
        let snapshot = configuration
        previewLoading = true; previewError = nil
        do {
            try await Task.sleep(for: .milliseconds(200))
            let result = try await store.buildConnectionPrompt(link: link, config: snapshot)
            guard !Task.isCancelled, configuration == snapshot, self.link == link else { return }
            preview = result; previewConfiguration = snapshot; previewLink = link; previewLoading = false
        } catch {
            guard !Task.isCancelled, configuration == snapshot, self.link == link else { return }
            preview = ""; previewConfiguration = nil; previewLink = nil; previewError = error.localizedDescription; previewLoading = false
        }
    }
    private func save(_ link: NodeLink) {
        operationError = nil; resultMessage = nil
        if store.saveConnectionAction(link: link, config: configuration) { resultMessage = "저장했습니다." }
        else { captureError() }
    }
    private func prepare(_ link: NodeLink) async {
        guard previewConfiguration == configuration, previewLink == link, !preview.isEmpty else { return }
        operationError = nil; resultMessage = nil; preparing = true
        defer { preparing = false }
        guard store.saveConnectionAction(link: link, config: configuration) else { captureError(); return }
        if await store.prepareConnectionAction(link: link, config: configuration, preparedPrompt: preview) { dismiss(); onPrepared() }
        else { captureError() }
    }
    private func captureError() { operationError = store.error; store.error = nil }
}
