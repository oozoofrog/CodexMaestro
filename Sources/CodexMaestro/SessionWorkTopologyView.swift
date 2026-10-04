import SwiftUI
import MaestroCore

struct SessionWorkTopologyView: View {
    @Bindable var store: MaestroStore
    var body: some View {
        if let inspection = store.workInspection {
            SessionWorkContent(maestro: store, inspection: inspection)
                .onAppear { inspection.start() }
                .onDisappear { inspection.stopPolling() }
        }
    }
}

private enum CircuitTab: String, CaseIterable, Identifiable {
    case circuit, events, coverage
    var id: Self { self }
    var label: String { switch self { case .circuit: "작업 회로"; case .events: "이벤트 기록"; case .coverage: "확인 범위" } }
}

private struct SessionWorkContent: View {
    @Bindable var maestro: MaestroStore
    @Bindable var inspection: SessionWorkStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var tab = CircuitTab.circuit
    @State private var motionEnabled = true
    @State private var includeChildren = false
    @State private var selectedGroupID: String?
    @State private var expanded: Set<String> = []
    @State private var groupPages: [String: Int] = [:]
    @State private var focusedCallID: String?
    @State private var eventPage = 0
    @State private var bodyPages = 1
    @State private var replaying = false

    private var allNodes: [WorkNode] { inspection.visibleNodes }
    private var allEdges: [WorkRelation] { inspection.visibleEdges }
    private var displayedNodes: [WorkNode] {
        guard let focusedCallID else { return allNodes }
        var ids: Set<String> = [focusedCallID]
        for edge in allEdges where edge.source == focusedCallID || edge.target == focusedCallID {
            ids.insert(edge.source); ids.insert(edge.target)
        }
        return allNodes.filter { ids.contains($0.id) }
    }
    private var projection: CircuitProjection { CircuitProjection(nodes: displayedNodes, edges: allEdges, expanded: expanded, groupPages: groupPages) }
    private var selected: WorkNode? { inspection.selectedDetailNode }
    private var selectedGroup: CircuitItem? { projection.items.first { $0.id == selectedGroupID && $0.isGroup } }
    private var eventDates: [Date] {
        guard let graph=inspection.graph else { return [] }
        return CircuitEventTimeline.dates(graph:graph,turnID:inspection.selectedTurnID)
    }
    private var canAnimate: Bool { inspection.canAnimate && scenePhase == .active && !reduceMotion && motionEnabled }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                header
                controls
                if inspection.loading && inspection.graph == nil {
                    ProgressView("현재 작업의 저장 기록을 읽는 중…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if inspection.graph == nil {
                    EmptyPanel(symbol: "point.3.connected.trianglepath.dotted", title: "작업 기록을 읽지 못했습니다", detail: inspection.error ?? "읽을 수 있는 기록이 없습니다.")
                } else {
                    if geometry.size.width >= 1060 {
                        HStack(spacing: 0) {
                            mainContent.frame(maxWidth: .infinity)
                            Divider()
                            inspector.frame(width: 290)
                        }
                    } else {
                        VSplitView {
                            mainContent.frame(minHeight: 250)
                            inspector.frame(minHeight: 160, idealHeight: 210, maxHeight: 320)
                        }
                    }
                    tokens
                    timeline
                }
            }
        }
        .background(Palette.canvas)
        .onChange(of: inspection.selectedNodeID) { _, _ in bodyPages = 1 }
        .onChange(of: inspection.selectedObservationIndex) { _, _ in bodyPages = 1 }
        .onChange(of: inspection.selectedTurnID) { _, _ in
            selectedGroupID = nil; focusedCallID = nil; eventPage = 0; replaying = false
        }
        .onChange(of: inspection.session.id) { _, _ in
            selectedGroupID = nil; focusedCallID = nil; expanded = []; groupPages = [:]; eventPage = 0; replaying = false
        }
        .onChange(of: tab) { _, _ in replaying = false }
        .onChange(of: scenePhase) { _, phase in if phase != .active { replaying = false } }
        .task(id: replaying) {
            guard replaying else { return }
            while replaying && !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(1300)) } catch { return }
                guard replaying else { return }
                if !advanceEvent() { replaying = false }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                Button { maestro.closeSessionWork() } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.plain).accessibilityLabel("작업 흐름으로 돌아가기")
                ForEach(Array(inspection.breadcrumbs.enumerated()), id: \.element.id) { index, session in
                    if index > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(Palette.muted) }
                    if index < inspection.breadcrumbs.count - 1 {
                        Button(session.title) { Task { await inspection.back(to: session.id) } }
                            .buttonStyle(.plain).font(.subheadline).lineLimit(1).help(session.title)
                    } else { Text(session.title).font(.headline).lineLimit(1).help(session.title) }
                }
                Spacer(minLength: 8)
                if inspection.isDemo { Text("데모 · 합성 기록").font(.caption).foregroundStyle(Palette.amber) }
                if inspection.loading { ProgressView().controlSize(.small) }
                Button { Task { await inspection.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("선택한 세션 기록 다시 읽기").accessibilityLabel("작업 기록 다시 읽기")
                Button("기록 지도") { maestro.showSessionRecordMap() }.help("기존 전체 기록 지도로 전환")
            }
            HStack(spacing: 12) {
                let turn = inspection.selectedTurn
                let configuration=[turn?.model,turn?.effort].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator:" · ")
                Text(configuration.isEmpty ? "요청 모델 설정 미확인" : configuration)
                    .font(.caption.monospaced()).foregroundStyle(Palette.muted)
                if inspection.historyCutoff != nil { Label("기록 재생", systemImage: "clock.arrow.circlepath").font(.caption).foregroundStyle(Palette.amber) }
                else { Text("현재 IPC: \(inspection.liveStatus?.label ?? "현재 상태 미확인")").font(.caption).foregroundStyle(inspection.stale ? Palette.amber : Palette.mint) }
                if let turn { Text("기록: \(turn.status.label)").font(.caption).foregroundStyle(Palette.muted) }
                Spacer()
                if !inspection.atRoot { Button("상위 회로") { Task { await inspection.back() } }.font(.caption) }
            }
            if let prompt = inspection.selectedTurn?.promptNodeID.flatMap({ id in allNodes.first { $0.id == id } }) {
                HStack(alignment: .top, spacing: 12) {
                    Text(promptLabel).font(.caption).foregroundStyle(Palette.blue)
                    Button { select(prompt) } label: { Text(prompt.summary).font(.subheadline).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading) }
                        .buttonStyle(.plain).accessibilityLabel("현재 프롬프트 원문 선택")
                }.padding(10).background(Palette.selection.opacity(0.65), in: RoundedRectangle(cornerRadius: 6))
            }
        }.padding(.horizontal, 18).padding(.vertical, 13).background(Palette.panel)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Picker("상세 보기", selection: $tab) { ForEach(CircuitTab.allCases) { Text($0.label).tag($0) } }.pickerStyle(.segmented).frame(maxWidth: 285)
            if let graph = inspection.graph, !graph.turns.isEmpty {
                Picker("요청", selection: Binding(get: { inspection.followsCurrentTurn ? "" : inspection.selectedTurnID ?? "" }, set: { inspection.selectTurn($0.isEmpty ? nil : $0) })) {
                    Text("최신 요청 따라가기").tag("")
                    ForEach(graph.turns.reversed()) { turn in
                        Text(turnLabel(turn, graph: graph)).tag(turn.id)
                    }
                }.labelsHidden().frame(maxWidth: 280).accessibilityLabel("작업 요청 선택")
            }
            Spacer(minLength: 4)
            Button { motionEnabled.toggle() } label: { Label(motionEnabled && !reduceMotion ? "흐름 표시" : "흐름 정지", systemImage: "waveform.path") }
                .font(.caption).help("신호 움직임만 변경합니다. 기록 수집과 상태는 유지합니다.")
        }.padding(.horizontal,18).padding(.vertical,9).background(Palette.panel)
    }

    @ViewBuilder private var mainContent: some View {
        VStack(spacing: 0) {
            if let error = inspection.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Palette.red)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading).background(Palette.red.opacity(0.08))
            }
            if tab == .circuit {
                if displayedNodes.isEmpty {
                    EmptyPanel(symbol:"point.3.connected.trianglepath.dotted", title:"이 요청의 작업 기록 없음", detail:"확인 범위에서 읽은 출처와 미확인 항목을 확인할 수 있습니다.")
                } else {
                    VStack(spacing:0) {
                        HStack {
                            Text("\(displayedNodes.count)개 기록 · \(projection.items.count)개 표시").font(.caption).foregroundStyle(Palette.muted)
                            Spacer()
                            if focusedCallID != nil { Button("전체 작업 회로") { focusedCallID = nil }.font(.caption) }
                            if !expanded.isEmpty { Button("완료 기록 접기") { expanded = []; selectedGroupID = nil }.font(.caption) }
                        }.padding(.horizontal,18).padding(.vertical,8)
                        CircuitGraph(projection: projection, selectedID: selectedGroupID ?? inspection.selectedNodeID,
                                     animate: canAnimate, stale: inspection.stale,
                                     select: { item in if item.isGroup { selectedGroupID = item.id; inspection.selectNode(nil) } else { select(item.node) } })
                    }
                }
            } else if tab == .events { eventList }
            else { coverage }
            HStack(spacing: 8) {
                Image(systemName: inspection.stale ? "clock.badge.exclamationmark" : "clock")
                Text(inspection.stale ? "마지막 관찰 · 현재 실행 여부 미확인" : inspection.historyCutoff != nil ? "선택한 기록 시각의 상태" : "관찰된 기록을 증분 갱신")
                Spacer()
                if let date = inspection.graph?.loadedAt { Text(date,style:.time).monospacedDigit() }
            }.font(.caption).foregroundStyle(Palette.muted).padding(.horizontal,18).padding(.vertical,8).background(Palette.panel)
        }
    }

    private var eventList: some View {
        let rows = CircuitEventRow.rows(nodes:allNodes,cutoff:inspection.historyCutoff)
        let pages = max(1,(rows.count+59)/60), page = min(eventPage,pages-1)
        return VStack(spacing:0) {
            List(Array(rows.dropFirst(page*60).prefix(60))) { row in
                let node = row.node
                Button { selectedGroupID=nil;inspection.selectObservation(nodeID:node.id,index:row.observationIndex) } label: {
                    HStack(alignment:.top,spacing:10) {
                        if let date = node.timestamp { Text(date,style:.time).font(.caption.monospaced()).foregroundStyle(Palette.muted).frame(width:64,alignment:.leading) }
                        Image(systemName:node.kind.symbol).foregroundStyle(Palette.muted).frame(width:18)
                        VStack(alignment:.leading,spacing:4) {
                            Text(node.title).font(.subheadline)
                            Text(node.summary).font(.caption).foregroundStyle(Palette.muted).lineLimit(2)
                            if let ordinal=row.recordOrdinal { Text("원시 항목 \(ordinal)").font(.caption2.monospaced()).foregroundStyle(Palette.muted) }
                        }
                        Spacer(); WorkNodeState(node:node,stale:inspection.stale)
                    }.padding(.vertical,4).frame(maxWidth:.infinity,alignment:.leading)
                }.buttonStyle(.plain).listRowBackground(node.id == inspection.selectedNodeID && row.observationIndex == inspection.selectedObservationIndex ? Palette.selection : Color.clear)
            }.listStyle(.plain)
            HStack { Text("\(rows.count)개 상태 관찰 · \(page+1) / \(pages) 페이지").font(.caption).foregroundStyle(Palette.muted);Spacer();Button("이전") { eventPage = max(0,page-1) }.disabled(page==0);Button("다음") { eventPage = min(pages-1,page+1) }.disabled(page==pages-1) }.padding(12)
        }
    }

    private var coverage: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:18) {
                Text("기록된 실행과 관계만 연결합니다. 내부 reasoning과 기록되지 않은 서버 작업은 표시하지 않습니다.").font(.subheadline).foregroundStyle(Palette.muted)
                ForEach(inspection.graph?.coverage ?? []) { source in
                    VStack(alignment:.leading,spacing:6) {
                        HStack { Text(coverageLabel(source.status)).font(.caption).foregroundStyle(source.status == .complete ? Palette.mint : Palette.amber);Spacer();Text("\(source.records)개 · \(source.bytes.formatted()) bytes").font(.caption.monospaced()).foregroundStyle(Palette.muted) }
                        Text(source.source).font(.caption.monospaced()).textSelection(.enabled)
                        ForEach(Array(source.issues.enumerated()),id:\.offset) { _, issue in Text(issue).font(.caption).foregroundStyle(Palette.amber) }
                    }.padding(12).background(Palette.panel,in:RoundedRectangle(cornerRadius:7))
                }
                Text("응답 종료는 사용자 목표 충족을 증명하지 않습니다. 파일 참조, 생성·내용 확인, 빌드·테스트·설치·실행은 각각의 근거를 확인해야 합니다.").font(.caption).foregroundStyle(Palette.muted)
            }.padding(18).frame(maxWidth:.infinity,alignment:.leading)
        }
    }

    private var inspector: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:16) {
                if let group = selectedGroup {
                    Text(group.title).font(.headline)
                    Text("접힌 구성원 \(group.members.count)개 · 원본 ID와 연결을 보존합니다.").font(.caption).foregroundStyle(Palette.muted)
                    let whole = allNodes.filter { CircuitProjection.groupID($0) == group.id && ![.running,.waiting,.queued,.failed].contains($0.status) }
                    let pages = max(1,(whole.count+23)/24), page = min(groupPages[group.id] ?? 0,pages-1)
                    Button(expanded.contains(group.id) ? "이 묶음 접기" : "구성원 회로 펼치기") {
                        if expanded.contains(group.id) { expanded.remove(group.id) } else { expanded.insert(group.id) }
                    }
                    if expanded.contains(group.id), pages > 1 {
                        HStack { Button("이전") { groupPages[group.id] = max(0,page-1) }.disabled(page==0);Text("\(page+1) / \(pages)").font(.caption);Button("다음") { groupPages[group.id] = min(pages-1,page+1) }.disabled(page==pages-1) }
                        Text("페이지 밖 구성원은 회로의 나머지 묶음에 유지됩니다.").font(.caption).foregroundStyle(Palette.muted)
                    }
                    LazyVStack(alignment:.leading,spacing:0) {
                        ForEach(group.members) { node in
                            Button { select(node) } label: { VStack(alignment:.leading,spacing:4) { Text(node.title).font(.subheadline);WorkNodeState(node:node,stale:inspection.stale) }.padding(.vertical,8).frame(maxWidth:.infinity,alignment:.leading) }.buttonStyle(.plain)
                            Divider()
                        }
                    }
                } else if let node = selected {
                    HStack { Text(node.kind.label).font(.caption).foregroundStyle(Palette.muted);Spacer();WorkNodeState(node:node,stale:inspection.stale) }
                    Text(node.title).font(.headline).textSelection(.enabled)
                    Text(node.summary).font(.subheadline).textSelection(.enabled)
                    field("소속 turn",node.turnID ?? "소속 미확인")
                    field("항목 ID",node.id)
                    if let callID = node.callID { field("호출 ID",callID) }
                    if let date = node.timestamp { field("기록 시각",date.formatted(date:.numeric,time:.standard)) }
                    if let child = node.relatedSessionID {
                        Button("하위 세션 회로 열기") { Task { await inspection.openChild(child) } }
                            .accessibilityLabel("\(node.title)의 하위 세션 회로 열기")
                    }
                    if [.toolCall,.command,.mcp].contains(node.kind) {
                        Button("호출 세부 회로") { focusedCallID = node.id; tab = .circuit }
                    }
                    if inspection.bodyLoading { ProgressView("원문 확인 중…").controlSize(.small) }
                    else if let error = inspection.bodyError { Text(error).font(.caption).foregroundStyle(Palette.red) }
                    else {
                        let body = inspection.selectedBody ?? node.bodyPreview
                        Text("기록 원문").font(.caption).foregroundStyle(Palette.muted)
                        Text(String(body.prefix(bodyPages*12_000))).font(.system(.caption,design:.monospaced)).textSelection(.enabled)
                            .frame(maxWidth:.infinity,alignment:.leading).padding(10).background(Palette.card,in:RoundedRectangle(cornerRadius:6))
                        if body.count > bodyPages*12_000 { Button("원문 더 보기") { bodyPages += 1 } }
                    }
                    let related = allEdges.filter { $0.source == node.id || $0.target == node.id }
                    if !related.isEmpty {
                        Text("연결된 작업").font(.caption).foregroundStyle(Palette.muted)
                        ForEach(related) { edge in
                            let otherID = edge.source == node.id ? edge.target : edge.source
                            if let other = allNodes.first(where: { $0.id == otherID }) {
                                Button { select(other) } label: { VStack(alignment:.leading,spacing:3) { Text(other.title).font(.subheadline);Text(edge.label).font(.caption).foregroundStyle(Palette.muted) }.frame(maxWidth:.infinity,alignment:.leading) }.buttonStyle(.plain)
                                if !edge.evidence.isEmpty { Text(edge.evidence).font(.caption2).foregroundStyle(Palette.muted).textSelection(.enabled) }
                            }
                        }
                    }
                    Divider();field("출처",node.source)
                } else {
                    Text("작업을 선택하세요").font(.headline)
                    Text("회로 노드나 이벤트를 선택하면 원문·ID·연결 근거를 표시합니다.").font(.subheadline).foregroundStyle(Palette.muted)
                }
            }.padding(17).frame(maxWidth:.infinity,alignment:.leading)
        }.background(Palette.panel)
    }

    private var tokens: some View {
        CircuitTokenPanel(inspection:inspection,includeChildren:$includeChildren)
    }

    private var timeline: some View {
        let unique = eventDates
        let position = inspection.historyCutoff.flatMap { cutoff in unique.lastIndex(where: { $0 <= cutoff }) } ?? max(0,unique.count-1)
        return VStack(spacing:8) {
            HStack {
                Text(inspection.historyCutoff == nil ? "현재 기록 · \(unique.count)개 이벤트 시각" : "기록 재생 · \(position+1) / \(unique.count)").font(.caption).foregroundStyle(Palette.muted)
                if let date = inspection.historyCutoff { Text(date,style:.time).font(.caption.monospaced()) }
                Spacer()
                Button(replaying ? "재생 정지" : "이벤트 재생") { if replaying { replaying=false } else { if let first=unique.first { inspection.seek(to:first) };replaying=true } }.disabled(unique.isEmpty || reduceMotion)
                Button("다음 이벤트") { replaying=false;_ = advanceEvent() }.disabled(unique.isEmpty)
                Button("현재로") { replaying=false;inspection.returnToLive() }.disabled(inspection.historyCutoff==nil && inspection.selectedTurnID==inspection.graph?.currentTurnID)
            }
            if unique.count>1 {
                Slider(value:Binding(get:{ Double(position) },set:{ value in replaying=false;inspection.seek(to:unique[max(0,min(unique.count-1,Int(value)))]) }),in:0...Double(unique.count-1),step:1)
                    .accessibilityLabel("기록 재생 위치").accessibilityValue("\(position+1) / \(unique.count)")
            }
        }.padding(.horizontal,18).padding(.vertical,10).background(Palette.panel)
    }

    @discardableResult private func advanceEvent() -> Bool {
        let dates = eventDates
        guard let cutoff=inspection.historyCutoff else { if let first=dates.first { inspection.seek(to:first);return true };return false }
        guard let next=dates.first(where:{ $0>cutoff }) else { return false }
        inspection.seek(to:next)
        let stopped = inspection.visibleNodes.contains { [.waiting,.failed].contains($0.status) }
        return !stopped && next != dates.last
    }

    private func select(_ node:WorkNode) { selectedGroupID=nil;inspection.selectNode(node.id) }
    private var promptLabel:String {
        if !inspection.followsCurrentTurn || inspection.historyCutoff != nil { return "선택한 프롬프트" }
        return inspection.selectedTurn?.status == .running ? "현재 프롬프트" : "최근 프롬프트"
    }
    private func field(_ label:String,_ value:String) -> some View {
        VStack(alignment:.leading,spacing:4) { Text(label).font(.caption).foregroundStyle(Palette.muted);Text(value).font(.system(.caption,design:.monospaced)).textSelection(.enabled) }
    }
    private func turnLabel(_ turn:WorkTurn,graph:SessionWorkTopology) -> String {
        let prompt=turn.promptNodeID.flatMap { id in graph.nodes.first { $0.id==id } }
        let title=prompt.map { String(($0.summary.isEmpty ? $0.title : $0.summary).prefix(32)) } ?? String(turn.id.prefix(16))
        return (turn.startedAt.map { $0.formatted(date:.omitted,time:.shortened)+" · " } ?? "")+title
    }
    private func coverageLabel(_ status:ContextCoverageStatus) -> String {
        switch status { case .complete:"읽기 완료";case .partial:"일부 확인";case .missing:"기록 없음";case .error:"읽기 오류";case .skipped:"확인 제외" }
    }
}

private struct WorkNodeState: View {
    let node:WorkNode
    var stale:Bool
    var body:some View {
        HStack(spacing:4) {
            Image(systemName:node.status == .failed ? "diamond.fill" : node.status == .waiting ? "pause.fill" : "circle.fill").font(.system(size:6))
            Text(stale && node.status == .running ? "마지막 관찰: 실행 중" : label)
        }.font(.caption2).foregroundStyle(color)
    }
    private var label:String {
        switch node.status {
        case .waiting:node.kind == .waiting ? "입력 대기" : "결과 미수신"
        case .ended:[.session].contains(node.kind) ? "응답 종료" : [.toolCall,.command,.mcp,.toolResult].contains(node.kind) ? "반환 수신" : "기록 있음"
        default:node.status.label
        }
    }
    private var color:Color {
        if stale && node.status == .running { return Palette.muted }
        return switch node.status { case .running:Palette.blue;case .waiting,.queued:Palette.amber;case .failed:Palette.red;case .succeeded:Palette.mint;default:Palette.muted }
    }
}

private struct CircuitGraph: View {
    let projection:CircuitProjection
    let selectedID:String?
    let animate:Bool
    let stale:Bool
    let select:(CircuitItem)->Void
    @State private var routedKey:CircuitRouteKey?
    @State private var cachedRoutes:[CircuitRoute] = []
    var body:some View {
        GeometryReader { geometry in
            let layout=CircuitLayout(items:projection.items,width:geometry.size.width)
            let routeKey=CircuitRouteKey(layout:layout,wires:projection.wires)
            let routes=routedKey == routeKey ? cachedRoutes : []
            let selectedItem=selectedID.flatMap { projection.membership[$0] ?? $0 }
            let statuses=Dictionary(projection.items.map { ($0.id,$0.node.status) },uniquingKeysWith:{ _,last in last })
            ScrollView([.vertical,.horizontal]) {
                ZStack(alignment:.topLeading) {
                    CircuitWires(routes:routes,layout:layout,statuses:statuses,selectedID:selectedItem,animate:animate)
                    HStack(spacing:0) {
                        ForEach(0..<layout.columns,id:\.self) { column in
                            Text(layout.columns==4 ? ["입력·컨텍스트","프롬프트·세션","도구·하위 세션","결과·검증"][column] : ["입력·세션","도구·결과"][column]).font(.caption).foregroundStyle(Palette.muted).frame(maxWidth:.infinity,alignment:.leading)
                        }
                    }.padding(.horizontal,24).padding(.top,14)
                    ForEach(projection.items) { item in
                        if let frame=layout.frames[item.id] {
                            Button { select(item) } label: {
                                VStack(alignment:.leading,spacing:7) {
                                    HStack(spacing:5) { Image(systemName:item.node.kind.symbol);Text(item.node.kind.label);Spacer();if item.isGroup { Image(systemName:"square.stack") } }
                                        .font(.caption2).foregroundStyle(Palette.muted)
                                    Text(item.title).font(.subheadline.weight(.medium)).lineLimit(2).frame(maxWidth:.infinity,alignment:.leading)
                                    Spacer(minLength:0)
                                    if item.isGroup { Text("\(item.members.count)개 구성원 · 펼쳐 보기").font(.caption2).foregroundStyle(Palette.muted) }
                                    else { WorkNodeState(node:item.node,stale:stale) }
                                }.padding(12).frame(width:frame.width,height:frame.height,alignment:.topLeading)
                                    .background(isSelected(item) ? Palette.selection : item.node.status == .running && !stale ? Palette.blue.opacity(0.08) : Palette.panel,in:RoundedRectangle(cornerRadius:9))
                                    .overlay(RoundedRectangle(cornerRadius:9).stroke(isSelected(item) ? Palette.blue : item.node.status == .failed ? Palette.red : item.node.status == .waiting ? Palette.amber : Palette.border,lineWidth:isSelected(item) ? 2 : 1))
                            }.buttonStyle(.plain).position(x:frame.midX,y:frame.midY)
                                .accessibilityLabel("\(item.title), \(item.node.kind.label), \(item.isGroup ? "접힌 구성원 \(item.members.count)개" : item.node.status.label), \(stale ? "마지막 관찰" : "관찰 기록"), turn \(item.node.turnID ?? "미확인")")
                                .help(item.node.summary.isEmpty ? item.node.title : item.node.summary)
                        }
                    }
                }.frame(width:layout.size.width,height:layout.size.height)
            }.accessibilityLabel("작업 회로 · \(projection.items.count)개 노드")
                .onChange(of:routeKey,initial:true) { _,key in
                    cachedRoutes=CircuitRouting.routes(projection.wires,layout:layout);routedKey=key
                }
        }
    }
    private func isSelected(_ item:CircuitItem)->Bool { item.id==selectedID || selectedID.map { projection.membership[$0] == item.id } == true }
}

private struct CircuitWires: View {
    let routes:[CircuitRoute]
    let layout:CircuitLayout
    let statuses:[String:WorkStatus]
    let selectedID:String?
    let animate:Bool
    var body:some View {
        TimelineView(.animation(minimumInterval:1.0/30,paused:!animate)) { timeline in
            Canvas { context,size in
                for x in stride(from:CGFloat(0),through:size.width,by:24) {
                    var grid=Path();grid.move(to:CGPoint(x:x,y:0));grid.addLine(to:CGPoint(x:x,y:size.height));context.stroke(grid,with:.color(Palette.grid.opacity(0.2)),lineWidth:0.5)
                }
                for y in stride(from:CGFloat(0),through:size.height,by:24) {
                    var grid=Path();grid.move(to:CGPoint(x:0,y:y));grid.addLine(to:CGPoint(x:size.width,y:y));context.stroke(grid,with:.color(Palette.grid.opacity(0.2)),lineWidth:0.5)
                }
                for route in routes {
                    guard let first=route.points.first,let last=route.points.last else { continue }
                    let isSelected=route.wire.source==selectedID || route.wire.target==selectedID
                    let sourceStatus=statuses[route.wire.source]
                    let active=animate && [.calls,.spawnedSession].contains(route.wire.kind) &&
                        sourceStatus != .failed && sourceStatus != .cancelled &&
                        statuses[route.wire.target] == .running
                    let color:Color=[.spawnedSession,.sentToSession,.reportedBy].contains(route.wire.kind) ? Palette.purple : active ? Palette.blue : Palette.branch
                    let dash:[CGFloat]=[.observedUsage,.historicalAssociation].contains(route.wire.kind) ? [2,5] : route.wire.kind == .belongsToTurn ? [4,5] : []
                    var path=Path();path.move(to:first);for point in route.points.dropFirst() { path.addLine(to:point) }
                    context.stroke(path,with:.color(color.opacity(isSelected || active ? 1 : 0.55)),style:StrokeStyle(lineWidth:isSelected || active ? 1.6 : 1,dash:dash))
                    if route.points.count>1 {
                        let previous=route.points[route.points.count-2],angle=atan2(last.y-previous.y,last.x-previous.x)
                        var arrow=Path();arrow.move(to:CGPoint(x:last.x-5*cos(angle-0.5),y:last.y-5*sin(angle-0.5)));arrow.addLine(to:last);arrow.addLine(to:CGPoint(x:last.x-5*cos(angle+0.5),y:last.y-5*sin(angle+0.5)));context.stroke(arrow,with:.color(color),lineWidth:1)
                    }
                    if active,let point=CircuitRouting.point(along:route.points,fraction:timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy:2.8)/2.8) {
                        context.fill(Path(ellipseIn:CGRect(x:point.x-2.5,y:point.y-2.5,width:5,height:5)),with:.color(color))
                    }
                }
            }
        }.frame(width:layout.size.width,height:layout.size.height).allowsHitTesting(false).accessibilityHidden(true)
    }
}
