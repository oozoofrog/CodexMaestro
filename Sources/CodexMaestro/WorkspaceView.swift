import SwiftUI
import MaestroCore

private enum WorkspaceRequest: Identifiable {
    case overlap(OverlapProposal), connection(ConnectionActionTarget), optimization(ContextOptimizationProposal)
    var id: String {
        switch self { case .overlap(let item): "overlap:\(item.id)"; case .connection(let item): "connection:\(item.id)"; case .optimization(let item): "optimization:\(item.id)" }
    }
}

struct WorkspaceView: View {
    @Bindable var store: MaestroStore
    @State private var showingConnections = false
    @State private var showingDecisions = false
    @State private var showsSidebar = true
    @State private var showsInspector = true
    @AppStorage("appearance") private var appearance = "system"

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                if showsSidebar {
                    ProjectSidebar(store: store)
                        .frame(minWidth: 190, idealWidth: 210, maxWidth: 230)
                }
                Group {
                    if store.contextScope != nil { ContextTopologyView(store: store) }
                    else if store.workInspection != nil { SessionWorkTopologyView(store: store) }
                    else { center }
                }.frame(minWidth: 560, maxWidth: .infinity)
                if showsInspector && store.contextScope == nil && store.workInspection == nil {
                    SessionInspector(store: store, onManageConnections: { showingConnections = true })
                        .frame(minWidth: 300, idealWidth: 330, maxWidth: 360)
                }
            }
            footer
        }
        .background(Palette.canvas).foregroundStyle(Palette.text)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { showsSidebar.toggle() } label: { Image(systemName: "sidebar.left") }
                    .help(showsSidebar ? "사이드바 숨기기" : "사이드바 표시")
                    .accessibilityLabel(showsSidebar ? "사이드바 숨기기" : "사이드바 표시")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { showingDecisions = true } label: { Image(systemName: "slider.horizontal.3") }
                    .help("사용자 정의 판단").accessibilityLabel("사용자 정의 판단")
                Button { showingConnections = true } label: { Image(systemName: "link") }
                    .help("연결").accessibilityLabel("연결")
                Button { Task { await store.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("새로고침 · ⌘R").accessibilityLabel("새로고침")
                Button { showsInspector.toggle() } label: { Image(systemName: "sidebar.right") }
                    .help(showsInspector ? "상세 패널 숨기기" : "상세 패널 표시")
                    .accessibilityLabel(showsInspector ? "상세 패널 숨기기" : "상세 패널 표시")
                Menu {
                    Picker("화면 모드", selection: $appearance) {
                        Text("시스템 설정").tag("system")
                        Text("밝게").tag("light")
                        Text("어둡게").tag("dark")
                    }
                    Divider()
                    Button("Codex 다시 연결") { Task { await store.reconnect() } }
                    Button("작업 흐름 내보내기…") { store.exportGraph() }
                    Button("배치 초기화") { store.resetPositions() }
                } label: { Image(systemName: "ellipsis.circle") }
                    .help("화면 모드와 작업공간 설정").accessibilityLabel("작업공간 설정")
            }
        }
        .sheet(isPresented: $showingDecisions) { DecisionWorkbenchView(maestro: store) }
        .sheet(isPresented: $showingConnections, onDismiss: { store.actionSheetTarget = nil }) { ProjectConnectionsView(store: store) }
        .sheet(item: requestBinding) { request in
            switch request {
            case .overlap(let proposal): OverlapActionView(store: store, proposal: proposal)
            case .connection(let target): ConnectionActionView(store: store, linkID: target.id)
            case .optimization(let proposal): ContextOptimizationView(store: store, proposal: proposal)
            }
        }
        .alert("작업을 완료하지 못했습니다", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("확인", role: .cancel) { store.error = nil }
        } message: { Text(store.error ?? "") }
        .overlay(alignment: .bottom) {
            if let notice = store.notice {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.mint)
                    Text(notice).font(.system(size: 12))
                    Button { store.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }
                .padding(12).background(Palette.panel, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.border))
                .shadow(color: .black.opacity(0.12), radius: 12, y: 3).padding(.bottom, 36)
                .task(id: notice) { try? await Task.sleep(for: .seconds(6)); if store.notice == notice { store.notice = nil } }
            }
        }
    }

    private var requestBinding: Binding<WorkspaceRequest?> {
        Binding(get: {
            if let proposal = store.overlapProposal { return .overlap(proposal) }
            if let proposal = store.optimizationProposal { return .optimization(proposal) }
            if !showingConnections, let target = store.actionSheetTarget { return .connection(target) }
            return nil
        }, set: { value in
            guard value == nil else { return }
            store.overlapProposal = nil; store.optimizationProposal = nil
            if !showingConnections { store.actionSheetTarget = nil }
        })
    }

    private var center: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                Text(store.selectedProjectID.flatMap { id in store.projects.first { $0.id == id }?.name }
                    ?? "작업 흐름").font(.system(size: 20, weight: .medium))
                Spacer()
                HStack(spacing: 2) {
                    ToolButton(symbol: "point.3.connected.trianglepath.dotted", help: "작업 흐름", active: !store.showList) { store.showList = false }
                    ToolButton(symbol: "list.bullet", help: "세션 목록 보기", active: store.showList) { store.showList = true }
                }.padding(2).background(Palette.card, in: RoundedRectangle(cornerRadius: 6))
            }.padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 12)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Palette.muted)
                TextField("검색", text: $store.search)
                    .textFieldStyle(.plain).font(.system(size: 12)).accessibilityIdentifier("session-search")
                if !store.search.isEmpty {
                    Button { store.search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.muted) }
                        .buttonStyle(.plain).accessibilityLabel("검색 지우기")
                }
            }
            .padding(8).background(Palette.panel, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.border))
            .padding(.horizontal, 18).padding(.bottom, 14)
            if let source = store.linkingEndpoint {
                HStack {
                    Image(systemName: "link")
                    Text("\(store.endpointTitle(source)) → 연결할 항목 선택").lineLimit(1)
                    Spacer()
                    Button("취소") { store.cancelLink() }
                }.font(.system(size: 11)).foregroundStyle(Palette.accent).padding(10).background(Palette.selection)
            }
            Rectangle().fill(Palette.border).frame(height: 1)
            if store.filteredSessions.isEmpty && store.visibleProjects.isEmpty {
                EmptyPanel(symbol: store.refreshing ? "arrow.clockwise" : "point.3.connected.trianglepath.dotted",
                    title: store.refreshing ? "불러오는 중" : "세션 없음",
                    detail: store.scope == "live" ? "Codex에서 열린 세션을 기다립니다." : "프로젝트나 검색 조건을 바꿔보세요.")
            } else if store.showList { SessionListView(store: store) }
            else { TopologyCanvas(store: store) }
        }
    }

    private var footer: some View {
        HStack(spacing: 16) {
            HStack(spacing: 5) {
                Circle().fill(store.connected ? Palette.mint : Palette.amber).frame(width: 5, height: 5)
                Text(store.demo ? "데모 · 실제 전송 없음" : store.connected ? "Codex 연결" : "저장된 상태")
            }
            Text("실행 \(store.runningCount) · 입력 대기 \(store.waitingCount)")
            Spacer()
            if let refreshed = store.lastRefresh {
                Image(systemName: "arrow.clockwise").help("갱신 \(refreshed.formatted(date: .omitted, time: .standard))")
            }
        }.font(.system(size: 10)).foregroundStyle(Palette.muted)
            .padding(.horizontal, 14).frame(height: 27).background(Palette.panel)
            .overlay(alignment: .top) { Rectangle().fill(Palette.border).frame(height: 1) }
    }
}

struct ProjectSidebar: View {
    @Bindable var store: MaestroStore
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: 16)
            scopeRow("최근 작업", symbol: "clock", scope: "recent", count: nil)
            scopeRow("열린 세션", symbol: "waveform.path", scope: "live", count: store.liveCount)
            scopeRow("전체", symbol: "tray.full", scope: "all", count: store.sessions.count)
            Divider().padding(.horizontal, 16).padding(.top, 16)
            HStack {
                Eyebrow(text: "프로젝트")
                Spacer()
            }.padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 10)
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(store.projects) { project in
                        projectRow(project)
                    }
                    if store.count(in: "unassigned") > 0 {
                        projectRow(Project(id: "unassigned", name: "프로젝트 없음"))
                    }
                }.padding(.horizontal, 8)
            }
        }.background(Palette.sidebar)
    }

    private func projectRow(_ project: Project) -> some View {
        let selected = store.selectedProjectID == project.id
        return HStack(spacing: 9) {
                Image(systemName: project.id == "unassigned" ? "tray" : "folder").font(.system(size: 13)).foregroundStyle(Palette.accent)
                Text(project.name).lineLimit(1).font(.system(size: 12, weight: selected ? .medium : .regular))
                Spacer(minLength: 0)
                Text("\(store.count(in: project.id))").font(.system(size: 10)).foregroundStyle(Palette.muted)
            }.padding(.horizontal, 10).padding(.vertical, 8)
                .background(selected ? Palette.selection : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle()).help(project.roots.joined(separator: "\n"))
            .gesture(TapGesture(count: 2).exclusively(before: TapGesture(count: 1)).onEnded { value in
                switch value {
                case .first: store.openContext(for: .project(project.id))
                case .second: selectProject(project)
                }
            })
            .accessibilityElement(children: .combine).accessibilityAddTraits(.isButton)
            .accessibilityAction { selectProject(project) }
            .accessibilityAction(named: "컨텍스트 보기") { store.openContext(for: .project(project.id)) }
            .contextMenu {
                Button("컨텍스트 보기") { store.openContext(for: .project(project.id)) }
                Button("Finder에서 열기") { store.revealProject(project) }
            }
    }

    private func selectProject(_ project: Project) {
        store.closeSessionWork()
        store.selectedProjectID = project.id
        store.selectProjectNode(project)
    }

    private func scopeRow(_ title: String, symbol: String, scope: String, count: Int?) -> some View {
        let selected = store.selectedProjectID == nil && store.scope == scope
        return Button {
            store.closeSessionWork()
            store.selectedProjectID = nil
            store.selectedNodeProjectID = nil
            store.scope = scope
            store.cancelLink()
        } label: {
            HStack(spacing: 9) {
                Image(systemName: symbol).frame(width: 17)
                Text(title)
                Spacer()
                if let count { Text("\(count)").font(.system(size: 10)) }
            }.font(.system(size: 12, weight: selected ? .medium : .regular))
                .foregroundStyle(selected ? Palette.accent : Palette.text)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(selected ? Palette.selection : .clear, in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain).padding(.horizontal, 8).padding(.bottom, 2)
    }
}

struct SessionListView: View {
    @Bindable var store: MaestroStore
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(store.filteredSessions) { session in
                    HStack(spacing: 10) {
                            Circle().fill(Palette.status(session.status)).frame(width: 6, height: 6)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(session.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                Text(store.projectName(for: session)).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1)
                                Text(session.lastMessage?.displayText ?? "대화 미리보기 없음")
                                    .font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(2).truncationMode(.tail)
                            }
                            Spacer()
                            SessionStatePill(session: session)
                    }.padding(12).background(store.selectedSessionID == session.id ? Palette.selection : Palette.panel)
                        .contentShape(Rectangle())
                        .gesture(TapGesture(count: 2).exclusively(before: TapGesture(count: 1)).onEnded { value in
                            switch value {
                            case .first: store.openSessionWork(for: session.id)
                            case .second: store.select(session)
                            }
                        })
                        .accessibilityElement(children: .combine).accessibilityAddTraits(.isButton)
                        .accessibilityAction { store.select(session) }
                        .accessibilityAction(named: "작업 회로 보기") { store.openSessionWork(for: session.id) }
                        .contextMenu {
                            Button("작업 회로 보기") { store.openSessionWork(for: session.id) }
                            Button("기록 지도 보기") { store.openContext(for: .session(session.id)) }
                        }
                    Divider()
                }
            }.padding(16)
        }
    }
}
