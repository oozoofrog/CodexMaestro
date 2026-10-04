import Foundation
import MaestroCore

extension MaestroStore {
    @discardableResult func completeConnectionDrag(from source: LinkEndpoint, to target: LinkEndpoint) -> Bool {
        guard source != target, endpointExists(source), endpointExists(target) else { return false }
        cancelLink()
        let link: NodeLink
        if let existing = workspace.allNodeLinks.first(where: { $0.source == source && $0.target == target && $0.kind == .context }) {
            link = existing
        } else {
            let value = NodeLink(source: source, target: target, kind: .context)
            guard saveNodeLink(value) else { return false }
            link = value
        }
        showLinks = true
        configureConnection(link)
        return true
    }

    func configureConnection(_ link: NodeLink) {
        guard workspace.allNodeLinks.contains(where: { $0.id == link.id }) else { return }
        actionSheetTarget = ConnectionActionTarget(id: link.id)
    }

    func connectionAction(for id: UUID) -> ConnectionActionConfiguration {
        (workspace.connectionActions[id.uuidString] ?? ConnectionActionConfiguration()).sessionManagedSkills()
    }
    func actionRecipientCandidates(link: NodeLink, config: ConnectionActionConfiguration) -> [Session] {
        let endpoint = config.executionEndpoint(for: link)
        return sessions.filter { endpoint.kind == .session ? $0.id == endpoint.id : $0.projectID == endpoint.id }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private func validatedAction(_ link: NodeLink, _ config: ConnectionActionConfiguration, requireRecipient: Bool) throws -> Session? {
        guard workspace.allNodeLinks.first(where: { $0.id == link.id }) == link,
              endpointExists(link.source), endpointExists(link.target) else {
            throw MaestroError.message("연결 또는 대상이 변경되었습니다. 연결을 다시 선택하세요.")
        }
        let endpoint = config.executionEndpoint(for: link)
        let candidate: Session?
        if endpoint.kind == .session {
            candidate = sessions.first { $0.id == endpoint.id }
            if let chosen = config.recipientSessionID, chosen != endpoint.id {
                throw MaestroError.message("선택한 작업 세션이 연결의 작업 위치와 일치하지 않습니다.")
            }
        } else {
            candidate = config.recipientSessionID.flatMap { chosen in sessions.first { $0.id == chosen && $0.projectID == endpoint.id } }
            if config.recipientSessionID != nil, candidate == nil {
                throw MaestroError.message("선택한 세션이 현재 작업 프로젝트에 속하지 않습니다. 담당 세션을 다시 선택하세요.")
            }
        }
        if requireRecipient, candidate == nil { throw MaestroError.message("프로젝트에서 작업할 세션을 선택하세요.") }
        if config.function == .custom, config.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw MaestroError.message("직접 실행할 프롬프트를 입력하세요.")
        }
        return candidate
    }

    @discardableResult func saveConnectionAction(link: NodeLink, config: ConnectionActionConfiguration) -> Bool {
        let config = config.sessionManagedSkills()
        do {
            _ = try validatedAction(link, config, requireRecipient: false)
            let previous = workspace
            workspace.connectionActions[link.id.uuidString] = config
            workspace.version = max(3, workspace.version)
            guard save() else { workspace = previous; return false }
            record("연결 기능 저장 · \(config.function.label)")
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    func buildConnectionPrompt(link: NodeLink, config: ConnectionActionConfiguration) async throws -> String {
        let config = config.sessionManagedSkills()
        guard let receiver = try validatedAction(link, config, requireRecipient: true) else { throw MaestroError.message("작업 세션을 선택하세요.") }
        let reference = config.referenceEndpoint(for: link)
        let material: String
        if reference.kind == .session {
            guard let session = sessions.first(where: { $0.id == reference.id }) else { throw MaestroError.message("참고 세션이 없습니다.") }
            let messages = try await connectionReferenceMessages(session.id)
            try Task.checkCancellation()
            let savedResponse = messages.last(where: { $0.role == "assistant" })?.text
            let response = savedResponse ?? session.preview
            let scope = savedResponse == nil ? "카탈로그의 세션 요약입니다." : "최근 저장된 어시스턴트 응답입니다."
            let excerpt = String(response.prefix(16_000)) + (response.count > 16_000 ? "\n[긴 응답의 앞부분만 포함했습니다.]" : "")
            material = "참고 세션: \(session.title)\n출처: codex://threads/\(session.id)\n작업 경로: \(session.cwd)\n\(scope) 전체 대화나 실행 중인 내부 상태는 포함하지 않았습니다.\n<reference_material>\n\(excerpt)\n</reference_material>"
        } else {
            guard let project = projects.first(where: { $0.id == reference.id }) else { throw MaestroError.message("참고 프로젝트가 없습니다.") }
            material = "참고 프로젝트: \(project.name)\n프로젝트 ID: \(project.id)\n참고 경로:\n\(project.roots.map { "- " + $0 }.joined(separator: "\n"))\n프로젝트의 파일과 세션 대화를 첨부하지 않았습니다. 요청에 필요한 파일을 확인하고, 접근할 수 없으면 필요한 근거를 명시하세요."
        }
        _ = try validatedAction(link, config, requireRecipient: true)
        var sections = ["연결 기능: \(config.function.label)\n실제 작업 세션: \(receiver.title) (\(receiver.id))\n연결: \(endpointTitle(link.source)) → \(endpointTitle(link.target))", material]
        if !link.note.isEmpty { sections.append("연결 메모:\n\(link.note)") }
        sections.append(config.function.instruction)
        if !config.prompt.isEmpty { sections.append("요청:\n\(config.prompt)") }
        sections.append("스킬 선택:\n이 세션에서 사용할 수 있는 스킬 중 요청에 적합한 스킬이 있으면 직접 선택해서 사용하세요. 적합한 스킬이 없으면 일반 작업 방식으로 진행하세요. 요청을 수행하는 데 반드시 필요한 스킬을 사용할 수 없으면 누락된 조건을 명시하세요.")
        return sections.joined(separator: "\n\n")
    }

    @discardableResult func prepareConnectionAction(link: NodeLink, config: ConnectionActionConfiguration, preparedPrompt: String? = nil) async -> Bool {
        let config = config.sessionManagedSkills()
        do {
            let text: String
            if let preparedPrompt { text = preparedPrompt }
            else { text = try await buildConnectionPrompt(link: link, config: config) }
            try Task.checkCancellation()
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let receiver = try validatedAction(link, config, requireRecipient: true) else { throw MaestroError.message("준비할 초안이 없습니다.") }
            let existing = draft(for: receiver.id)
            guard existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || existing == text else {
                throw MaestroError.message("‘\(receiver.title)’에 기존 초안이 있습니다. 해당 세션에서 기존 초안을 정리한 뒤 다시 준비하세요. 연결 설정과 초안은 유지됩니다.")
            }
            let previous = workspace
            workspace.connectionActions[link.id.uuidString] = config
            workspace.version = max(3, workspace.version)
            workspace.drafts[receiver.id] = text
            guard save() else { workspace = previous; return false }
            closeSessionWork()
            selectedProjectID = nil; selectedNodeProjectID = nil; scope = "all"; search = ""
            selectSessionID(receiver.id)
            await loadTranscript(receiver.id)
            notice = "‘\(receiver.title)’의 초안을 준비했습니다. 내용을 편집하고 전송하세요."
            record("연결 초안 준비 · \(config.function.label) · \(receiver.title)")
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
}
