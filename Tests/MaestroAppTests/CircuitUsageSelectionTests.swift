import XCTest
import MaestroCore
@testable import CodexMaestro

final class CircuitUsageSelectionTests:XCTestCase {
    func testHistoricalTurnDoesNotShowLaterOrUndatedSessionMetrics() {
        let start=Date(timeIntervalSince1970:100),end=Date(timeIntervalSince1970:200)
        let turn=WorkTurn(id:"t",sessionID:"s",startedAt:start,endedAt:end)
        let graph=SessionWorkTopology(sessionID:"s",title:"S",usage:[
            WorkUsage(sessionID:"s",input:10,output:3,timestamp:start,scope:"세션 누적 · 세대 0 · 구간 0"),
            WorkUsage(sessionID:"s",input:100,output:30,timestamp:Date(timeIntervalSince1970:300),scope:"세션 누적 · 세대 0 · 구간 0"),
            WorkUsage(sessionID:"s",input:999,output:99,scope:"세션 누적 · 세대 0 · 구간 0")
        ])
        XCTAssertEqual(CircuitUsageSelection.main(in:graph,turn:turn,cutoff:nil)?.input,10)
        XCTAssertNil(CircuitUsageSelection.main(in:graph,turn:turn,cutoff:Date(timeIntervalSince1970:90)))
    }
    func testCachedAndReasoningTokensAreSubsetsAndChildOverlapMustBeKnown() {
        func sample(_ id:String,_ includes:Bool?)->WorkUsage {
            WorkUsage(sessionID:id,input:100,cachedInput:80,output:20,reasoningOutput:5,scope:"명시된 turn 계측",includesSubsessions:includes)
        }
        let sum=CircuitUsageSelection.addingIndependent([sample("parent",false),sample("child",false)])
        XCTAssertEqual(sum?.input,200);XCTAssertEqual(sum?.output,40);XCTAssertEqual(sum?.cached,160);XCTAssertEqual(sum?.reasoning,10)
        XCTAssertNil(CircuitUsageSelection.addingIndependent([sample("parent",nil),sample("child",false)]))
        XCTAssertNil(CircuitUsageSelection.addingIndependent([sample("parent",true),sample("child",false)]))
        XCTAssertNil(CircuitUsageSelection.addingIndependent([sample("parent",false),sample("parent",false)]))
    }
    func testUnknownChildMetricAndOverflowCannotBecomeZeroTotal() {
        let a=WorkUsage(sessionID:"a",input:Int64.max,output:1,scope:"turn",includesSubsessions:false)
        let b=WorkUsage(sessionID:"b",input:1,output:1,scope:"turn",includesSubsessions:false)
        XCTAssertNil(CircuitUsageSelection.addingIndependent([a,b]))
        let unknown=WorkUsage(sessionID:"b",input:1,scope:"turn",includesSubsessions:false)
        XCTAssertNil(CircuitUsageSelection.addingIndependent([a,unknown]))
    }

    func testMissingChildSubsetsRemainUnknownWithinKnownInputOutputSum() {
        let a=WorkUsage(sessionID:"a",input:100,cachedInput:80,output:20,reasoningOutput:5,scope:"turn",includesSubsessions:false)
        let b=WorkUsage(sessionID:"b",input:100,output:20,scope:"turn",includesSubsessions:false)
        let sum=CircuitUsageSelection.addingIndependent([a,b])
        XCTAssertEqual(sum?.input,200);XCTAssertEqual(sum?.output,40)
        XCTAssertNil(sum?.cached);XCTAssertNil(sum?.reasoning)
    }

    func testRecentRequestRatioIsSeparateFromTurnTotals() {
        let t=WorkTurn(id:"t",sessionID:"s")
        let graph=SessionWorkTopology(sessionID:"s",title:"S",usage:[
            WorkUsage(sessionID:"s",turnID:"t",lastRequestInput:30,modelContextWindow:100,scope:"마지막 요청 · turn 합계 아님"),
            WorkUsage(sessionID:"s",turnID:"t",input:400,output:50,scope:"명시된 turn 계측"),
            WorkUsage(sessionID:"s",turnID:"t",input:450,output:55,scope:"명시된 turn 누적 · 직접 turn_token_usage · 구간 0"),
            WorkUsage(sessionID:"s",input:5000,output:500,scope:"세션 누적 · 직접 thread_token_usage")
        ])
        XCTAssertEqual(CircuitUsageSelection.main(in:graph,turn:t,cutoff:nil)?.input,450)
        XCTAssertEqual(CircuitUsageSelection.lastRequest(in:graph,turn:t,cutoff:nil)?.lastRequestRatio,0.3)
    }

    func testForeignOwnerCountersDoNotReplaceMainSessionMetrics() {
        let graph=SessionWorkTopology(sessionID:"parent",title:"Parent",usage:[
            WorkUsage(sessionID:"parent",input:100,output:20,lastRequestInput:10,modelContextWindow:100,scope:"세션 누적"),
            WorkUsage(sessionID:"child",input:900,output:90,lastRequestInput:90,modelContextWindow:100,scope:"세션 누적")
        ])
        XCTAssertEqual(CircuitUsageSelection.main(in:graph,turn:nil,cutoff:nil)?.input,100)
        XCTAssertEqual(CircuitUsageSelection.lastRequest(in:graph,turn:nil,cutoff:nil)?.lastRequestRatio,0.1)
    }
}
