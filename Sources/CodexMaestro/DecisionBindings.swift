import Foundation
import AppKit
import MaestroCore

extension MaestroStore {
    @discardableResult func prepareDecisionDraft(_ prompt: String, sessionID: String) -> Bool {
        guard sessions.contains(where: { $0.id == sessionID }), !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { error = "초안 대상 또는 원문이 없습니다."; return false }
        let existing = draft(for: sessionID)
        guard existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || existing == prompt else { error = "선택한 세션에 기존 초안이 있습니다. 초안을 정리한 뒤 다시 준비하세요."; return false }
        let previous = workspace
        workspace.drafts[sessionID] = prompt
        guard save() else { workspace = previous; return false }
        closeSessionWork()
        selectedProjectID = nil; selectedNodeProjectID = nil; scope = "all"; search = ""; selectSessionID(sessionID)
        record("판단 결과에서 초안 준비")
        notice = "초안을 준비했습니다. 세션에서 확인한 뒤 직접 전송하세요."
        return true
    }
}
