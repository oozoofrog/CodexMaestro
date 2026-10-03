import SwiftUI
import MaestroCore

extension MaestroStore {
    func requestOverlap(from source: LinkEndpoint, to target: LinkEndpoint) {
        guard source != target, endpointExists(source), endpointExists(target) else { return }
        cancelLink()
        overlapProposal = OverlapProposal(source: source, target: target)
    }

    @discardableResult func confirmOverlap(_ proposal: OverlapProposal, function: ConnectionFunction) -> Bool {
        guard overlapProposal?.id == proposal.id, proposal.source != proposal.target,
              endpointExists(proposal.source), endpointExists(proposal.target),
              ConnectionFunction.availableFunctions.contains(function) else {
            error = "연결할 항목이 변경되었습니다. 다시 선택하세요."
            return false
        }
        let previous = workspace
        do {
            let existing = workspace.allNodeLinks.first { $0.source == proposal.source && $0.target == proposal.target && $0.kind == .context }
            let link = existing ?? NodeLink(source: proposal.source, target: proposal.target, kind: .context)
            if existing == nil { try workspace.addNodeLink(link) }
            var configuration = workspace.connectionActions[link.id.uuidString]?.sessionManagedSkills() ?? ConnectionActionConfiguration()
            let previousEndpoint = configuration.executionEndpoint(for: link)
            configuration.function = function
            configuration.executionSide = function.defaultExecutionSide
            if previousEndpoint != configuration.executionEndpoint(for: link) { configuration.recipientSessionID = nil }
            workspace.connectionActions[link.id.uuidString] = configuration
            workspace.version = max(3, workspace.version)
            guard save() else { workspace = previous; return false }
            showLinks = true
            overlapProposal = nil
            actionSheetTarget = ConnectionActionTarget(id: link.id)
            record("연결 요청 · \(function.label)")
            return true
        } catch { workspace = previous; self.error = error.localizedDescription; return false }
    }
}

struct OverlapActionView: View {
    @Bindable var store: MaestroStore
    let proposal: OverlapProposal
    @State private var operationError: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("다음 작업").font(.system(size: 18, weight: .medium))
            Text("\(store.endpointTitle(proposal.source)) → \(store.endpointTitle(proposal.target))")
                .font(.system(size: 12)).foregroundStyle(Palette.muted).lineLimit(2)
            VStack(spacing: 8) {
                ForEach(ConnectionFunction.availableFunctions, id: \.self) { function in
                    Button {
                        if !store.confirmOverlap(proposal, function: function) {
                            operationError = store.error; store.error = nil
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: symbol(function)).frame(width: 22).foregroundStyle(Palette.blue)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(function.label).font(.system(size: 13, weight: .medium))
                                Text(description(function)).font(.system(size: 11)).foregroundStyle(Palette.muted)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(Palette.muted)
                        }.padding(12).background(Palette.card, in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
            if let operationError { Text(operationError).font(.system(size: 11)).foregroundStyle(Palette.amber) }
            HStack { Spacer(); Button("취소") { store.overlapProposal = nil }.keyboardShortcut(.cancelAction) }
        }.padding(24).frame(width: 440).background(Palette.panel)
    }
    private func symbol(_ function: ConnectionFunction) -> String {
        switch function { case .reference: "book"; case .handoff: "arrow.right"; case .review: "checkmark.bubble"; default: "text.bubble" }
    }
    private func description(_ function: ConnectionFunction) -> String {
        switch function {
        case .reference: "옮긴 항목에서 상대 자료를 참고합니다."
        case .handoff: "상대 항목에 자료와 다음 작업을 전달합니다."
        case .review: "상대 항목에 검토를 요청합니다."
        default: "담당과 요청 내용을 직접 지정합니다."
        }
    }
}
