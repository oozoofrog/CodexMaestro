import SwiftUI
import MaestroCore

enum ConnectionDirection: String, CaseIterable {
    case all = "전체"
    case sessionSession = "세션 → 세션"
    case projectProject = "프로젝트 → 프로젝트"
    case sessionProject = "세션 → 프로젝트"
    case projectSession = "프로젝트 → 세션"
    var sourceKind: LinkEndpointKind? {
        switch self { case .all: nil; case .sessionSession, .sessionProject: .session; case .projectProject, .projectSession: .project }
    }
    var targetKind: LinkEndpointKind? {
        switch self { case .all: nil; case .sessionSession, .projectSession: .session; case .projectProject, .sessionProject: .project }
    }
    func includes(_ link: NodeLink) -> Bool {
        self == .all || (link.source.kind == sourceKind && link.target.kind == targetKind)
    }
}
struct ConnectionDraft: Identifiable {
    let id: UUID
    var source: LinkEndpoint
    var target: LinkEndpoint
    var kind: LinkKind
    var note: String
    let existing: Bool
    init(link: NodeLink, existing: Bool = true) {
        id = link.id; source = link.source; target = link.target; kind = link.kind; note = link.note; self.existing = existing
    }
    var link: NodeLink { NodeLink(id: id, source: source, target: target, kind: kind, note: note) }
    static func new(direction: ConnectionDirection, selected: LinkEndpoint?, projects: [Project], sessions: [Session]) -> Self {
        let endpoints = projects.map { LinkEndpoint.project($0.id) } + sessions.map { LinkEndpoint.session($0.id) }
        let candidates = endpoints.filter { direction.sourceKind == nil || $0.kind == direction.sourceKind }
        let source = selected.flatMap { candidates.contains($0) ? $0 : nil } ?? candidates.first ?? LinkEndpoint(kind: direction.sourceKind ?? .session, id: "")
        let targets = endpoints.filter { (direction.targetKind == nil || $0.kind == direction.targetKind) && $0 != source }
        let target = targets.first ?? LinkEndpoint(kind: direction.targetKind ?? source.kind, id: "")
        return Self(link: NodeLink(source: source, target: target, kind: .context), existing: false)
    }
}

struct SavedConnectionActionSummary: View {
    let store: MaestroStore
    let link: NodeLink
    var body: some View {
        if let configuration = store.workspace.connectionActions[link.id.uuidString] {
            Text("\(configuration.function.label) · \(receiverLabel(configuration))")
                .font(.system(size: 11)).foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
    }
    private func receiverLabel(_ configuration: ConnectionActionConfiguration) -> String {
        let endpoint = configuration.executionEndpoint(for: link)
        if endpoint.kind == .session {
            return store.endpointExists(endpoint) ? "담당: \(store.endpointTitle(endpoint))" : "담당 다시 선택"
        }
        guard let id = configuration.recipientSessionID else { return "담당 세션 선택" }
        guard store.sessions.contains(where: { $0.id == id && $0.projectID == endpoint.id }) else { return "담당 다시 선택" }
        return "담당: \(store.endpointTitle(.session(id)))"
    }
}

struct ProjectConnectionsView: View {
    @Bindable var store: MaestroStore
    @Environment(\.dismiss) private var dismiss
    @State private var direction: ConnectionDirection = .all
    @State private var draft: ConnectionDraft?
    @State private var operationError: String?
    private var links: [NodeLink] { store.workspace.allNodeLinks.filter { direction.includes($0) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("연결 관리").font(.system(size: 17, weight: .medium))
                Spacer()
                Button("완료") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Picker("연결 방향", selection: $direction) {
                ForEach(ConnectionDirection.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.menu).accessibilityIdentifier("connection-direction")
            HStack {
                Spacer()
                Button("연결 추가", systemImage: "plus") { newConnection() }
                    .disabled(store.projects.isEmpty && store.sessions.isEmpty).accessibilityIdentifier("connection-add")
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if links.isEmpty {
                        Text("연결이 없습니다.").font(.system(size: 12)).foregroundStyle(Palette.muted).padding(22)
                    }
                    ForEach(links) { link in connectionRow(link) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if let operationError { Text(operationError).font(.system(size: 12)).foregroundStyle(Palette.amber) }
        }.padding(22).frame(width: 680, height: 530).background(Palette.background).foregroundStyle(Palette.text)
            .sheet(item: $draft) { value in ConnectionEditor(store: store, initial: value) }
            .sheet(item: $store.actionSheetTarget) { target in ConnectionActionView(store: store, linkID: target.id, onPrepared: { dismiss() }) }
    }
    private func endpointLabel(_ endpoint: LinkEndpoint) -> String { store.endpointExists(endpoint) ? store.endpointTitle(endpoint) : "현재 목록에 없음" }
    private func connectionRow(_ link: NodeLink) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 8) {
                Label(endpointLabel(link.source), systemImage: link.source.kind.symbol)
                Image(systemName: "arrow.right").foregroundStyle(Palette.muted)
                Label(endpointLabel(link.target), systemImage: link.target.kind.symbol)
            }.font(.system(size: 12, weight: .medium)).fixedSize(horizontal: false, vertical: true)
            SavedConnectionActionSummary(store: store, link: link)
            HStack {
                Button("요청") { store.configureConnection(link) }
                Spacer()
                Menu {
                    Button("편집") { draft = ConnectionDraft(link: link) }
                    Button("삭제", role: .destructive) { handleResult(store.deleteNodeLink(link)) }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
                    .accessibilityLabel("연결 편집 및 삭제")
            }.controlSize(.small)
            DisclosureGroup("관계 설정") {
                VStack(alignment: .leading, spacing: 8) {
                    Label(link.kind.label, systemImage: link.kind.symbol).foregroundStyle(Palette.link(link.kind))
                    if !link.note.isEmpty { Text(link.note).foregroundStyle(Palette.muted).textSelection(.enabled) }
                }.font(.system(size: 11)).padding(.top, 6)
            }.font(.system(size: 11)).foregroundStyle(Palette.muted)
        }.padding(.vertical, 13).frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) { Rectangle().fill(Palette.border).frame(height: 1) }
    }
    private func newConnection() {
        draft = ConnectionDraft.new(direction: direction, selected: store.selectedEndpoint, projects: store.projects, sessions: store.sessions)
    }
    private func handleResult(_ success: Bool) {
        operationError = success ? nil : store.error
        if !success { store.error = nil }
    }
}

private struct ConnectionEditor: View {
    @Bindable var store: MaestroStore
    @State private var value: ConnectionDraft
    @State private var validationError: String?
    @Environment(\.dismiss) private var dismiss
    init(store: MaestroStore, initial: ConnectionDraft) { self.store = store; _value = State(initialValue: initial) }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("연결 \(value.existing ? "편집" : "추가")").font(.system(size: 18, weight: .medium))
            endpointPicker("출발", endpoint: $value.source)
            endpointPicker("도착", endpoint: $value.target)
            DisclosureGroup("관계 설정") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("연결 목적", selection: $value.kind) { ForEach(LinkKind.allCases, id: \.self) { Text($0.label).tag($0) } }.pickerStyle(.segmented)
                    TextField("메모", text: $value.note, axis: .vertical).lineLimit(3...6).textFieldStyle(.roundedBorder)
                }.padding(.top, 8)
            }.font(.system(size: 12))
            if let validationError { Text(validationError).font(.system(size: 12)).foregroundStyle(Palette.amber).accessibilityIdentifier("connection-validation") }
            HStack {
                Button("취소", role: .cancel) { dismiss() }
                Spacer()
                Button("저장") { commit() }.buttonStyle(.borderedProminent).tint(Palette.blue).keyboardShortcut(.defaultAction)
                    .disabled(value.source.id.isEmpty || value.target.id.isEmpty || value.source == value.target).accessibilityIdentifier("connection-save")
            }
        }.padding(22).frame(width: 580).background(Palette.background).foregroundStyle(Palette.text)
    }
    private func endpointPicker(_ title: String, endpoint: Binding<LinkEndpoint>) -> some View {
        let items = endpoint.wrappedValue.kind == .project ? store.projects.map { ($0.id, $0.name) } : store.sessions.map { ($0.id, "\($0.title) · \(store.projectName(for: $0))") }
        return VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12)).foregroundStyle(Palette.muted)
            HStack {
                Picker("\(title) 종류", selection: Binding(get: { endpoint.wrappedValue.kind }, set: { kind in
                    let firstID = kind == .project ? store.projects.first?.id : store.sessions.first?.id
                    endpoint.wrappedValue = LinkEndpoint(kind: kind, id: firstID ?? "")
                })) { ForEach(LinkEndpointKind.allCases, id: \.self) { Text($0.label).tag($0) } }
                    .labelsHidden().frame(width: 130).accessibilityIdentifier(title == "출발" ? "connection-source-kind" : "connection-target-kind")
                Picker(title, selection: Binding(get: { endpoint.wrappedValue.id }, set: { endpoint.wrappedValue = LinkEndpoint(kind: endpoint.wrappedValue.kind, id: $0) })) {
                    if !items.contains(where: { $0.0 == endpoint.wrappedValue.id }) {
                        Text(endpoint.wrappedValue.id.isEmpty ? "선택하세요" : "현재 목록에 없음 · \(endpoint.wrappedValue.id)").tag(endpoint.wrappedValue.id)
                    }
                    ForEach(items, id: \.0) { item in Text(item.1).tag(item.0) }
                }.labelsHidden().frame(maxWidth: .infinity)
            }
        }
    }
    private func commit() {
        if store.saveNodeLink(value.link) { dismiss() }
        else { validationError = store.error; store.error = nil }
    }
}
