import SwiftUI
import MaestroCore

struct CircuitUsageSelection {
    static func main(in graph: SessionWorkTopology?, turn: WorkTurn?, cutoff: Date?) -> WorkUsage? {
        guard let graph else { return nil }
        let upper = cutoff ?? turn?.endedAt
        let eligible = graph.usage.filter { sample in
            guard sample.sessionID == graph.sessionID else { return false }
            // An undated sample cannot be positioned in historical playback.
            guard upper.map({ bound in sample.timestamp.map { $0 <= bound } ?? false }) ?? true else { return false }
            return sample.turnID == nil || turn?.id == nil || sample.turnID == turn?.id
        }
        if let explicit = eligible.last(where: { ($0.scope == "명시된 turn 계측" || $0.scope.hasPrefix("명시된 turn 누적")) && $0.turnID == turn?.id }) { return explicit }
        return eligible.last(where: { $0.scope.hasPrefix("세션 누적") }) ?? eligible.last
    }

    static func lastRequest(in graph: SessionWorkTopology?, turn: WorkTurn?, cutoff: Date?) -> WorkUsage? {
        guard let graph else { return nil }
        let upper = cutoff ?? turn?.endedAt
        return graph.usage.last { sample in
            guard sample.sessionID == graph.sessionID else { return false }
            guard sample.lastRequestInput != nil, sample.modelContextWindow != nil else { return false }
            guard upper.map({ bound in sample.timestamp.map { $0 <= bound } ?? false }) ?? true else { return false }
            return sample.turnID == nil || turn?.id == nil || sample.turnID == turn?.id
        }
    }

    static func addingIndependent(_ samples: [WorkUsage]) -> (input: Int64?, cached: Int64?, output: Int64?, reasoning: Int64?)? {
        guard !samples.isEmpty, Set(samples.map(\.sessionID)).count == samples.count,
              samples.allSatisfy({ $0.includesSubsessions == false }),
              samples.allSatisfy({ $0.scope == samples[0].scope }) else { return nil }
        func sum(_ key: KeyPath<WorkUsage,Int64?>) -> Int64? {
            var total: Int64 = 0
            for sample in samples {
                guard let value = sample[keyPath:key], value >= 0 else { return nil }
                let (next,overflow) = total.addingReportingOverflow(value)
                if overflow { return nil }; total = next
            }
            return total
        }
        guard let input=sum(\.input),let output=sum(\.output) else { return nil }
        return (input,sum(\.cachedInput),output,sum(\.reasoningOutput))
    }
}

struct CircuitTokenPanel: View {
    @Bindable var inspection:SessionWorkStore
    @Binding var includeChildren:Bool
    private var main:WorkUsage? { CircuitUsageSelection.main(in:inspection.graph,turn:inspection.selectedTurn,cutoff:inspection.historyCutoff) }
    private var lastRequest:WorkUsage? { CircuitUsageSelection.lastRequest(in:inspection.graph,turn:inspection.selectedTurn,cutoff:inspection.historyCutoff) }
    private var childIDs:[String] {
        Array(Set((inspection.graph?.nodes.filter { $0.kind == .subsession }.compactMap(\.relatedSessionID) ?? []) + inspection.knownSessions.filter { $0.parentID == inspection.session.id }.map(\.id))).filter { $0 != inspection.session.id }.sorted()
    }
    private var childSamples:[WorkUsage] {
        childIDs.compactMap { id in
            guard let graph=inspection.measuredGraphs[id] else { return nil }
            return CircuitUsageSelection.main(in:graph,turn:graph.turns.first { $0.id == graph.currentTurnID },cutoff:inspection.historyCutoff)
        }
    }
    private var sum:(input:Int64?,cached:Int64?,output:Int64?,reasoning:Int64?)? {
        guard includeChildren,let main,!childIDs.isEmpty,childSamples.count==childIDs.count else { return nil }
        return CircuitUsageSelection.addingIndependent([main]+childSamples)
    }
    var body:some View {
        VStack(alignment:.leading,spacing:7) {
            HStack(spacing:12) {
                Text("토큰 계측").font(.subheadline.weight(.medium))
                Text(main?.scope ?? "계측 미확인").font(.caption).foregroundStyle(Palette.muted)
                if let date=main?.timestamp { Text(date,style:.time).font(.caption.monospaced()).foregroundStyle(Palette.muted) }
                Spacer()
                if includeChildren {
                    Button("하위 계측 갱신") { Task { await inspection.refreshChildMetrics() } }.font(.caption)
                        .disabled(inspection.childMetricsLoading)
                    if inspection.childMetricsLoading { ProgressView().controlSize(.mini) }
                }
                Toggle("하위 세션 포함",isOn:$includeChildren).toggleStyle(.checkbox).font(.caption)
            }
            ScrollView(.horizontal) {
              HStack(alignment:.top,spacing:18) {
                metric("입력",sum?.input ?? main?.input,note:sum == nil ? "캐시 입력 포함" : "확인한 독립 범위 합계")
                metric("캐시 입력",sum != nil ? sum?.cached : main?.cachedInput,note:"입력의 일부")
                metric("출력",sum?.output ?? main?.output,note:"추론 출력 \(format(sum != nil ? sum?.reasoning : main?.reasoningOutput)) 포함")
                VStack(alignment:.leading,spacing:3) {
                    Text("메인 최근 입력 / 한도").font(.caption).foregroundStyle(Palette.muted)
                    Text(lastRequest?.lastRequestRatio.map { ($0*100).formatted(.number.precision(.fractionLength(1)))+"%" } ?? "미확인").font(.title3.monospacedDigit())
                    Text(lastRequest?.modelContextWindow.map { "입력 \(format(lastRequest?.lastRequestInput)) / 한도 \($0.formatted())" } ?? "입력·한도 쌍 미확인").font(.caption2).foregroundStyle(Palette.muted)
                    Text("점유율 아님").font(.caption2).foregroundStyle(Palette.muted)
                    if let date=lastRequest?.timestamp { Text("비율 계측 \(date.formatted(date:.omitted,time:.standard))").font(.caption2.monospaced()).foregroundStyle(Palette.muted) }
                }.frame(minWidth:200,maxWidth:.infinity,alignment:.leading)
              }.frame(minWidth:640,alignment:.leading)
            }.scrollIndicators(.hidden)
            if includeChildren {
              VStack(alignment:.leading,spacing:7) {
                HStack(alignment:.top,spacing:8) {
                    Image(systemName:sum == nil ? "info.circle" : "sum")
                    Text(sum == nil ? "하위 계측 \(childSamples.count) / \(childIDs.count)개 · 중복·범위 확인 전 합계 없음" : "메인 + 하위 \(childSamples.count)개 · 계측 시각은 각 세션별로 다름")
                    Spacer()
                }
                if let checked=inspection.childMetricsCheckedAt {
                    Text("하위 세션 계측은 조회 시점의 기록입니다 · 조회 \(checked.formatted(date:.omitted,time:.standard))")
                }
                ForEach(inspection.childMetricsErrors.keys.sorted(),id:\.self) { id in
                    Text("\(inspection.knownSessions.first { $0.id==id }?.title ?? id): \(inspection.childMetricsErrors[id] ?? "계측 미확인")")
                        .foregroundStyle(Palette.amber).textSelection(.enabled)
                }
                ScrollView(.horizontal) {
                  HStack(alignment:.top,spacing:18) {
                    ForEach(childSamples) { sample in
                        VStack(alignment:.trailing,spacing:2) {
                            Text(inspection.knownSessions.first { $0.id==sample.sessionID }?.title ?? sample.sessionID).lineLimit(1)
                            Text("입력 \(format(sample.input)) · 출력 \(format(sample.output))").monospacedDigit()
                            if let date=sample.timestamp { Text(date,style:.time).monospacedDigit() }
                        }.frame(width:200,alignment:.trailing).help(sample.scope)
                    }
                  }
                }.scrollIndicators(.hidden)
              }.font(.caption2).foregroundStyle(Palette.muted)
            }
        }.padding(.horizontal,18).padding(.vertical,11).background(Palette.panel)
        .overlay(alignment:.top) { Rectangle().fill(Palette.border).frame(height:1) }
        .task(id:includeChildren ? inspection.session.id+":"+(inspection.graph?.currentTurnID ?? "") : "") {
            if includeChildren { await inspection.refreshChildMetrics() }
        }
    }
    private func metric(_ title:String,_ value:Int64?,note:String)->some View {
        VStack(alignment:.leading,spacing:3) { Text(title).font(.caption).foregroundStyle(Palette.muted);Text(format(value)).font(.title3.monospacedDigit());Text(note).font(.caption2).foregroundStyle(Palette.muted) }.frame(minWidth:130,maxWidth:.infinity,alignment:.leading)
    }
    private func format(_ value:Int64?)->String { value.map { $0.formatted() } ?? "미확인" }
}
