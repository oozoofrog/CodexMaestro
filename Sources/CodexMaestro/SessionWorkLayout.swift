import Foundation
import CoreGraphics
import MaestroCore

struct CircuitItem: Identifiable {
    let id: String
    let members: [WorkNode]
    var node: WorkNode { members[0] }
    var isGroup: Bool { id != node.id }
    var title: String { isGroup ? "\(node.kind.label) · \(members.count)개" : node.title }
}

struct CircuitWire: Identifiable {
    let id: String
    let source: String
    let target: String
    let relations: [WorkRelation]
    var kind: WorkRelationKind { relations[0].kind }
}

/// A display group retains every constituent ID. The event list remains exhaustive.
struct CircuitProjection {
    let items: [CircuitItem]
    let wires: [CircuitWire]
    let membership: [String: String]
    init(nodes: [WorkNode], edges: [WorkRelation], expanded: Set<String> = [], groupPages: [String: Int] = [:]) {
        let eligible = nodes.filter {
            ![.session, .prompt, .subsession, .waiting].contains($0.kind) &&
            ![.running, .waiting, .queued, .failed].contains($0.status)
        }
        let eligibleIDs = Set(eligible.map(\.id))
        let grouped = Dictionary(grouping: eligible, by: { Self.groupID($0) })
        var membership: [String: String] = [:]
        var items: [CircuitItem] = []
        var emitted: Set<String> = []
        var visibleMembers: [String: Set<String>] = [:]
        var remainingMembers: [String: [WorkNode]] = [:]
        for (id, members) in grouped where members.count > 3 {
            if expanded.contains(id) {
                let lastPage = (members.count - 1) / 24
                let page = max(0, min(lastPage, groupPages[id] ?? 0))
                let shown = Set(members.dropFirst(page * 24).prefix(24).map(\.id))
                visibleMembers[id] = shown
                remainingMembers[id] = members.filter { !shown.contains($0.id) }
            } else { remainingMembers[id] = members }
        }
        for node in nodes {
            let groupID = Self.groupID(node)
            if let members = grouped[groupID], members.count > 3,
               eligibleIDs.contains(node.id),
               !(visibleMembers[groupID]?.contains(node.id) ?? false),
               let remainder = remainingMembers[groupID], !remainder.isEmpty {
                membership[node.id] = groupID
                if emitted.insert(groupID).inserted { items.append(CircuitItem(id: groupID, members: remainder)) }
            } else {
                membership[node.id] = node.id
                items.append(CircuitItem(id: node.id, members: [node]))
            }
        }
        self.items = items
        self.membership = membership
        var wireIDs: [String] = []
        var relations: [String: [WorkRelation]] = [:]
        var ends: [String: (String, String)] = [:]
        for edge in edges where edge.kind != .recordedNext {
            guard let source = membership[edge.source], let target = membership[edge.target], source != target else { continue }
            let id = source + "|" + edge.kind.rawValue + "|" + target
            if relations[id] == nil { wireIDs.append(id); ends[id] = (source, target) }
            relations[id, default: []].append(edge)
        }
        wires = wireIDs.compactMap { id in
            guard let ends = ends[id], let rows = relations[id] else { return nil }
            return CircuitWire(id: id, source: ends.0, target: ends.1, relations: rows)
        }
    }
    static func groupID(_ node: WorkNode) -> String {
        "circuit-group:" + node.sessionID + ":" + (node.turnID ?? "unassigned") + ":" + node.kind.rawValue
    }
}

struct CircuitLayout {
    let frames: [String: CGRect]
    let size: CGSize
    let columns: Int
    init(items: [CircuitItem], width: CGFloat) {
        let width = max(360, width)
        columns = width >= 780 ? 4 : 2
        let padding: CGFloat = 24, gap: CGFloat = 40, cardHeight: CGFloat = 116, rowGap: CGFloat = 42
        let cardWidth = (width - 2 * padding - CGFloat(columns - 1) * gap) / CGFloat(columns)
        var rows = Array(repeating: 0, count: columns)
        var frames: [String: CGRect] = [:]
        let sorted = items.sorted { a, b in
            let rank: (CircuitItem) -> Int = { item in
                switch item.node.kind { case .prompt: 0; case .session: 1; default: 2 }
            }
            if rank(a) != rank(b) { return rank(a) < rank(b) }
            if a.node.timestamp != b.node.timestamp { return (a.node.timestamp ?? .distantPast) < (b.node.timestamp ?? .distantPast) }
            return a.id < b.id
        }
        for item in sorted {
            let lane = columns == 4 ? item.node.kind.lane : (item.node.kind.lane < 2 ? 0 : 1)
            frames[item.id] = CGRect(x: padding + CGFloat(lane) * (cardWidth + gap),
                                    y: 48 + CGFloat(rows[lane]) * (cardHeight + rowGap), width: cardWidth, height: cardHeight)
            rows[lane] += 1
        }
        self.frames = frames
        size = CGSize(width: width, height: max(320, 48 + CGFloat(rows.max() ?? 0) * (cardHeight + rowGap)))
    }
}

struct CircuitRoute: Identifiable {
    let id: String
    let wire: CircuitWire
    let points: [CGPoint]
}

/// Status, selection, and telemetry updates do not invalidate connection geometry.
struct CircuitRouteKey: Equatable {
    let frames:[String:CGRect]
    let size:CGSize
    let wireIDs:[String]
    init(layout:CircuitLayout,wires:[CircuitWire]) {
        frames=layout.frames;size=layout.size;wireIDs=wires.map(\.id)
    }
}

struct CircuitEventRow: Identifiable {
    let node:WorkNode
    let observationIndex:Int
    let recordOrdinal:Int?
    var id:String { node.id + ":observation:" + String(observationIndex) }
    static func rows(nodes:[WorkNode],cutoff:Date?) -> [Self] {
        nodes.filter { $0.kind != .session }.flatMap { original in
            original.statusHistory.enumerated().compactMap { index,observation -> Self? in
                if let cutoff { guard let date=observation.timestamp,date <= cutoff else { return nil } }
                var node=original
                node.timestamp=observation.timestamp;node.status=observation.status
                node.summary=observation.summary ?? "상태 관찰: \(observation.status.label)"
                node.bodyPreview=observation.bodyPreview ?? "이 관찰의 원문 미확인"
                node.bodyReference=observation.bodyReference
                if let ref=node.bodyReference { node.source="\(ref.path) · byte \(ref.offset)" }
                return Self(node:node,observationIndex:index,recordOrdinal:observation.recordOrdinal)
            }
        }.sorted {
            if $0.node.timestamp != $1.node.timestamp { return ($0.node.timestamp ?? .distantPast) < ($1.node.timestamp ?? .distantPast) }
            if $0.recordOrdinal != $1.recordOrdinal { return ($0.recordOrdinal ?? 0) < ($1.recordOrdinal ?? 0) }
            return $0.id < $1.id
        }
    }
}

enum CircuitEventTimeline {
    static func dates(graph:SessionWorkTopology,turnID:String?) -> [Date] {
        var dates=graph.nodes.filter { $0.turnID == turnID }
            .flatMap { $0.statusHistory.compactMap(\.timestamp)+[$0.timestamp].compactMap { $0 } }
        guard let turnID else { return Array(Set(dates)).sorted() }
        let root="turn:\(graph.sessionID):\(turnID)"
        let end=graph.turns.first { $0.id==turnID }?.endedAt
        let nodes=Dictionary(graph.nodes.map { ($0.id,$0) },uniquingKeysWith:{ _,last in last })
        for edge in graph.edges where edge.kind == .receivedInTurn && edge.target == root {
            guard let received=edge.observedAt else { continue }
            dates.append(received)
            if let node=nodes[edge.source] {
                dates += node.statusHistory.compactMap(\.timestamp).filter { date in date >= received && (end.map { date <= $0 } ?? true) }
            }
        }
        return Array(Set(dates)).sorted()
    }
}

enum CircuitRouting {
    /// Routes on a rectilinear visibility grid outside padded node rectangles.
    static func routes(_ wires: [CircuitWire], layout: CircuitLayout) -> [CircuitRoute] {
        let obstacles = Array(layout.frames.values)
        return wires.compactMap { wire in
            guard let source = layout.frames[wire.source], let target = layout.frames[wire.target],
                  let points = route(from: source, to: target, obstacles: obstacles, bounds: layout.size) else { return nil }
            return CircuitRoute(id: wire.id, wire: wire, points: points)
        }
    }

    static func route(from source: CGRect, to target: CGRect, obstacles: [CGRect], bounds: CGSize) -> [CGPoint]? {
        let start: CGPoint, end: CGPoint, outerStart: CGPoint, outerEnd: CGPoint
        if abs(source.midX - target.midX) < 1 {
            let down = source.midY < target.midY
            start = CGPoint(x: source.midX, y: down ? source.maxY : source.minY)
            end = CGPoint(x: target.midX, y: down ? target.minY : target.maxY)
            outerStart = CGPoint(x: start.x, y: start.y + (down ? 14 : -14))
            outerEnd = CGPoint(x: end.x, y: end.y + (down ? -14 : 14))
        } else {
            let right = source.midX < target.midX
            start = CGPoint(x: right ? source.maxX : source.minX, y: source.midY)
            end = CGPoint(x: right ? target.minX : target.maxX, y: target.midY)
            outerStart = CGPoint(x: start.x + (right ? 14 : -14), y: start.y)
            outerEnd = CGPoint(x: end.x + (right ? -14 : 14), y: end.y)
        }
        let padded = obstacles.map { $0.insetBy(dx: -8, dy: -8) }
        var xs: Set<CGFloat> = [12, bounds.width - 12, outerStart.x, outerEnd.x]
        var ys: Set<CGFloat> = [26, bounds.height - 12, outerStart.y, outerEnd.y]
        for rect in obstacles {
            xs.formUnion([rect.minX - 14, rect.maxX + 14])
            ys.formUnion([rect.minY - 14, rect.maxY + 14])
        }
        let x = xs.filter { $0 >= 0 && $0 <= bounds.width }.sorted()
        let y = ys.filter { $0 >= 0 && $0 <= bounds.height }.sorted()
        guard let sx = x.firstIndex(of: outerStart.x), let sy = y.firstIndex(of: outerStart.y),
              let ex = x.firstIndex(of: outerEnd.x), let ey = y.firstIndex(of: outerEnd.y) else { return nil }
        let startIndex = sy * x.count + sx, endIndex = ey * x.count + ex
        var queue = [startIndex], head = 0, parent: [Int: Int] = [startIndex: -1]
        while head < queue.count {
            let index = queue[head]; head += 1
            if index == endIndex { break }
            let ix = index % x.count, iy = index / x.count
            for (nx, ny) in [(ix+1,iy),(ix-1,iy),(ix,iy+1),(ix,iy-1)] {
                guard nx >= 0, nx < x.count, ny >= 0, ny < y.count else { continue }
                let next = ny * x.count + nx
                guard parent[next] == nil else { continue }
                let a = CGPoint(x: x[ix], y: y[iy]), b = CGPoint(x: x[nx], y: y[ny])
                guard !padded.contains(where: { intersects(a, b, rect: $0) }) else { continue }
                parent[next] = index; queue.append(next)
            }
        }
        guard parent[endIndex] != nil else { return nil }
        var middle: [CGPoint] = [], index = endIndex
        while index >= 0 {
            middle.append(CGPoint(x: x[index % x.count], y: y[index / x.count]))
            index = parent[index] ?? -1
        }
        let all = [start] + middle.reversed() + [end]
        var result: [CGPoint] = []
        for point in all {
            if result.last == point { continue }
            if result.count >= 2 {
                let a = result[result.count-2], b = result[result.count-1]
                if (a.x == b.x && b.x == point.x) || (a.y == b.y && b.y == point.y) { result.removeLast() }
            }
            result.append(point)
        }
        return result
    }

    static func intersects(_ a: CGPoint, _ b: CGPoint, rect: CGRect) -> Bool {
        if a.x == b.x { return a.x > rect.minX && a.x < rect.maxX && max(a.y,b.y) > rect.minY && min(a.y,b.y) < rect.maxY }
        if a.y == b.y { return a.y > rect.minY && a.y < rect.maxY && max(a.x,b.x) > rect.minX && min(a.x,b.x) < rect.maxX }
        return true
    }

    static func point(along points: [CGPoint], fraction: Double) -> CGPoint? {
        guard let first = points.first else { return nil }
        let lengths = zip(points,points.dropFirst()).map { hypot($1.x-$0.x,$1.y-$0.y) }
        var distance = lengths.reduce(0,+) * CGFloat(max(0,min(1,fraction)))
        for (index,length) in lengths.enumerated() {
            if distance <= length, length > 0 {
                let a = points[index], b = points[index+1], t = distance / length
                return CGPoint(x: a.x+(b.x-a.x)*t, y: a.y+(b.y-a.y)*t)
            }
            distance -= length
        }
        return points.last ?? first
    }
}
