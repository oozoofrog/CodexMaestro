import SwiftUI
import MaestroCore
import Observation
import AppKit

private struct PositionedSession: Identifiable {
    var id: String { session.id }
    let session: Session
    let point: CGPoint
}
private struct PositionedProject: Identifiable {
    var id: String { project.id }
    let project: Project
    let point: CGPoint
    let items: [PositionedSession]
    let hiddenCount: Int
}
struct TopologyCanvas: View {
    @Bindable var store: MaestroStore
    @State private var drag = TopologyDragState()
    @State private var connectionDrag = TopologyConnectionDragState()
    @State private var showingLegend = false
    @Environment(\.colorScheme) private var colorScheme
    private let cardWidth: CGFloat = 240
    private var groups: [PositionedProject] {
        TopologyPerformance.layoutPasses += 1
        let filtered = store.filteredSessions
        let byProject = Dictionary(grouping: filtered) { $0.projectID ?? "unassigned" }
        let projects = store.orderedProjects(for: filtered)
        let displayed = projects.map { project in
            store.displayedSessions(byProject[project.id] ?? [], projectID: project.id)
        }
        var rowOrigins: [CGFloat] = []
        var nextOrigin: CGFloat = 68
        for start in stride(from: 0, to: projects.count, by: 3) {
            rowOrigins.append(nextOrigin)
            let count = displayed[start..<min(start + 3, displayed.count)].map(\.count).max() ?? 1
            nextOrigin += CGFloat(count) * 136 + 170
        }
        return projects.enumerated().map { index, project in
            let origin = CGPoint(x: 160 + CGFloat(index % 3) * 285, y: rowOrigins[index / 3])
            let items = displayed[index].enumerated().map { offset, session in
                PositionedSession(session: session,
                    point: store.position(for: session.id, fallback: CGPoint(x: origin.x, y: origin.y + 116 + CGFloat(offset) * 136)))
            }
            return PositionedProject(project: project, point: store.position(for: "project:" + project.id, fallback: origin), items: items,
                hiddenCount: (byProject[project.id]?.count ?? 0) - items.count)
        }
    }
    private func graphSize(_ groups: [PositionedProject]) -> CGSize {
        let all = groups.flatMap(\.items)
        return CGSize(width: max(920, (groups.map { $0.point.x } + all.map { $0.point.x }).max().map { $0 + 160 } ?? 920), height: max(570, (groups.map { $0.point.y } + all.map { $0.point.y }).max().map { $0 + 160 } ?? 570))
    }
    var body: some View {
        let groups = groups
        let graphSize = graphSize(groups)
        return VStack(spacing: 0) {
            ScrollView([.horizontal, .vertical]) {
                graph(groups, size: graphSize)
                    .frame(width: graphSize.width, height: graphSize.height)
                    .scaleEffect(store.zoom, anchor: .topLeading)
                    .frame(width: graphSize.width * store.zoom, height: graphSize.height * store.zoom, alignment: .topLeading)
            }.background(Palette.canvas)
            canvasControls
                .padding(.horizontal, 16).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading).background(Palette.panel)
        }
    }
    private func graph(_ groups: [PositionedProject], size: CGSize) -> some View {
        let selected: LinkEndpoint? = store.selectedSessionID.map { .session($0) } ?? store.selectedNodeProjectID.map { .project($0) }
        let links = store.workspace.allNodeLinks
        let related = TopologyRelatedNodes.endpoints(selected: selected, links: links)
        let targets = groups.flatMap { group in
            [TopologyNodeGeometry(endpoint: .project(group.id), point: group.point)]
                + group.items.map { TopologyNodeGeometry(endpoint: .session($0.id), point: $0.point) }
        }
        let eligible = Set(store.projects.map { LinkEndpoint.project($0.id) } + store.sessions.map { LinkEndpoint.session($0.id) })
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(ImagePaint(image: TopologyGrid.image(dark: colorScheme == .dark)))
                .allowsHitTesting(false)
            TopologyEdges(groups: groups, links: links, showLinks: store.showLinks, drag: drag, canvasSize: size)
                .allowsHitTesting(false)
            ForEach(groups) { group in
                projectNode(group, related: related.contains(.project(group.id)))
                    .modifier(TopologyNodeDragModifier(store: store, endpoint: .project(group.id), point: group.point,
                        drag: drag, connection: connectionDrag, targets: targets, eligible: eligible))
                ForEach(group.items) { item in
                    DraggableSessionNode(store: store, item: item, drag: drag, connection: connectionDrag,
                        targets: targets, eligible: eligible, related: related.contains(.session(item.id)))
                }
                if group.hiddenCount > 0, let last = group.items.last {
                    Button { store.expandedProjects.insert(group.id) } label: { Label("\(group.hiddenCount)개 세션 더 보기", systemImage: "plus").font(.system(size: 11)).foregroundStyle(Palette.muted).padding(10) }.buttonStyle(.plain).position(x: group.point.x, y: last.point.y + 82)
                }
            }
        }.coordinateSpace(name: "topology")
            .background(TopologyConnectionCancellation(state: connectionDrag).frame(width: 0, height: 0))
            .onDisappear { connectionDrag.cancel() }
    }
    private func projectNode(_ group: PositionedProject, related: Bool) -> some View {
        let endpoint = LinkEndpoint.project(group.id)
        let selected = store.selectedNodeProjectID == group.id
        let linking = store.linkingEndpoint == endpoint
        return HStack(spacing: 8) {
            HStack(spacing: 10) {
                    Image(systemName: "folder").font(.system(size: 17)).foregroundStyle(Palette.blue)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(group.project.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Text("\(group.items.count + group.hiddenCount)개 세션").font(.system(size: 11)).foregroundStyle(Palette.muted)
                    }
                    Spacer(minLength: 0)
            }.frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
                .gesture(TapGesture(count: 2).onEnded { store.openContext(for: endpoint) }
                    .exclusively(before: TapGesture().onEnded { store.selectEndpoint(endpoint) }))
                .accessibilityAction { store.selectEndpoint(endpoint) }
                .accessibilityAction(named: Text("컨텍스트 열기")) { store.openContext(for: endpoint) }
                .accessibilityLabel("\(group.project.name) 프로젝트 · \(group.items.count + group.hiddenCount)개 세션")
                .accessibilityAddTraits(selected ? .isSelected : [])
            Button { store.beginLink(from: endpoint) } label: {
                Image(systemName: "link").font(.system(size: 12))
                    .foregroundStyle(linking ? Palette.blue : Palette.muted).frame(width: 24, height: 24)
            }.buttonStyle(.plain).help("이 프로젝트에서 연결 만들기")
                .accessibilityLabel("\(group.project.name) 프로젝트 연결 만들기")
                .disabled(!store.endpointExists(endpoint))
        }.padding(12).frame(width: cardWidth, height: 58)
            .background(selected ? Palette.selection : Palette.panel, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected || linking ? Palette.blue : (related ? Palette.blue.opacity(0.45) : Palette.border), lineWidth: selected || linking ? 1.5 : 1))
            .contextMenu {
                Button("프로젝트 선택") { store.selectEndpoint(endpoint) }
                    .disabled(store.linkingEndpoint != nil && !store.endpointExists(endpoint))
                Button("연결 만들기") { store.beginLink(from: endpoint) }.disabled(!store.endpointExists(endpoint))
                if !group.project.roots.isEmpty { Button("Finder에서 열기") { store.revealProject(group.project) } }
            }
    }
    private var edgeLegend: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) { legendItems }
            VStack(alignment: .leading, spacing: 6) { legendItems }
        }.font(.system(size: 10)).foregroundStyle(Palette.muted)
            .accessibilityElement(children: .combine).accessibilityLabel("연결선 범례")
    }
    @ViewBuilder private var legendItems: some View {
        legendSample("프로젝트 소속", color: Palette.branch)
        ForEach(LinkKind.allCases, id: \.self) { kind in legendSample(kind.label, color: Palette.link(kind)) }
        legendSample("부모 세션", color: Palette.muted, dashed: true)
    }
    private func legendSample(_ label: String, color: Color, dashed: Bool = false) -> some View {
        HStack(spacing: 5) {
            Path { p in p.move(to: .zero); p.addLine(to: CGPoint(x: 18, y: 0)) }
                .stroke(color, style: StrokeStyle(lineWidth: 1.4, dash: dashed ? [3, 3] : []))
                .frame(width: 18, height: 1)
            Text(label)
        }
    }
    private var canvasControls: some View {
        HStack(spacing: 7) {
            ToolButton(symbol: "minus", help: "축소") { store.zoom = max(0.35, store.zoom - 0.1) }
            Text("\(Int(store.zoom * 100))%").font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.muted).frame(width: 36)
            ToolButton(symbol: "plus", help: "확대") { store.zoom = min(1.6, store.zoom + 0.1) }
            Rectangle().fill(Palette.border).frame(width: 1, height: 18)
            ToolButton(symbol: "arrow.up.left.and.arrow.down.right", help: "레이아웃 초기화") { store.resetPositions() }
            ToolButton(symbol: "link", help: "연결선 표시", active: store.showLinks) { store.showLinks.toggle() }
            Spacer(minLength: 0)
            ToolButton(symbol: "info.circle", help: "연결선과 조작 안내", active: showingLegend) { showingLegend.toggle() }
                .popover(isPresented: $showingLegend) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("겹쳐 놓아 요청 · 빈 곳에 놓아 배치 · 두 번 클릭으로 컨텍스트 열기 · Esc로 취소")
                            .font(.system(size: 11)).foregroundStyle(Palette.muted)
                        edgeLegend
                    }.padding(16)
                }
        }.padding(5).background(Palette.panel.opacity(0.97), in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.border))
    }
}

// Drag state is observed by the edge layer only; the layout and siblings never read it.
@MainActor @Observable final class TopologyDragState {
    var endpoint: LinkEndpoint?
    var offset: CGSize = .zero
    var basePoint: CGPoint?
    func clear() { endpoint = nil; offset = .zero; basePoint = nil }
}

enum TopologyGestureMode: Equatable {
    case position, ignored
}

/// Capture movement eligibility once, until this gesture ends or is cancelled.
struct TopologyGestureSession {
    private(set) var mode: TopologyGestureMode?
    mutating func begin(canMove: Bool) {
        if mode == nil { mode = canMove ? .position : .ignored }
    }
    mutating func clear() { mode = nil }
}

@MainActor @Observable final class TopologyConnectionDragState {
    private(set) var source: LinkEndpoint?
    private(set) var target: LinkEndpoint?
    private(set) var cancelled = false
    func begin(source: LinkEndpoint) {
        self.source = source; target = nil; cancelled = false
    }
    func update(pointer: CGPoint, targets: [TopologyNodeGeometry], eligible: Set<LinkEndpoint>) {
        guard let source, !cancelled else { return }
        let moved = TopologyNodeGeometry(endpoint: source, point: pointer)
        let next = TopologyConnectionHitTest.target(overlapping: moved, nodes: targets, eligible: eligible)
        if target != next { target = next }
    }
    func completedTarget(from endpoint: LinkEndpoint) -> LinkEndpoint? {
        guard source == endpoint, !cancelled else { return nil }
        return target
    }
    func clear() { source = nil; target = nil; cancelled = false }
    func cancel() { source = nil; target = nil; cancelled = true }
}

enum TopologyConnectionHitTest {
    static let minimumOverlapFraction: CGFloat = 0.2
    static func target(overlapping moved: TopologyNodeGeometry, nodes: [TopologyNodeGeometry], eligible: Set<LinkEndpoint>) -> LinkEndpoint? {
        guard eligible.contains(moved.endpoint), !(moved.endpoint.kind == .project && moved.endpoint.id == "unassigned") else { return nil }
        let candidates = nodes.enumerated().filter { _, node in
            guard node.endpoint != moved.endpoint, eligible.contains(node.endpoint),
                  !(node.endpoint.kind == .project && node.endpoint.id == "unassigned") else { return false }
            let overlap = moved.frame.intersection(node.frame)
            let smallerArea = min(moved.frame.width * moved.frame.height, node.frame.width * node.frame.height)
            return !overlap.isNull && overlap.width * overlap.height >= smallerArea * minimumOverlapFraction
        }
        return candidates.min { lhs, rhs in
            let left = hypot(lhs.element.point.x - moved.point.x, lhs.element.point.y - moved.point.y)
            let right = hypot(rhs.element.point.x - moved.point.x, rhs.element.point.y - moved.point.y)
            return left == right ? lhs.offset > rhs.offset : left < right
        }?.element.endpoint
    }
}

private struct DraggableSessionNode: View {
    let store: MaestroStore
    let item: PositionedSession
    let drag: TopologyDragState
    let connection: TopologyConnectionDragState
    let targets: [TopologyNodeGeometry]
    let eligible: Set<LinkEndpoint>
    let related: Bool
    var body: some View {
        SessionCard(store: store, item: item, related: related)
            .modifier(TopologyNodeDragModifier(store: store, endpoint: .session(item.id), point: item.point,
                drag: drag, connection: connection, targets: targets, eligible: eligible))
    }
}

private struct TopologyGestureSnapshot {
    var translation: CGSize = .zero
    var active = false
}

private struct TopologyNodeDragModifier: ViewModifier {
    let store: MaestroStore
    let endpoint: LinkEndpoint
    let point: CGPoint
    let drag: TopologyDragState
    let connection: TopologyConnectionDragState
    let targets: [TopologyNodeGeometry]
    let eligible: Set<LinkEndpoint>
    @GestureState private var snapshot = TopologyGestureSnapshot()
    @State private var gesture = TopologyGestureSession()
    @State private var origin: CGPoint?
    private var canConnect: Bool {
        eligible.contains(endpoint) && !(endpoint.kind == .project && endpoint.id == "unassigned")
    }
    func body(content: Content) -> some View {
        content.overlay(TopologyConnectionCue(endpoint: endpoint, state: connection))
            .position(origin ?? point).offset(connection.cancelled ? .zero : snapshot.translation)
            .simultaneousGesture(DragGesture(minimumDistance: 8, coordinateSpace: .named("topology"))
                .updating($snapshot) { value, state, _ in
                    state.active = true
                    let control = TopologyNodeGeometry(endpoint: endpoint, point: origin ?? point).isConnectionControl(at: value.startLocation)
                    state.translation = canConnect && !control && !connection.cancelled ? value.translation : .zero
                }
                .onChanged { value in
                    let starting = gesture.mode == nil
                    if starting {
                        let control = TopologyNodeGeometry(endpoint: endpoint, point: point).isConnectionControl(at: value.startLocation)
                        gesture.begin(canMove: canConnect && !control)
                        guard gesture.mode == .position else { return }
                        // The named graph coordinate space supplies unscaled geometry units.
                        // Freeze the canonical origin for the complete gesture.
                        origin = point; drag.basePoint = point; drag.endpoint = endpoint
                        store.cancelLink()
                        connection.begin(source: endpoint)
                        TopologyPerformance.beginDrag()
                    }
                    guard gesture.mode == .position, !connection.cancelled else { return }
                    let base = origin ?? point
                    TopologyPerformance.dragUpdates += 1
                    drag.offset = value.translation
                    connection.update(pointer: CGPoint(x: base.x + value.translation.width, y: base.y + value.translation.height),
                        targets: targets, eligible: eligible)
                }
                .onEnded { value in
                    if gesture.mode == .position, !connection.cancelled {
                        let base = origin ?? point
                        let destination = CGPoint(x: base.x + value.translation.width, y: base.y + value.translation.height)
                        connection.update(pointer: destination, targets: targets, eligible: eligible)
                        TopologyPerformance.endDrag()
                        if let target = connection.completedTarget(from: endpoint) {
                            store.requestOverlap(from: endpoint, to: target)
                        } else {
                            store.setPosition(endpoint.kind == .project ? "project:" + endpoint.id : endpoint.id, point: destination)
                        }
                    }
                    drag.clear(); connection.clear(); origin = nil; gesture.clear()
                })
            .onChange(of: connection.cancelled) { _, cancelled in
                if cancelled, drag.endpoint == endpoint { drag.clear(); origin = nil }
            }
            .onChange(of: snapshot.active) { _, active in
                if !active, gesture.mode != nil {
                    if connection.source == endpoint { connection.cancel() }
                    if drag.endpoint == endpoint { drag.clear() }
                    origin = nil; gesture.clear()
                }
            }
            .onDisappear {
                if connection.source == endpoint { connection.cancel() }
                if drag.endpoint == endpoint { drag.clear() }
                origin = nil; gesture.clear()
            }
    }

}

private struct TopologyConnectionCue: View {
    let endpoint: LinkEndpoint
    let state: TopologyConnectionDragState
    var body: some View {
        let isSource = state.source == endpoint
        let isTarget = state.target == endpoint
        return RoundedRectangle(cornerRadius: 10)
            .stroke(isTarget ? Palette.blue : (isSource ? Palette.blue.opacity(0.7) : .clear),
                style: StrokeStyle(lineWidth: isTarget ? 2.5 : 1.5, dash: isSource ? [4, 3] : []))
            .background(isTarget ? Palette.selection.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 10))
            .allowsHitTesting(false)
    }
}

/// Cancels the moving item on Escape or loss of app focus without saving a position.
private struct TopologyConnectionCancellation: NSViewRepresentable {
    let state: TopologyConnectionDragState
    func makeCoordinator() -> Coordinator { Coordinator(state: state) }
    func makeNSView(context: Context) -> NSView { context.coordinator.install(); return NSView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) { coordinator.uninstall() }
    @MainActor final class Coordinator {
        let state: TopologyConnectionDragState
        var monitor: Any?
        var focusObserver: NSObjectProtocol?
        init(state: TopologyConnectionDragState) { self.state = state }
        func install() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == 53, let self, self.state.source != nil else { return event }
                self.state.cancel(); return nil
            }
            focusObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.state.cancel() } }
        }
        func uninstall() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) }
            monitor = nil; focusObserver = nil
        }
    }
}

private struct SessionCard: View {
    let store: MaestroStore
    let item: PositionedSession
    let related: Bool
    private let cardWidth: CGFloat = 240
    var body: some View {
        let selected = store.selectedSessionID == item.id
        let linking = store.linkingEndpoint == .session(item.id)
        return VStack(alignment: .leading, spacing: 10) {
            Text(item.session.title).font(.system(size: 12, weight: .medium)).lineLimit(2)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HStack {
                SessionStatePill(session: item.session)
                Spacer(minLength: 2)
                Button { store.beginLink(from: .session(item.id)) } label: { Image(systemName: "link").font(.system(size: 12)).foregroundStyle(linking ? Palette.blue : Palette.muted).frame(width: 24, height: 18) }.buttonStyle(.plain).help("이 세션에서 연결 만들기").accessibilityLabel("\(item.session.title) 연결 만들기")
            }
        }.padding(12).frame(width: cardWidth, height: 112)
            .background(selected ? Palette.selection : Palette.panel, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(selected || linking ? Palette.blue : (related ? Palette.blue.opacity(0.45) : Palette.border), lineWidth: selected || linking ? 1.5 : 1))
            .shadow(color: .black.opacity(selected ? 0.25 : 0.08), radius: 4, y: 2)
            .contentShape(RoundedRectangle(cornerRadius: 11))
            .gesture(TapGesture(count: 2).onEnded { store.openContext(for: .session(item.id)) }
                .exclusively(before: TapGesture().onEnded { store.selectEndpoint(.session(item.id)) }))
            .accessibilityElement(children: .contain).accessibilityLabel(item.session.title)
            .accessibilityAction { store.selectEndpoint(.session(item.id)) }
            .accessibilityAction(named: Text("컨텍스트 열기")) { store.openContext(for: .session(item.id)) }
            .contextMenu { Button("세션 선택") { store.selectEndpoint(.session(item.id)) }; Button("연결 만들기") { store.beginLink(from: .session(item.id)) }; Button("Codex에서 열기") { store.openInCodex(item.session) } }
    }
 }

private struct TopologyEdges: View {
    let groups: [PositionedProject]
    let links: [NodeLink]
    let showLinks: Bool
    let drag: TopologyDragState
    let canvasSize: CGSize
    var body: some View {
        // Offset remains exclusively observed by MovingTopologyEdges.
        let dragged = drag.endpoint
        let nodes = TopologyNodeProjection.nodes(groups: groups)
        let labels = showLinks ? TopologyStaticLabels.make(nodes: nodes, links: links,
            excluding: dragged, size: canvasSize) : [:]
        return ZStack {
            TopologyEdgeRenderer(groups: groups, links: links, nodes: nodes,
                showLinks: showLinks, dragged: dragged, offset: .zero, basePoint: nil, movingOnly: false, staticLabels: labels)
            MovingTopologyEdges(groups: groups, links: links, nodes: nodes,
                showLinks: showLinks, drag: drag, staticLabels: labels)
        }
    }
}

private struct MovingTopologyEdges: View {
    let groups: [PositionedProject]
    let links: [NodeLink]
    let nodes: [LinkEndpoint: TopologyNodeGeometry]
    let showLinks: Bool
    let drag: TopologyDragState
    let staticLabels: [UUID: CGRect]
    var body: some View {
        TopologyEdgeRenderer(groups: groups, links: links, nodes: nodes, showLinks: showLinks,
            dragged: drag.endpoint, offset: drag.offset, basePoint: drag.basePoint,
            movingOnly: true, staticLabels: staticLabels)
    }
}

private enum TopologyStaticLabels {
    static func make(nodes: [LinkEndpoint: TopologyNodeGeometry], links: [NodeLink], excluding: LinkEndpoint?, size: CGSize) -> [UUID: CGRect] {
        let obstacles = nodes.values.map(\.frame)
        var occupied: [CGRect] = []
        var result: [UUID: CGRect] = [:]
        for edge in TopologyNodeProjection.edges(links: links, nodes: nodes) where !edge.touches(excluding) {
            let curve = TopologyLinkGeometry(source: edge.source, target: edge.target)
            if let frame = TopologyLabelPlacement.frame(preferred: curve.midpoint,
                size: TopologyLabelPlacement.size(for: edge.link.kind), obstacles: obstacles,
                occupied: occupied, bounds: CGRect(origin: .zero, size: size)) {
                result[edge.link.id] = frame
                occupied.append(frame)
            }
        }
        return result
    }
}

private struct TopologyEdgeRenderer: View {
    let groups: [PositionedProject]
    let links: [NodeLink]
    let nodes: [LinkEndpoint: TopologyNodeGeometry]
    let showLinks: Bool
    let dragged: LinkEndpoint?
    let offset: CGSize
    let basePoint: CGPoint?
    let movingOnly: Bool
    let staticLabels: [UUID: CGRect]
    private let cardWidth: CGFloat = 240
    private func includes(_ source: LinkEndpoint?, _ target: LinkEndpoint) -> Bool {
        let touchesDrag = dragged != nil && (source == dragged || target == dragged)
        return movingOnly ? touchesDrag : !touchesDrag
    }
    var body: some View {
        Canvas { context, canvasSize in
            let positioned = TopologyNodeProjection.moving(nodes: nodes, dragged: dragged, offset: offset, basePoint: basePoint)
            for group in groups {
                for item in group.items where includes(.project(group.id), .session(item.id)) {
                    guard let position = positioned[.session(item.id)]?.point,
                          let project = positioned[.project(group.id)]?.point else { continue }
                    var path = Path()
                    let from = CGPoint(x: project.x - cardWidth / 2 + 18, y: project.y + 29)
                    let to = CGPoint(x: position.x - cardWidth / 2, y: position.y)
                    let spineX = project.x - cardWidth / 2 - 15
                    path.move(to: from)
                    path.addLine(to: CGPoint(x: spineX, y: from.y))
                    path.addLine(to: CGPoint(x: spineX, y: to.y))
                    path.addLine(to: to)
                    context.stroke(path, with: .color(Palette.branch), style: StrokeStyle(lineWidth: 1))
                }
            }
            if showLinks {
                let edges = TopologyNodeProjection.edges(links: links, nodes: positioned)
                    .filter { movingOnly ? $0.touches(dragged) : !$0.touches(dragged) }
                var occupied = Array(staticLabels.values)
                var labels = staticLabels
                if movingOnly {
                    let obstacles = positioned.values.map(\.frame)
                    for edge in edges {
                        let curve = TopologyLinkGeometry(source: edge.source, target: edge.target)
                        if let frame = TopologyLabelPlacement.frame(preferred: curve.midpoint,
                            size: TopologyLabelPlacement.size(for: edge.link.kind), obstacles: obstacles,
                            occupied: occupied, bounds: CGRect(origin: .zero, size: canvasSize)) {
                            labels[edge.link.id] = frame
                            occupied.append(frame)
                        }
                    }
                }
                for edge in edges {
                    drawLink(context: context, source: edge.source, target: edge.target,
                        color: Palette.link(edge.link.kind), dashed: false,
                        label: edge.link.kind.label, labelFrame: labels[edge.link.id])
                }
                // Ancestry remains distinct from user relations and uses the session namespace.
                for item in groups.flatMap(\.items) {
                    if let parent = item.session.parentID, includes(.session(parent), .session(item.id)),
                       let source = positioned[.session(parent)], let target = positioned[.session(item.id)] {
                        drawLink(context: context, source: source, target: target, color: Palette.muted, dashed: true)
                    }
                }
            }
        }
    }
    private func drawLink(context: GraphicsContext, source: TopologyNodeGeometry, target: TopologyNodeGeometry, color: Color, dashed: Bool, label: String? = nil, labelFrame: CGRect? = nil) {
        let curve = TopologyLinkGeometry(source: source, target: target)
        let from = curve.from, to = curve.to, control1 = curve.control1, control2 = curve.control2
        var path = Path(); path.move(to: from); path.addCurve(to: to, control1: control1, control2: control2)
        context.stroke(path, with: .color(color.opacity(0.65)), style: StrokeStyle(lineWidth: 1.7, dash: dashed ? [4, 5] : []))
        if let label, let frame = labelFrame {
            let center = CGPoint(x: frame.midX, y: frame.midY)
            if hypot(center.x - curve.midpoint.x, center.y - curve.midpoint.y) > 18 {
                var leader = Path(); leader.move(to: curve.midpoint); leader.addLine(to: center)
                context.stroke(leader, with: .color(color.opacity(0.4)), style: StrokeStyle(lineWidth: 0.8, dash: [1, 3]))
            }
            let text = context.resolve(Text(label).font(.system(size: 10)).foregroundColor(color))
            context.fill(Path(roundedRect: frame, cornerRadius: 4), with: .color(Palette.canvas))
            context.draw(text, at: center)
        }
        let angle = atan2(to.y - control2.y, to.x - control2.x)
        var arrow = Path(); arrow.move(to: to)
        arrow.addLine(to: CGPoint(x: to.x - 7 * cos(angle - 0.5), y: to.y - 7 * sin(angle - 0.5)))
        arrow.addLine(to: CGPoint(x: to.x - 7 * cos(angle + 0.5), y: to.y - 7 * sin(angle + 0.5))); arrow.closeSubpath()
        context.fill(arrow, with: .color(color))
    }
}

struct TopologyNodeGeometry {
    let endpoint: LinkEndpoint
    let point: CGPoint
    var height: CGFloat { endpoint.kind == .project ? 58 : 112 }
    var frame: CGRect { CGRect(x: point.x - 120, y: point.y - height / 2, width: 240, height: height) }
    func isConnectionControl(at location: CGPoint) -> Bool {
        frame.contains(location) && location.x >= frame.maxX - 44
            && (endpoint.kind == .project || location.y >= frame.maxY - 40)
    }
}

struct TopologyProjectedLink {
    let link: NodeLink
    let source: TopologyNodeGeometry
    let target: TopologyNodeGeometry
    func touches(_ endpoint: LinkEndpoint?) -> Bool {
        guard let endpoint else { return false }
        return link.source == endpoint || link.target == endpoint
    }
}

enum TopologyNodeProjection {
    fileprivate static func nodes(groups: [PositionedProject]) -> [LinkEndpoint: TopologyNodeGeometry] {
        var result: [LinkEndpoint: TopologyNodeGeometry] = [:]
        for group in groups {
            let project = LinkEndpoint.project(group.id)
            result[project] = TopologyNodeGeometry(endpoint: project, point: group.point)
            for item in group.items {
                let session = LinkEndpoint.session(item.id)
                result[session] = TopologyNodeGeometry(endpoint: session, point: item.point)
            }
        }
        return result
    }
    static func edges(links: [NodeLink], nodes: [LinkEndpoint: TopologyNodeGeometry]) -> [TopologyProjectedLink] {
        links.compactMap { link in
            guard let source = nodes[link.source], let target = nodes[link.target] else { return nil }
            return TopologyProjectedLink(link: link, source: source, target: target)
        }
    }
    static func moving(nodes: [LinkEndpoint: TopologyNodeGeometry], dragged: LinkEndpoint?, offset: CGSize, basePoint: CGPoint?) -> [LinkEndpoint: TopologyNodeGeometry] {
        guard let dragged, let node = nodes[dragged] else { return nodes }
        let base = basePoint ?? node.point
        var result = nodes
        result[dragged] = TopologyNodeGeometry(endpoint: dragged,
            point: CGPoint(x: base.x + offset.width, y: base.y + offset.height))
        return result
    }
}

/// Canonical curve geometry shared by rendering and collision-aware label placement.
struct TopologyLinkGeometry {
    static let longRowClearance: CGFloat = 18
    let from: CGPoint
    let to: CGPoint
    let control1: CGPoint
    let control2: CGPoint
    var midpoint: CGPoint {
        CGPoint(x: (from.x + 3 * control1.x + 3 * control2.x + to.x) / 8,
            y: (from.y + 3 * control1.y + 3 * control2.y + to.y) / 8)
    }
    init(source: TopologyNodeGeometry, target: TopologyNodeGeometry) {
        self.init(a: source.point, b: target.point, sourceHeight: source.height, targetHeight: target.height)
    }
    init(a: CGPoint, b: CGPoint, cardWidth: CGFloat = 240, sourceHeight: CGFloat = 112, targetHeight: CGFloat = 112, columnSpacing: CGFloat = 285) {
        let sameColumn = abs(a.x - b.x) < 60
        if abs(a.x - b.x) > columnSpacing * 1.5, abs(a.y - b.y) <= Self.longRowClearance {
            // A long side-to-side line would traverse the intervening row card.
            // Top-center anchors and a shallow corridor also avoid project headers
            // directly above session cards in the default layout. Retain this route
            // for small vertical placement adjustments within the corridor clearance.
            from = CGPoint(x: a.x, y: a.y - sourceHeight / 2)
            to = CGPoint(x: b.x, y: b.y - targetHeight / 2)
            let corridor = min(from.y, to.y) - Self.longRowClearance
            control1 = CGPoint(x: from.x, y: corridor)
            control2 = CGPoint(x: to.x, y: corridor)
            return
        }
        // Use the outside side curve for every same-column relation, including mixed
        // kinds. A center-column vertical curve can cross intervening session bodies.
        from = sameColumn ? CGPoint(x: a.x + cardWidth / 2, y: a.y + min(20, sourceHeight / 2 - 8))
            : CGPoint(x: a.x + (b.x > a.x ? cardWidth / 2 : -cardWidth / 2), y: a.y)
        to = sameColumn ? CGPoint(x: b.x + cardWidth / 2, y: b.y - min(20, targetHeight / 2 - 8))
            : CGPoint(x: b.x + (b.x > a.x ? -cardWidth / 2 : cardWidth / 2), y: b.y)
        let bend: CGFloat = sameColumn ? 42 : abs(to.x - from.x) * 0.55
        control1 = CGPoint(x: from.x + (sameColumn || b.x > a.x ? bend : -bend), y: from.y)
        control2 = CGPoint(x: to.x + (sameColumn || b.x < a.x ? bend : -bend), y: to.y)
    }
}

/// A bounded search never places a label over a card or previously reserved label.
enum TopologyLabelPlacement {
    static func size(for kind: LinkKind) -> CGSize {
        let measured = (kind.label as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 10)])
        return CGSize(width: ceil(measured.width) + 10, height: ceil(measured.height) + 6)
    }
    static func frame(preferred: CGPoint, size: CGSize, obstacles: [CGRect], occupied: [CGRect], bounds: CGRect) -> CGRect? {
        let clearance: CGFloat = 2
        let radius: CGFloat = 240
        // Candidate centers are bounded, but each label extends beyond its center.
        // Include every obstacle that can touch the full frame plus clearance.
        let search = CGRect(x: preferred.x - radius, y: preferred.y - radius, width: radius * 2, height: radius * 2)
            .insetBy(dx: -size.width / 2 - clearance, dy: -size.height / 2 - clearance)
        let nearby = (obstacles + occupied).filter { $0.intersects(search) }.map { $0.insetBy(dx: -clearance, dy: -clearance) }
        var candidates = [preferred]
        // Card boundaries give exact candidates even in a narrow inter-row gap.
        for rect in nearby {
            candidates.append(CGPoint(x: preferred.x, y: rect.minY - size.height / 2 - 0.5))
            candidates.append(CGPoint(x: preferred.x, y: rect.maxY + size.height / 2 + 0.5))
            candidates.append(CGPoint(x: rect.minX - size.width / 2 - 0.5, y: preferred.y))
            candidates.append(CGPoint(x: rect.maxX + size.width / 2 + 0.5, y: preferred.y))
        }
        for ring in 1...12 {
            let distance = CGFloat(ring) * 18
            for dx in -1...1 {
                for dy in -1...1 where dx != 0 || dy != 0 {
                    candidates.append(CGPoint(x: preferred.x + CGFloat(dx) * distance, y: preferred.y + CGFloat(dy) * distance))
                }
            }
        }
        func distance(_ point: CGPoint) -> CGFloat { hypot(point.x - preferred.x, point.y - preferred.y) }
        candidates.sort {
            let a = distance($0), b = distance($1)
            if a != b { return a < b }
            if $0.y != $1.y { return $0.y < $1.y }
            return $0.x < $1.x
        }
        for center in candidates where distance(center) <= radius {
            let frame = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
            if bounds.contains(frame), !nearby.contains(where: { $0.intersects(frame) }) { return frame }
        }
        return nil
    }
}

private enum TopologyGrid {
    private static let light = makeImage(dark: false)
    private static let dark = makeImage(dark: true)
    static func image(dark: Bool) -> Image { dark ? Self.dark : light }
    private static func makeImage(dark: Bool) -> Image {
        let tile = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            appearance?.performAsCurrentDrawingAppearance {
                NSColor(Palette.grid).setFill()
                NSBezierPath(ovalIn: NSRect(x: 8.4, y: 8.4, width: 1.2, height: 1.2)).fill()
            }
            return true
        }
        return Image(nsImage: tile)
    }
}

/// Direct user-defined relations highlight neighboring nodes, without filtering the graph.
enum TopologyRelatedNodes {
    static func endpoints(selected: LinkEndpoint?, links: [NodeLink]) -> Set<LinkEndpoint> {
        guard let selected else { return [] }
        return Set(links.compactMap { $0.source == selected ? $0.target : ($0.target == selected ? $0.source : nil) })
    }
}

// Opt-in diagnostics, containing counters only (no session titles or prompt content).
@MainActor private enum TopologyPerformance {
    static var layoutPasses = 0
    static var dragUpdates = 0
    private static var initialPasses = 0
    static func beginDrag() { initialPasses = layoutPasses; dragUpdates = 0 }
    static func endDrag() {
        guard ProcessInfo.processInfo.environment["MAESTRO_PERFORMANCE_LOG"] == "1" else { return }
        print("Maestro drag: updates=\(dragUpdates) layoutPasses=\(layoutPasses - initialPasses)")
        fflush(stdout)
    }
}
