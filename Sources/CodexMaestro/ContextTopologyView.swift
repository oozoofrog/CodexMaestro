import SwiftUI
import MaestroCore

struct ContextTopologyView: View {
    @Bindable var store: MaestroStore
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { store.returnToSessionWork() } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.plain)
                    .help(store.workInspection == nil ? "작업 흐름으로 돌아가기" : "작업 회로로 돌아가기")
                    .accessibilityLabel(store.workInspection == nil ? "작업 흐름으로 돌아가기" : "작업 회로로 돌아가기")
                Text(store.contextScope.map { store.endpointTitle($0) } ?? "컨텍스트")
                    .font(.system(size: 18, weight: .medium)).lineLimit(1)
                Text("컨텍스트").font(.system(size: 11)).foregroundStyle(Palette.muted)
                Spacer()
                ToolButton(symbol: "arrow.clockwise", help: "컨텍스트 다시 읽기") {
                    if let endpoint = store.contextScope { store.openContext(for: endpoint) }
                }
            }.padding(18).background(Palette.panel)
            Divider()
            if store.contextLoading {
                VStack(spacing: 12) { ProgressView(); Text("기록을 읽는 중").font(.system(size: 12)).foregroundStyle(Palette.muted) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = store.contextError {
                VStack(spacing: 12) {
                    EmptyPanel(symbol: "exclamationmark.triangle", title: "기록을 읽지 못했습니다", detail: error)
                    Button("다시 읽기") { if let endpoint = store.contextScope { store.openContext(for: endpoint) } }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let graph = store.contextTopology {
                ContextMapContent(store: store, graph: graph).id(graph.loadedAt)
            }
        }.background(Palette.canvas)
    }
}

private struct ContextMapContent: View {
    @Bindable var store: MaestroStore
    let graph: ContextTopology
    let byID: [String: ContextNode]
    let children: [String: [ContextNode]]
    let edgesBySource: [String: [ContextEdge]]
    @State private var path: [String]
    @State private var selectedID: String?
    @State private var page = 0
    @State private var search = ""
    @State private var searchMatches: [ContextNode] = []
    @State private var zoom = 0.9
    @State private var showingCoverage = false
    @State private var bodyText = ""
    @State private var bodyLoading = false
    @State private var bodyError: String?
    @State private var bodyPage = 0
    @State private var bodyCount = 0
    private let pageSize = 18
    private let bodyPageSize = 12_000

    init(store: MaestroStore, graph: ContextTopology) {
        self.store = store; self.graph = graph
        let nodeIndex = Dictionary(graph.nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        byID = nodeIndex
        var relations = Dictionary(grouping: graph.nodes.filter { $0.parentID != nil }, by: { $0.parentID! })
        var pairs = Set(graph.nodes.compactMap { node in node.parentID.map { $0 + "|" + node.id } })
        for edge in graph.edges where edge.source != edge.target {
            if pairs.insert(edge.source + "|" + edge.target).inserted, let node = nodeIndex[edge.target] {
                relations[edge.source, default: []].append(node)
            }
        }
        func displayRank(_ kind: ContextNodeKind) -> Int {
            switch kind {
            case .project, .session, .group, .tool: 0
            case .skill, .plugin: 2
            case .file: 3
            default: 1
            }
        }
        children = relations.mapValues { nodes in
            nodes.enumerated().sorted { left, right in
                let lhs = displayRank(left.element.kind), rhs = displayRank(right.element.kind)
                return lhs == rhs ? left.offset < right.offset : lhs < rhs
            }.map(\.element)
        }
        edgesBySource = Dictionary(grouping: graph.edges, by: \.source)
        let root = graph.nodes.first { $0.parentID == nil }?.id ?? ""
        _path = State(initialValue: [root]); _selectedID = State(initialValue: root)
    }
    private var focus: ContextNode? { byID[path.last ?? ""] }
    private var selected: ContextNode? { selectedID.flatMap { byID[$0] } }
    private var candidates: [ContextNode] {
        if !search.isEmpty {
            return searchMatches
        }
        return children[path.last ?? ""] ?? []
    }
    private var pageNodes: [ContextNode] {
        let values = candidates
        let start = min(page * pageSize, values.count)
        return Array(values.dropFirst(start).prefix(pageSize))
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach(Array(path.enumerated()), id: \.offset) { index, id in
                    if index > 0 { Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(Palette.muted) }
                    Button(byID[id]?.title ?? "컨텍스트") {
                        path = Array(path.prefix(index + 1)); selectedID = id; page = 0; search = ""
                    }.buttonStyle(.plain).font(.system(size: 11)).lineLimit(1)
                }
                Spacer(minLength: 10)
                Menu {
                    ForEach(ContextOptimizationMode.allCases) { mode in
                        Button(mode.label) { store.requestOptimization(graph: graph, mode: mode, selectedNodeID: selectedID) }
                    }
                } label: { Label("개선 요청", systemImage: "sparkles") }.font(.system(size: 12)).fixedSize()
                    .disabled(graph.sessions.isEmpty)
            }.padding(.horizontal, 16).padding(.vertical, 10)
            HSplitView {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(Palette.muted)
                        TextField("기록 검색", text: $search).textFieldStyle(.plain).font(.system(size: 12))
                        if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain) }
                    }.padding(10).background(Palette.panel)
                    ScrollView([.horizontal, .vertical]) {
                        ContextGraphPage(focus: focus, nodes: pageNodes, edges: visibleEdges, selectedID: selectedID,
                            select: { selectedID = $0.id }, enter: enter)
                            .scaleEffect(zoom, anchor: .topLeading)
                            .frame(width: 720 * zoom, height: pageHeight * zoom, alignment: .topLeading)
                    }.background(Palette.canvas)
                    HStack(spacing: 8) {
                        ToolButton(symbol: "minus", help: "축소") { zoom = max(0.45, zoom - 0.1) }
                        Text("\(Int(zoom * 100))%").font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.muted)
                        ToolButton(symbol: "plus", help: "확대") { zoom = min(1.4, zoom + 0.1) }
                        Spacer()
                        if candidates.count > pageSize {
                            Button { page = max(0, page - 1) } label: { Image(systemName: "chevron.left") }.disabled(page == 0)
                            Text("\(page * pageSize + 1)–\(min((page + 1) * pageSize, candidates.count)) / \(candidates.count)")
                                .font(.system(size: 10, design: .monospaced))
                            Button { page += 1 } label: { Image(systemName: "chevron.right") }.disabled((page + 1) * pageSize >= candidates.count)
                        } else { Text("\(candidates.count)개 항목").font(.system(size: 10)).foregroundStyle(Palette.muted) }
                    }.padding(10).background(Palette.panel)
                }.frame(minWidth: 430, maxWidth: .infinity)
                inspector.frame(minWidth: 280, idealWidth: 330, maxWidth: 420)
            }
            HStack(spacing: 12) {
                Text("저장된 기록").foregroundStyle(Palette.muted)
                Text("\(graph.sessions.count)개 세션 · \(graph.nodes.count)개 항목")
                if !graph.coverage.allSatisfy({ $0.status == .complete }) {
                    Text("일부 기록 확인 필요").foregroundStyle(Palette.amber)
                }
                Spacer()
                ToolButton(symbol: "info.circle", help: "출처와 확인 범위", active: showingCoverage) { showingCoverage.toggle() }
                    .popover(isPresented: $showingCoverage) { coverageView }
            }.font(.system(size: 10)).padding(.horizontal, 14).padding(.vertical, 5).background(Palette.panel)
        }
        .onChange(of: search) { _, value in
            page = 0
            searchMatches = value.isEmpty ? [] : graph.nodes.filter {
                $0.id != path.last && ($0.title.localizedCaseInsensitiveContains(value) || $0.summary.localizedCaseInsensitiveContains(value))
            }
        }
        .task(id: selectedID) { await readSelectedBody() }
    }
    private var pageHeight: CGFloat { max(560, CGFloat(pageNodes.count) * 116 + 80) }
    private var visibleEdges: [ContextEdge] {
        let ids = Set(pageNodes.map(\.id) + [focus?.id].compactMap { $0 })
        return ids.flatMap { edgesBySource[$0] ?? [] }.filter { ids.contains($0.target) }
    }
    private func enter(_ node: ContextNode) {
        selectedID = node.id
        if !(children[node.id] ?? []).isEmpty, path.last != node.id {
            if search.isEmpty, !path.contains(node.id) { path.append(node.id) }
            else {
                var ancestry: [String] = [], cursor: String? = node.id, visited = Set<String>()
                while let id = cursor, visited.insert(id).inserted {
                    ancestry.append(id); cursor = byID[id]?.parentID
                }
                path = ancestry.reversed()
            }
            page = 0; search = ""
        }
    }
    private var inspector: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let node = selected {
                HStack(spacing: 8) {
                    Image(systemName: node.kind.symbol).foregroundStyle(Palette.blue)
                    Text(node.title).font(.system(size: 14, weight: .medium)).lineLimit(3)
                }.padding(16)
                if let session = graph.sessions.first(where: { $0.id == node.sessionID }), session.isArchived {
                    Text("보관된 세션").font(.system(size: 10)).foregroundStyle(Palette.muted).padding(.horizontal, 16).padding(.bottom, 10)
                }
                if !(children[node.id] ?? []).isEmpty {
                    Button { enter(node) } label: { Label("펼치기", systemImage: "arrow.down.right.and.arrow.up.left") }
                        .font(.system(size: 11)).padding(.horizontal, 16).padding(.bottom, 12)
                }
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if bodyLoading { ProgressView() }
                        else if let bodyError { Text(bodyError).foregroundStyle(Palette.amber) }
                        else { Text(bodyExcerpt.isEmpty ? node.summary : bodyExcerpt).textSelection(.enabled) }
                        if bodyCount > bodyPageSize {
                            HStack {
                                Button { bodyPage = max(0, bodyPage - 1) } label: { Image(systemName: "chevron.left") }.disabled(bodyPage == 0)
                                Text("\(bodyPage * bodyPageSize + 1)–\(min((bodyPage + 1) * bodyPageSize, bodyCount)) / \(bodyCount)글자").font(.system(size: 10, design: .monospaced))
                                Button { bodyPage += 1 } label: { Image(systemName: "chevron.right") }.disabled((bodyPage + 1) * bodyPageSize >= bodyCount)
                            }
                        }
                        if node.charCount > 0 { Text("\(node.charCount)글자 · 기록 크기").font(.system(size: 10)).foregroundStyle(Palette.muted) }
                        if !node.source.isEmpty {
                            Divider()
                            Text(node.source).font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.muted).textSelection(.enabled)
                        }
                    }.font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading).padding(16)
                }
            } else { EmptyPanel(symbol: "point.3.connected.trianglepath.dotted", title: "항목 선택", detail: "") }
        }.background(Palette.panel)
    }
    private var coverageView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("출처와 확인 범위").font(.system(size: 14, weight: .medium))
                ForEach(graph.boundaries, id: \.self) { Text($0).font(.system(size: 11)).foregroundStyle(Palette.muted) }
                Divider()
                ForEach(graph.coverage) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.source).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                        Text("\(coverageLabel(item.status)) · \(item.records)개 기록 · \(item.bytes)바이트").font(.system(size: 10)).foregroundStyle(Palette.muted)
                        ForEach(item.issues, id: \.self) { Text($0).font(.system(size: 10)).foregroundStyle(Palette.amber) }
                    }
                }
            }.padding(18).frame(width: 440, alignment: .leading)
        }.frame(maxHeight: 480)
    }
    private func coverageLabel(_ status: ContextCoverageStatus) -> String {
        switch status { case .complete: "읽음"; case .partial: "일부 읽음"; case .missing: "기록 없음"; case .error: "읽기 실패"; case .skipped: "제외됨" }
    }
    private var bodyExcerpt: String {
        bodyCount > bodyPageSize ? String(bodyText.dropFirst(bodyPage * bodyPageSize).prefix(bodyPageSize)) : bodyText
    }
    private func readSelectedBody() async {
        guard let node = selected else { bodyText = ""; return }
        bodyText = ""; bodyError = nil; bodyLoading = true; bodyPage = 0; bodyCount = 0
        defer { if selectedID == node.id && !Task.isCancelled { bodyLoading = false } }
        do {
            let result = try await ContextTopologyLoader(home: store.catalog.home).loadBody(node: node)
            try Task.checkCancellation()
            guard selectedID == node.id else { return }
            bodyCount = result.count; bodyText = result
        } catch is CancellationError { }
        catch { guard selectedID == node.id, !Task.isCancelled else { return }; bodyError = error.localizedDescription }
    }
}

private struct ContextGraphPage: View {
    let focus: ContextNode?
    let nodes: [ContextNode]
    let edges: [ContextEdge]
    let selectedID: String?
    let select: (ContextNode) -> Void
    let enter: (ContextNode) -> Void
    private var height: CGFloat { max(560, CGFloat(nodes.count) * 116 + 80) }
    private var center: CGPoint { CGPoint(x: 150, y: min(height / 2, 280)) }
    private func point(_ index: Int) -> CGPoint { CGPoint(x: 500, y: 80 + CGFloat(index) * 116) }
    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                let center = center
                var points = Dictionary(nodes.enumerated().map { ($0.element.id, point($0.offset)) }, uniquingKeysWith: { first, _ in first })
                if let focus { points[focus.id] = center }
                for (index, node) in nodes.enumerated() where node.parentID == focus?.id || edges.contains(where: { $0.source == focus?.id && $0.target == node.id }) {
                    let target = point(index)
                    var path = Path()
                    path.move(to: CGPoint(x: center.x + 115, y: center.y))
                    path.addCurve(to: CGPoint(x: target.x - 115, y: target.y),
                        control1: CGPoint(x: center.x + 150, y: center.y), control2: CGPoint(x: target.x - 150, y: target.y))
                    context.stroke(path, with: .color(Palette.blue.opacity(0.25)), lineWidth: 1.2)
                }
                for edge in edges where edge.relation != "contains" {
                    guard let a = points[edge.source], let b = points[edge.target], edge.source != focus?.id else { continue }
                    var path = Path(); path.move(to: a); path.addLine(to: b)
                    context.stroke(path, with: .color(Palette.muted.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                }
            }.allowsHitTesting(false)
            if let focus { card(focus).position(center) }
            ForEach(Array(nodes.enumerated()), id: \.element.id) { index, node in card(node).position(point(index)) }
            if nodes.isEmpty { Text("하위 기록 없음").font(.system(size: 12)).foregroundStyle(Palette.muted).position(x: 570, y: height / 2) }
        }.frame(width: 720, height: height)
    }
    private func card(_ node: ContextNode) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: node.kind.symbol).foregroundStyle(Palette.blue)
                Text(node.title).font(.system(size: 12, weight: .medium)).lineLimit(2)
            }
            HStack {
                Text(node.summary.isEmpty ? node.kind.label : node.summary).font(.system(size: 10)).foregroundStyle(Palette.muted).lineLimit(2)
                Spacer(minLength: 0)
                if node.recordCount > 0 { Text("\(node.recordCount)").font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.muted) }
            }
        }.padding(12).frame(width: 230, height: 90, alignment: .topLeading)
            .background(selectedID == node.id ? Palette.selection : Palette.panel, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(selectedID == node.id ? Palette.blue : Palette.border))
            .contentShape(Rectangle())
            .gesture(TapGesture(count: 2).exclusively(before: TapGesture(count: 1)).onEnded { value in
                switch value { case .first: enter(node); case .second: select(node) }
            })
            .accessibilityElement(children: .combine).accessibilityAddTraits(.isButton)
            .accessibilityAction { select(node) }.accessibilityAction(named: "펼치기") { enter(node) }
    }
}

struct ContextOptimizationView: View {
    @Bindable var store: MaestroStore
    let proposal: ContextOptimizationProposal
    @State private var recipient = ""
    @State private var prompt: String
    @State private var preparing = false
    @State private var operationError: String?
    init(store: MaestroStore, proposal: ContextOptimizationProposal) {
        self.store = store; self.proposal = proposal
        _prompt = State(initialValue: ContextOptimizationPrompt.make(proposal))
        _recipient = State(initialValue: proposal.graph.scope.kind == .session ? proposal.graph.scope.id : "")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(proposal.mode.label).font(.system(size: 18, weight: .medium))
            Text(proposal.graph.title).font(.system(size: 12)).foregroundStyle(Palette.muted)
            Picker("담당", selection: $recipient) {
                Text("세션 선택").tag("")
                ForEach(store.optimizationRecipients(for: proposal)) { session in Text(session.title).tag(session.id) }
            }
            TextEditor(text: $prompt).font(.system(size: 12)).padding(5)
                .background(Palette.card, in: RoundedRectangle(cornerRadius: 8)).frame(minHeight: 320)
                .accessibilityLabel("개선 요청 내용")
            Text("초안을 확인하고 전송하면 실행됩니다.").font(.system(size: 10)).foregroundStyle(Palette.muted)
            if let operationError { Text(operationError).font(.system(size: 11)).foregroundStyle(Palette.amber) }
            HStack {
                Button("취소") { store.optimizationProposal = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("초안 준비") {
                    preparing = true
                    Task {
                        if !(await store.prepareContextOptimization(proposal, recipientID: recipient, prompt: prompt)) {
                            operationError = store.error; store.error = nil
                        }
                        preparing = false
                    }
                }.keyboardShortcut(.defaultAction).disabled(preparing || recipient.isEmpty || !store.optimizationRecipients(for: proposal).contains { $0.id == recipient } || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 620, height: 540).background(Palette.panel)
    }
}
