import XCTest
import MaestroCore
@testable import CodexMaestro

final class SessionWorkLayoutTests: XCTestCase {
    func testAllGroupMembersAndEdgesRemainAccessible() {
        let nodes = (0..<9).map { WorkNode(id:"call-\($0)",sessionID:"s",turnID:"t",kind:.command,title:"Call \($0)",status:.ended) }
        let main = WorkNode(id:"main",sessionID:"s",turnID:"t",kind:.session,title:"Main",status:.running)
        let edges = nodes.map { WorkRelation(source:main.id,target:$0.id,kind:.calls) }
        let projection = CircuitProjection(nodes:[main]+nodes,edges:edges)
        XCTAssertEqual(projection.items.count,2)
        XCTAssertEqual(projection.items.flatMap(\.members).map(\.id).sorted(),([main]+nodes).map(\.id).sorted())
        XCTAssertEqual(projection.wires.first?.relations.count,9)
        let expanded = CircuitProjection(nodes:[main]+nodes,edges:edges,expanded:[CircuitProjection.groupID(nodes[0])])
        XCTAssertEqual(expanded.items.count,10)
        XCTAssertEqual(expanded.wires.count,9)
    }

    func testRoutingAvoidsEveryUnrelatedNodeAtActualPanelWidths() {
        let kinds: [WorkNodeKind] = [.instruction,.prompt,.command,.toolResult,.compaction,.session,.mcp,.verification,.usage,.waiting,.subsession,.message,.other,.artifact]
        let nodes = kinds.enumerated().map { WorkNode(id:"n\($0)",sessionID:"s",turnID:"t",kind:$0.element,title:$0.element.label,status:.running) }
        let relations = (1..<nodes.count).map { WorkRelation(source:nodes[5].id,target:nodes[$0].id,kind:.calls) }.filter { $0.source != $0.target }
        let projection = CircuitProjection(nodes:nodes,edges:relations)
        for width: CGFloat in [360,560,740,780,940,1200] {
            let layout = CircuitLayout(items:projection.items,width:width)
            let routes = CircuitRouting.routes(projection.wires,layout:layout)
            XCTAssertEqual(routes.count,projection.wires.count,"Unrouted connection at \(width)")
            for route in routes {
                for (id,rect) in layout.frames where id != route.wire.source && id != route.wire.target {
                    for (a,b) in zip(route.points,route.points.dropFirst()) {
                        XCTAssertFalse(CircuitRouting.intersects(a,b,rect:rect),"\(route.id) crosses \(id) at \(width)")
                    }
                }
            }
            for rect in layout.frames.values { XCTAssertGreaterThanOrEqual(rect.minX,0);XCTAssertLessThanOrEqual(rect.maxX,width) }
        }
    }

    func testFailedAndPendingExecutionsDoNotDisappearIntoCompletedGroup() {
        var nodes = (0..<5).map { WorkNode(id:"\($0)",sessionID:"s",kind:.command,title:"Call",status:.ended) }
        nodes += [WorkNode(id:"failed",sessionID:"s",kind:.command,title:"Failure",status:.failed),WorkNode(id:"waiting",sessionID:"s",kind:.command,title:"Pending",status:.waiting)]
        let projection = CircuitProjection(nodes:nodes,edges:[])
        XCTAssertEqual(projection.items.count,3)
        XCTAssertEqual(projection.membership["failed"],"failed")
        XCTAssertEqual(projection.membership["waiting"],"waiting")
    }

    func testLargeExpandedGroupPagesWithoutLosingConstituents() {
        let nodes = (0..<1000).map { WorkNode(id:"\($0)",sessionID:"s",turnID:"t",kind:.command,title:"Call",status:.ended) }
        let id = CircuitProjection.groupID(nodes[0])
        for page in [0,1,41,100] {
            let projection = CircuitProjection(nodes:nodes,edges:[],expanded:[id],groupPages:[id:page])
            XCTAssertLessThanOrEqual(projection.items.count,25)
            XCTAssertEqual(projection.membership.count,1000)
            XCTAssertEqual(Set(projection.items.flatMap(\.members).map(\.id)),Set(nodes.map(\.id)))
        }
    }

    func testEveryLifecycleObservationHasItsOwnSelectableRow() {
        let first=Date(timeIntervalSince1970:100),last=first.addingTimeInterval(5)
        let node=WorkNode(id:"call",sessionID:"s",turnID:"t",kind:.command,title:"Command",status:.succeeded,
            timestamp:first,statusHistory:[
                WorkStatusObservation(timestamp:first,status:.running,recordOrdinal:1,summary:"started",bodyPreview:"start body"),
                WorkStatusObservation(timestamp:last,status:.succeeded,recordOrdinal:4,summary:"returned",bodyPreview:"result body")
            ])
        let rows=CircuitEventRow.rows(nodes:[node],cutoff:nil)
        XCTAssertEqual(rows.count,2)
        XCTAssertEqual(Set(rows.map(\.id)).count,2)
        XCTAssertEqual(rows.map(\.observationIndex),[0,1])
        XCTAssertEqual(rows.map(\.node.bodyPreview),["start body","result body"])
        XCTAssertEqual(rows.map(\.node.status),[.running,.succeeded])
        XCTAssertEqual(CircuitEventRow.rows(nodes:[node],cutoff:first).count,1)
    }

    func testReceivingTurnTimelineIncludesRepeatedReceiptsWithoutEarlierOrLaterTurns() {
        let date=Date(timeIntervalSince1970:100)
        let root=WorkNode(id:"turn:s:b",sessionID:"s",turnID:"b",kind:.session,title:"B",timestamp:date.addingTimeInterval(10))
        let result=WorkNode(id:"r",sessionID:"s",turnID:"a",kind:.toolResult,title:"Result",timestamp:date,statusHistory:[
            WorkStatusObservation(timestamp:date,status:.succeeded),
            WorkStatusObservation(timestamp:date.addingTimeInterval(11),status:.succeeded),
            WorkStatusObservation(timestamp:date.addingTimeInterval(12),status:.failed),
            WorkStatusObservation(timestamp:date.addingTimeInterval(30),status:.succeeded)
        ])
        let edge=WorkRelation(source:"r",target:root.id,kind:.receivedInTurn,observedAt:date.addingTimeInterval(11))
        let graph=SessionWorkTopology(sessionID:"s",title:"S",nodes:[root,result],edges:[edge],
            turns:[WorkTurn(id:"b",sessionID:"s",startedAt:date.addingTimeInterval(10),endedAt:date.addingTimeInterval(20))])
        XCTAssertEqual(CircuitEventTimeline.dates(graph:graph,turnID:"b"),[10,11,12].map { date.addingTimeInterval(Double($0)) })
    }

    func testStatusSelectionAndTelemetryDoNotChangeRoutingGeometry() {
        var nodes=[WorkNode(id:"s",sessionID:"s",kind:.session,title:"Main",status:.running),
                   WorkNode(id:"c",sessionID:"s",kind:.command,title:"Command",status:.running)]
        let edges=[WorkRelation(source:"s",target:"c",kind:.calls)]
        let first=CircuitProjection(nodes:nodes,edges:edges)
        let original=CircuitRouteKey(layout:CircuitLayout(items:first.items,width:940),wires:first.wires)
        nodes[1].status = .succeeded;nodes[1].summary="new result"
        let second=CircuitProjection(nodes:nodes,edges:edges)
        XCTAssertEqual(original,CircuitRouteKey(layout:CircuitLayout(items:second.items,width:940),wires:second.wires))
        XCTAssertNotEqual(original,CircuitRouteKey(layout:CircuitLayout(items:second.items,width:560),wires:second.wires))
    }

    func testLargeCircuitRetainsAllRelationsAndMeasuresProjectionRouting() {
        let main=WorkNode(id:"main",sessionID:"s",turnID:"t",kind:.session,title:"Main",status:.running)
        let calls=(0..<1000).map { WorkNode(id:"c\($0)",sessionID:"s",turnID:"t",kind:.command,title:"Call",status:.ended) }
        let edges=calls.map { WorkRelation(source:main.id,target:$0.id,kind:.calls) }
        let start=Date()
        let collapsed=CircuitProjection(nodes:[main]+calls,edges:edges)
        let collapsedRoutes=CircuitRouting.routes(collapsed.wires,layout:CircuitLayout(items:collapsed.items,width:940))
        let collapsedSeconds=Date().timeIntervalSince(start)
        let expandedStart=Date()
        let expanded=CircuitProjection(nodes:[main]+calls,edges:edges,expanded:[CircuitProjection.groupID(calls[0])])
        let routes=CircuitRouting.routes(expanded.wires,layout:CircuitLayout(items:expanded.items,width:940))
        let expandedSeconds=Date().timeIntervalSince(expandedStart)
        XCTAssertEqual(collapsed.wires.flatMap(\.relations).count,1000)
        XCTAssertEqual(expanded.wires.flatMap(\.relations).count,1000)
        XCTAssertEqual(collapsedRoutes.count,collapsed.wires.count)
        XCTAssertEqual(routes.count,expanded.wires.count)
        XCTAssertLessThanOrEqual(expanded.items.count,26)
        print("SESSION_CIRCUIT_GEOMETRY nodes=1001 relations=1000 collapsed_seconds=\(collapsedSeconds) expanded_page_seconds=\(expandedSeconds) expanded_visible=\(expanded.items.count) routed=\(routes.count) scope=projection_layout_routing_not_render_fps")
    }
}
