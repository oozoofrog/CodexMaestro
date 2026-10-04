import SwiftUI
import MaestroCore

struct ProjectInspectorSummary {
    let sessionCount: Int
    let runningCount: Int
    let incidentLinks: [NodeLink]
    init(project: Project, sessions: [Session], nodeLinks: [NodeLink]) {
        let members = sessions.filter { ($0.projectID ?? "unassigned") == project.id }
        sessionCount = members.count
        runningCount = members.filter { $0.status == .running }.count
        incidentLinks = EndpointConnections.related(to: .project(project.id), in: nodeLinks)
    }
}

enum EndpointConnections {
    static func related(to endpoint: LinkEndpoint, in links: [NodeLink]) -> [NodeLink] {
        links.filter { $0.source == endpoint || $0.target == endpoint }
    }
}

struct SessionInspector: View {
    @Bindable var store: MaestroStore
    var onManageConnections: () -> Void = {}
    @State private var tab = "conversation"
    @State private var showsInformation = false
    var body: some View {
        VStack(spacing: 0) {
            if let session = store.selectedSession {
                header(session)
                Divider().overlay(Palette.border)
                Picker("세션 정보", selection: $tab) {
                    Text("대화").tag("conversation")
                    Text("연결").tag("connections")
                    Text("기록").tag("activity")
                }.pickerStyle(.segmented).labelsHidden().padding(16)
                if tab == "connections" { connections(session) }
                else if tab == "activity" { activity }
                else { conversation(session) }
                Divider().overlay(Palette.border)
                composer(session)
            } else if let project = store.selectedNodeProject {
                projectInspector(project)
            } else {
                EmptyPanel(symbol: "cursorarrow.click.2", title: "작업을 선택하세요", detail: "대화와 연결을 확인합니다.")
            }
        }.background(Palette.background)
            .onChange(of: store.selectedEndpoint) { _, _ in showsInformation = false }
    }
    private func projectInspector(_ project: Project) -> some View {
        let summary = ProjectInspectorSummary(project: project, sessions: store.sessions, nodeLinks: store.workspace.allNodeLinks)
        let links = summary.incidentLinks
        return VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    Text(project.name).font(.system(size: 17, weight: .medium)).textSelection(.enabled)
                    Spacer()
                    ToolButton(symbol: "folder", help: "Finder에서 열기") { store.revealProject(project) }
                        .disabled(project.roots.isEmpty)
                }
                Text("세션 \(summary.sessionCount) · 실행 \(summary.runningCount)")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
                if !project.roots.isEmpty {
                    DisclosureGroup("정보", isExpanded: $showsInformation) {
                        ForEach(project.roots, id: \.self) { root in
                            Text(root).font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.muted)
                                .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                        }.padding(.top, 6)
                    }.font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
            }.padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 14)
            Divider().overlay(Palette.border)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Eyebrow(text: "연결")
                        Spacer()
                        Button("전체", action: onManageConnections).buttonStyle(.bordered).controlSize(.small)
                    }.padding(.top, 16)
                    Button { store.beginLink(from: .project(project.id)) } label: { Label("연결", systemImage: "plus").frame(maxWidth: .infinity) }.buttonStyle(.bordered).tint(Palette.blue)
                        .disabled(!store.endpointExists(.project(project.id)))
                    if project.id == "unassigned" {
                        Text("각 세션에서 연결할 수 있습니다.").font(.system(size: 11)).foregroundStyle(Palette.muted)
                    }
                    if links.isEmpty {
                        Text("아직 연결이 없습니다.")
                            .font(.system(size: 12)).foregroundStyle(Palette.muted).lineSpacing(4)
                    }
                    ForEach(links) { link in connectionCard(link, endpoint: .project(project.id)) }
                }.padding(.horizontal, 17).padding(.bottom, 18)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
    private func header(_ session: Session) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Text(session.title).font(.system(size: 17, weight: .medium)).lineLimit(3).textSelection(.enabled)
                Spacer(minLength: 5)
                ToolButton(symbol: "arrow.up.right", help: "Codex에서 열기") { store.openInCodex(session) }
            }
            Button { store.openSessionWork(for: session.id) } label: {
                Label("작업 회로 보기", systemImage: "point.3.connected.trianglepath.dotted")
            }.buttonStyle(.bordered).controlSize(.small)
            HStack {
                SessionStatePill(session: session)
                Spacer()
                Text(store.projectName(for: session)).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1)
            }
            DisclosureGroup("정보", isExpanded: $showsInformation) {
                VStack(spacing: 7) {
                    infoRow("모델", value: session.model.isEmpty ? "미확인" : session.model, symbol: "cpu")
                    infoRow("추론", value: session.effort.isEmpty ? "세션 기본값" : session.effort, symbol: "sparkle")
                    if !session.branch.isEmpty { infoRow("브랜치", value: session.branch, symbol: "arrow.triangle.branch") }
                    Text(session.cwd).font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.muted)
                        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    Text(session.id).font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.muted)
                        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    if !session.isLive {
                        Text("저장된 상태 · Codex에서 열면 현재 상태를 확인합니다.")
                            .font(.system(size: 11)).foregroundStyle(Palette.muted).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding(.top, 6)
            }.font(.system(size: 11)).foregroundStyle(Palette.muted)
        }.padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 14)
    }
    private func infoRow(_ title: String, value: String, symbol: String) -> some View {
        HStack(spacing: 7) { Image(systemName: symbol).frame(width: 13); Text(title); Spacer(minLength: 7); Text(value).foregroundStyle(Palette.text).lineLimit(1).textSelection(.enabled) }.font(.system(size: 11)).foregroundStyle(Palette.muted)
    }
    private func conversation(_ session: Session) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if let error = store.transcriptError {
                        Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(Palette.amber)
                    } else if store.transcript.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Eyebrow(text: "대화")
                            Text(session.preview.isEmpty ? "아직 대화가 없습니다." : session.preview).font(.system(size: 12)).foregroundStyle(Palette.muted).lineSpacing(5).textSelection(.enabled)
                        }
                    } else {
                        ForEach(store.transcript) { message in
                            VStack(alignment: .leading, spacing: 9) {
                                HStack(spacing: 7) { Image(systemName: message.role == "assistant" ? "sparkle" : "person.crop.circle").foregroundStyle(message.role == "assistant" ? Palette.mint : Palette.muted); Text(message.role == "assistant" ? "Codex" : "사용자").font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.muted) }
                                Text(message.text).font(.system(size: 12)).lineSpacing(5).textSelection(.enabled).foregroundStyle(Palette.text.opacity(0.9))
                            }.padding(13).frame(maxWidth: .infinity, alignment: .leading).background(message.role == "user" ? Palette.card : .clear, in: RoundedRectangle(cornerRadius: 9)).id(message.id)
                        }
                    }
                }.padding(.horizontal, 17).padding(.bottom, 20)
            }.overlay(alignment: .topTrailing) { if store.transcriptLoading { ProgressView().controlSize(.small).padding(8) } }
                .onChange(of: store.selectedSessionID) { _, _ in if let last = store.transcript.last { proxy.scrollTo(last.id, anchor: .bottom) } }
        }
    }
    private func connections(_ session: Session) -> some View {
        let links = EndpointConnections.related(to: .session(session.id), in: store.workspace.allNodeLinks)
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Button { store.beginLink(from: .session(session.id)) } label: { Label("연결", systemImage: "plus").frame(maxWidth: .infinity) }.buttonStyle(.bordered).tint(Palette.blue)
                Button("전체 연결", action: onManageConnections).buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Palette.blue)
                if links.isEmpty {
                    Text("아직 연결이 없습니다.").font(.system(size: 12)).foregroundStyle(Palette.muted).lineSpacing(5).padding(.vertical, 12)
                }
                ForEach(links) { link in connectionCard(link, endpoint: .session(session.id)) }
                if let parent = session.parentID {
                    VStack(alignment: .leading, spacing: 8) {
                        Eyebrow(text: "상위 세션")
                        if let parentSession = store.sessions.first(where: { $0.id == parent }) {
                            Button { store.select(parentSession) } label: { Label(parentSession.title, systemImage: "arrow.turn.up.left") }
                                .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Palette.mint)
                        } else { Text(parent).font(.system(size: 11)).foregroundStyle(Palette.muted).textSelection(.enabled) }
                    }.padding(.top, 10)
                }
            }.padding(.horizontal, 17).padding(.bottom, 20)
        }
    }
    private func connectionCard(_ link: NodeLink, endpoint: LinkEndpoint) -> some View {
        let outgoing = link.source == endpoint
        let other = outgoing ? link.target : link.source
        return VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label(link.kind.label, systemImage: link.kind.symbol).foregroundStyle(Palette.link(link.kind))
                Spacer()
                Image(systemName: outgoing ? "arrow.up.right" : "arrow.down.left").foregroundStyle(Palette.muted)
                    .accessibilityLabel(outgoing ? "보내는 연결" : "받는 연결")
            }.font(.system(size: 11))
            Button { store.selectEndpoint(other) } label: {
                Label(store.endpointTitle(other), systemImage: other.kind.symbol)
                    .font(.system(size: 12, weight: .medium)).multilineTextAlignment(.leading)
            }.buttonStyle(.plain).disabled(!store.endpointExists(other))
            SavedConnectionActionSummary(store: store, link: link)
            if !link.note.isEmpty { Text(link.note).font(.system(size: 11)).foregroundStyle(Palette.muted).textSelection(.enabled) }
            HStack {
                Button("요청") { store.configureConnection(link) }.buttonStyle(.bordered).controlSize(.small)
                Spacer()
                Button(role: .destructive) { store.deleteNodeLink(link) } label: { Image(systemName: "trash").foregroundStyle(Palette.muted) }
                    .buttonStyle(.plain).help("연결 삭제")
            }
        }.padding(.vertical, 13).frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) { Rectangle().fill(Palette.border).frame(height: 1) }
    }
    private var activity: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 13) {
                Eyebrow(text: "최근 활동").padding(.bottom, 3)
                ForEach(store.events) { event in
                    HStack(alignment: .top, spacing: 9) {
                        Circle().fill(event.isError ? Palette.amber : Palette.mint).frame(width: 4, height: 4).padding(.top, 5)
                        VStack(alignment: .leading, spacing: 5) { Text(event.text).font(.system(size: 11)).lineSpacing(3); Text(event.date.formatted(date: .omitted, time: .standard)).font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.muted) }
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
        }
    }
    private func composer(_ session: Session) -> some View {
        let draft = Binding(get: { store.draft(for: session.id) }, set: { store.setDraft($0, for: session.id) })
        let sending = store.sending.contains(session.id)
        return VStack(alignment: .leading, spacing: 9) {
            HStack { Eyebrow(text: "요청"); Spacer(); Text("⌘ ↵").font(.system(size: 10)).foregroundStyle(Palette.muted) }
            ZStack(alignment: .topLeading) {
                if draft.wrappedValue.isEmpty { Text("다음 작업이나 개선할 점을 요청하세요…").font(.system(size: 12)).foregroundStyle(Palette.muted).padding(.horizontal, 9).padding(.top, 11).allowsHitTesting(false) }
                TextEditor(text: draft).font(.system(size: 12)).scrollContentBackground(.hidden).padding(5).frame(minHeight: 75, maxHeight: 110).accessibilityLabel("세션 프롬프트").accessibilityIdentifier("prompt-editor")
            }.background(Palette.background, in: RoundedRectangle(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 9).stroke(Palette.border))
            HStack {
                Spacer()
                Button { Task { await store.send(to: session) } } label: {
                    HStack(spacing: 7) { if sending { ProgressView().controlSize(.mini) } else { Image(systemName: "arrow.up") }; Text(sending ? "전송 중" : "전송").fontWeight(.semibold) }.font(.system(size: 11)).padding(.horizontal, 8).padding(.vertical, 3)
                }.buttonStyle(.borderedProminent).tint(Palette.blue).keyboardShortcut(.return, modifiers: .command)
                    .disabled(!store.connected || sending || store.actionSheetTarget != nil || draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("send-prompt")
            }
        }.padding(16).background(Palette.card)
            .task(id: draft.wrappedValue) { do { try await Task.sleep(for: .milliseconds(500)); store.saveDrafts() } catch {} }
    }
}
