// Link with freshly built MaestroCore objects and module. Reads local catalog/rollout only.
// No IPC requests, credential access, prompts, or workspace writes.
import Foundation
import Darwin
import MaestroCore

@main struct SessionCircuitProbe {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else {
            print("Usage: probe SESSION_ID");exit(2)
        }
        let id=CommandLine.arguments[1]
        let catalog=try CodexCatalog().read(includeArchived:true,includeMessagePreviews:false)
        guard let session=catalog.sessions.first(where:{ $0.id==id }) else {
            throw MaestroError.message("선택한 세션이 카탈로그에 없습니다.")
        }
        let loader=SessionWorkTopologyLoader(home:CodexCatalog().home)
        let coldStart=Date()
        let graph=try await loader.load(session:session,catalog:catalog.sessions)
        let coldSeconds=Date().timeIntervalSince(coldStart)
        let first=await loader.diagnostics(sessionID:id)
        let warmStart=Date()
        _ = try await loader.load(session:session,catalog:catalog.sessions)
        let warmSeconds=Date().timeIntervalSince(warmStart)
        let warm=await loader.diagnostics(sessionID:id)
        var resource=rusage();getrusage(RUSAGE_SELF,&resource)
        let kinds=Dictionary(grouping:graph.nodes,by:{ $0.kind.rawValue }).mapValues(\.count)
        let relations=Dictionary(grouping:graph.edges,by:{ $0.kind.rawValue }).mapValues(\.count)
        let current=graph.nodes.filter { $0.turnID==graph.currentTurnID }
        let currentCalls=current.filter { [.toolCall,.command,.mcp].contains($0.kind) }
        let activeCalls=currentCalls.filter { $0.status.isActive }
        let callGroups=Dictionary(grouping:currentCalls.filter { $0.callID != nil },by:{ $0.callID! })
        let samples=graph.usage.suffix(3).map { usage -> [String:Any] in
            var row:[String:Any] = ["scope":usage.scope,"session_id":usage.sessionID,"source":usage.source]
            row["turn_id"]=usage.turnID;row["input"]=usage.input;row["cached_input"]=usage.cachedInput
            row["output"]=usage.output;row["reasoning_output"]=usage.reasoningOutput
            row["last_request_input"]=usage.lastRequestInput;row["model_window"]=usage.modelContextWindow
            row["includes_subsessions"]=usage.includesSubsessions
            return row
        }
        var report:[String:Any] = [
            "session_id":id,"read_only":true,"loaded_at":graph.loadedAt.ISO8601Format(),
            "turns":graph.turns.count,"nodes":graph.nodes.count,"edges":graph.edges.count,
            "current_turn_nodes":current.count,"node_kinds":kinds,"relation_kinds":relations,
            "current_active_call_kinds":Dictionary(grouping:activeCalls,by:{ $0.kind.rawValue }).mapValues(\.count),
            "current_duplicate_call_id_groups":callGroups.values.filter { $0.count>1 }.count,
            "usage_samples":graph.usage.count,"last_usage_samples":samples,
            "cold_seconds":coldSeconds,"warm_seconds":warmSeconds,
            "cold_suffix_bytes":first?.lastReadBytes ?? -1,
            "warm_suffix_bytes":warm?.lastReadBytes ?? -1,"warm_parsed_records":warm?.parsedRecords ?? -1,
            "indexed_records":first?.totalParsedRecords ?? -1,"process_peak_rss_bytes":resource.ru_maxrss,
            "coverage":graph.coverage.map { ["source":$0.source,"status":$0.status.rawValue,
                                               "records":$0.records,"bytes":$0.bytes,"issues":$0.issues] as [String:Any] },
            "measurement_notes":["Cold means first index, not cold OS file cache.",
                                  "Suffix byte counters exclude bounded integrity probes (up to 8KiB).",
                                  "The source can append between reads; warm may therefore read a suffix."]
        ]
        report["current_turn_id"]=graph.currentTurnID
        print(String(decoding:try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]),as:UTF8.self))
    }
}
