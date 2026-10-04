import Foundation
import Observation
import AppKit
import UniformTypeIdentifiers
import MaestroCore

enum DecisionSourceKind: String, CaseIterable, Identifiable {
    case manual, project, session, record, draft
    var id: String { rawValue }
    var label: String { switch self { case .manual: "직접 입력 JSON"; case .project: "프로젝트"; case .session: "세션"; case .record: "기록"; case .draft: "초안" } }
}
@MainActor @Observable final class DecisionWorkbenchStore {
    var profiles: [DecisionProfile] = []
    var profile = DecisionProfile.starter
    var apiKey = ""
    var models: [DecisionModel] = []
    var sourceKind = DecisionSourceKind.manual
    var sessionID: String
    var projectID: String
    var recordID = ""
    var goal = ""
    var manualJSON = "{\n  \"goal\": \"검토할 목표\",\n  \"records\": []\n}"
    var input: DecisionInput?
    var inputSelectionFingerprint: String?
    var result: DecisionResult?
    var resultSelectionFingerprint: String?
    var sourceGraph: ContextTopology?
    var sourceNodes: [ContextNode] = []
    var running = false
    var loadingInput = false
    var progress = ""
    var error: String?
    var notice: String?
    private let repository: DecisionProfileRepository
    private var writable = true
    @ObservationIgnored private let engine = DecisionEngine()
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var inputTask: Task<Void, Never>?
    @ObservationIgnored private var runGeneration = UUID()
    @ObservationIgnored private var inputGeneration = UUID()
    @ObservationIgnored private var bodyResolver: (@Sendable (String) async throws -> DecisionJSON)?

    init(maestro: MaestroStore, repository: DecisionProfileRepository? = nil) {
        sessionID = maestro.selectedSessionID ?? maestro.sessions.first?.id ?? ""
        projectID = maestro.selectedProjectID ?? maestro.projects.first?.id ?? ""
        let defaultURL = maestro.demo
            ? FileManager.default.temporaryDirectory.appendingPathComponent("CodexMaestroDecisionDemo-\(ProcessInfo.processInfo.processIdentifier)/profiles.json")
            : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CodexMaestro/decision-profiles.json")
        self.repository = repository ?? .init(url: defaultURL)
        do { profiles = try self.repository.load(); if let first = profiles.first { profile = first } }
        catch { self.error = "Profile을 읽지 못했습니다: \(error.localizedDescription)"; writable = false }
    }
    func selectionFingerprint(maestro: MaestroStore) -> String {
        var observed: [String: DecisionJSON] = [:]
        if sourceKind != .manual {
            let sessions = sourceKind == .project ? maestro.sessions.filter { $0.projectID == projectID } : maestro.sessions.filter { $0.id == sessionID }
            observed = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, .object(["updated": .numeric($0.updatedAt.timeIntervalSince1970), "draft": .string(sourceKind == .draft ? maestro.draft(for: $0.id) : "")])) })
        }
        return DecisionJSON.object(["kind": .string(sourceKind.rawValue), "project": .string(projectID), "session": .string(sessionID), "record": .string(recordID), "goal": .string(goal), "manual": .string(manualJSON), "observed": .object(observed)]).fingerprint
    }
    func status(maestro: MaestroStore) -> DecisionResultStatus? {
        guard let result else { return nil }
        if resultSelectionFingerprint != selectionFingerprint(maestro: maestro) || result.profile != profile { return .stale }
        return result.status
    }
    func invalidateInput() { inputTask?.cancel(); inputGeneration = UUID(); loadingInput = false; input = nil; inputSelectionFingerprint = nil; bodyResolver = nil }
    func loadInput(maestro: MaestroStore) {
        inputTask?.cancel(); let generation = UUID(); inputGeneration = generation
        loadingInput = true; error = nil
        let kind = sourceKind, sessionID = sessionID, projectID = projectID, recordID = recordID, goal = goal, manual = manualJSON
        let stamp = selectionFingerprint(maestro: maestro)
        let projects = maestro.projects, sessions = maestro.sessions, reader = maestro.contextReader, home = maestro.catalog.home
        let draft = maestro.draft(for: sessionID)
        inputTask = Task { [weak self] in
            do {
                var input: DecisionInput, graph: ContextTopology?, nodes: [ContextNode] = []
                var resolver: (@Sendable (String) async throws -> DecisionJSON)?
                if kind == .manual {
                    let state = try DecisionJSON.parse(manual); guard state.isStateForWorkbench else { throw DecisionFailure.insufficientInput("JSON 문자열·객체·배열이 필요합니다.") }
                    input = .init(state: state, evidence: [.init(id: "manual", coverage: "full", fingerprint: state.fingerprint)])
                } else if kind == .draft {
                    guard sessions.contains(where: { $0.id == sessionID }), !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DecisionFailure.insufficientInput("선택한 세션의 초안이 없습니다.") }
                    let state = DecisionJSON.object(["goal": .string(goal), "sessionID": .string(sessionID), "draft": .string(draft)])
                    input = .init(state: state, evidence: [.init(id: sessionID, coverage: "full draft", fingerprint: DecisionJSON.string(draft).fingerprint)])
                } else {
                    let endpoint = kind == .project ? LinkEndpoint.project(projectID) : .session(sessionID)
                    let loaded = try await reader(endpoint, projects, sessions); graph = loaded
                    try Task.checkCancellation()
                    guard let self, self.inputGeneration == generation, self.selectionFingerprint(maestro: maestro) == stamp else { return }
                    nodes = loaded.nodes.filter { $0.kind != .group && $0.kind != .session && $0.kind != .project && $0.kind != .association }
                    let loader = ContextTopologyLoader(home: home)
                    if kind == .record {
                        guard let node = nodes.first(where: { $0.id == recordID }) else {
                            self.sourceGraph = loaded; self.sourceNodes = nodes
                            throw DecisionFailure.insufficientInput("기록 목록을 불러왔습니다. 기록을 선택하고 입력을 다시 불러오세요.")
                        }
                        let body = try await loader.loadBody(node: node)
                        let state = DecisionJSON.object(["goal": .string(goal), "id": .string(node.id), "title": .string(node.title), "body": .string(body)])
                        input = .init(state: state, materials: [node.id: .string(body)], evidence: [.init(id: node.id, coverage: "full sanitized record", fingerprint: DecisionJSON.string(body).fingerprint)])
                    } else {
                        let registered = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
                        resolver = { id in
                            guard let node = registered[id] else { throw DecisionFailure.insufficientInput("허용한 자료 ID가 아닙니다: \(id)") }
                            do { return .string(try await loader.loadBody(node: node)) }
                            catch is CancellationError { throw CancellationError() }
                            catch { throw DecisionFailure.stale("자료 \(id)를 다시 불러오세요: \(error.localizedDescription)") }
                        }
                        let candidates = Dictionary(uniqueKeysWithValues: nodes.map { node in
                            (node.id, DecisionJSON.object(["title": .string(node.title), "kind": .string(node.kind.rawValue), "summary": .string(node.summary), "characters": .number(Decimal(node.charCount)), "source": .string(node.source)]))
                        })
                        let coverage = loaded.coverage.map { item in DecisionJSON.object(["source": .string(item.source), "status": .string(item.status.rawValue), "records": .number(Decimal(item.records)), "issues": .array(item.issues.map(DecisionJSON.string))]) }
                        let state = DecisionJSON.object(["goal": .string(goal), "title": .string(loaded.title), "scope": .string(endpoint.id), "candidates": .object(candidates), "coverage": .array(coverage), "boundaries": .array(loaded.boundaries.map(DecisionJSON.string))])
                        let evidence = nodes.map { DecisionEvidence(id: $0.id, coverage: "summary; full body available on explicit plan stage", fingerprint: $0.bodyReference?.fingerprint ?? DecisionJSON.string($0.fullText).fingerprint) }
                        input = .init(state: state, evidence: evidence)
                    }
                }
                try Task.checkCancellation()
                guard let self, self.inputGeneration == generation, self.selectionFingerprint(maestro: maestro) == stamp else { return }
                self.input = input; self.inputSelectionFingerprint = stamp; self.sourceGraph = graph; self.sourceNodes = nodes; self.bodyResolver = resolver
                self.loadingInput = false
                self.notice = "입력을 불러왔습니다. 실행하면 이 입력을 TypeSafe API에 전달합니다."
            } catch {
                guard let self, self.inputGeneration == generation else { return }
                self.loadingInput = false; self.error = error.localizedDescription
            }
        }
    }
    func run(maestro: MaestroStore) {
        guard !running else { return }
        let stamp = selectionFingerprint(maestro: maestro)
        guard let input, inputSelectionFingerprint == stamp else { error = "현재 입력을 불러온 뒤 실행하세요."; return }
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { error = DecisionFailure.authentication.localizedDescription; return }
        do { try profile.validate() } catch { self.error = error.localizedDescription; return }
        running = true; error = nil; notice = nil; progress = "판단 시작"
        let profile = profile, engine = engine, resolver = bodyResolver, service = TypeSafeHTTPClient(apiKey: apiKey)
        let generation = UUID(); runGeneration = generation; resultSelectionFingerprint = stamp
        runTask = Task { [weak self] in
            var result = await engine.execute(profile: profile, input: input, service: service, progress: { [weak self] value in
                await MainActor.run { guard let self, self.runGeneration == generation else { return }; self.progress = value.message }
            }, materialResolver: resolver)
            guard let self, self.runGeneration == generation else { return }
            if self.selectionFingerprint(maestro: maestro) != stamp || self.profile != profile { result.status = .stale; result.detail = "입력 또는 Profile이 변경되었습니다. 현재 입력으로 다시 실행하세요." }
            self.result = result; self.running = false; self.progress = result.status.label
        }
    }
    func cancel() { runTask?.cancel(); inputTask?.cancel(); loadingInput = false; inputGeneration = UUID() }
    func save() {
        guard writable else { error = "기존 Profile 파일을 읽지 못해 저장을 중단했습니다."; return }
        do {
            var value = profile
            if let previous = profiles.first(where: { $0.id == value.id }), previous != value { value.revision = previous.revision + 1 }
            for stageIndex in value.plan.stages.indices {
                for questionIndex in value.plan.stages[stageIndex].questions.indices {
                    let stageID = value.plan.stages[stageIndex].id, question = value.plan.stages[stageIndex].questions[questionIndex]
                    if let old = profiles.first(where: { $0.id == value.id })?.plan.stages.first(where: { $0.id == stageID })?.questions.first(where: { $0.id == question.id }) {
                        if old.spec.instructions != question.spec.instructions || old.spec.type != question.spec.type { value.plan.stages[stageIndex].questions[questionIndex].revision = old.revision + 1 }
                        if old.spec.criteria != question.spec.criteria { value.plan.stages[stageIndex].questions[questionIndex].criteriaRevision = old.criteriaRevision + 1 }
                    }
                }
            }
            try value.validate()
            var all = profiles; if let index = all.firstIndex(where: { $0.id == value.id }) { all[index] = value } else { all.append(value) }
            try repository.save(all); profiles = all; profile = value; notice = "Profile을 저장했습니다."
        } catch { self.error = error.localizedDescription }
    }
    func clone() { profile.id = UUID(); profile.name += " 복제"; profile.revision = 1; notice = "복제한 Profile을 편집한 뒤 저장하세요." }
    func newProfile() { profile = .starter; notice = nil }
    func delete() {
        guard writable else { return }
        do { let remaining = profiles.filter { $0.id != profile.id }; try repository.save(remaining); profiles = remaining; profile = remaining.first ?? .starter }
        catch { self.error = error.localizedDescription }
    }
    func importProfile() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { var imported = try DecisionProfileRepository.decodeProfile(Data(contentsOf: url)); if profiles.contains(where: { $0.id == imported.id }) { imported.id = UUID(); imported.name += " 가져온 사본" }; profile = imported; notice = "가져온 Profile을 확인한 뒤 저장하세요." }
        catch { self.error = error.localizedDescription }
    }
    func exportProfile() {
        do {
            let data = try DecisionProfileRepository.encodeProfile(profile)
            let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "decision-profile.json"
            guard panel.runModal() == .OK, let url = panel.url else { return }; try data.write(to: url, options: .atomic); notice = "Profile을 내보냈습니다."
        } catch { self.error = error.localizedDescription }
    }
    func loadKey() { do { apiKey = try DecisionCredentials.load() ?? ""; notice = apiKey.isEmpty ? "저장한 키가 없습니다." : "Keychain에서 키를 불러왔습니다." } catch { self.error = error.localizedDescription } }
    func saveKey() { do { try DecisionCredentials.save(apiKey); notice = "Keychain에 키를 저장했습니다." } catch { self.error = error.localizedDescription } }
    func deleteKey() { do { try DecisionCredentials.delete(); apiKey = ""; notice = "저장한 키를 삭제했습니다." } catch { self.error = error.localizedDescription } }
    func loadModels() {
        guard !apiKey.isEmpty else { error = DecisionFailure.authentication.localizedDescription; return }
        let service = TypeSafeHTTPClient(apiKey: apiKey)
        Task { do { models = try await service.models(); notice = "모델 목록을 불러왔습니다." } catch { self.error = error.localizedDescription } }
    }
    func clearCache() { Task { await engine.clearCache(); notice = "메모리 결과 캐시를 비웠습니다." } }
}
private extension DecisionJSON { var isStateForWorkbench: Bool { switch self { case .string, .object, .array: true; default: false } } }
extension DecisionResultStatus {
    var label: String { switch self { case .succeeded: "판단 완료"; case .insufficientInput: "입력 부족"; case .insufficientJudgment: "판단 부족"; case .inputAdjustment: "입력 조정 필요"; case .apiError: "API 오류"; case .invalidProfile: "설정 오류"; case .cancelled: "취소"; case .stale: "오래된 결과" } }
}

extension DecisionWorkbenchStore {
    func validateForApplication(maestro: MaestroStore) async throws {
        guard let result, status(maestro: maestro) == .succeeded else { throw DecisionFailure.stale("현재 입력과 Profile의 성공 결과만 적용할 수 있습니다.") }
        let stamp = selectionFingerprint(maestro: maestro), profile = profile
        if let graph = sourceGraph {
            let fresh = try await maestro.contextReader(graph.scope, maestro.projects, maestro.sessions)
            func manifest(_ graph: ContextTopology) -> DecisionJSON {
                .array(graph.nodes.map { node in .object(["id": .string(node.id), "title": .string(node.title), "summary": .string(node.summary), "content": .string(node.bodyReference?.fingerprint ?? DecisionJSON.string(node.fullText).fingerprint)]) })
            }
            guard manifest(fresh) == manifest(graph) else { throw DecisionFailure.stale("저장된 자료가 변경되었습니다. 입력을 다시 불러오고 재평가하세요.") }
            let lookup = Dictionary(uniqueKeysWithValues: fresh.nodes.map { ($0.id, $0) })
            for id in Set(result.stages.values.flatMap(\.materialIDs)) {
                guard let node = lookup[id] else { throw DecisionFailure.stale("선택한 자료가 삭제되었습니다.") }
                _ = try await ContextTopologyLoader(home: maestro.catalog.home).loadBody(node: node)
            }
        }
        try Task.checkCancellation()
        guard status(maestro: maestro) == .succeeded, selectionFingerprint(maestro: maestro) == stamp, self.profile == profile else { throw DecisionFailure.stale("적용 중 입력 또는 Profile이 변경되었습니다.") }
    }
    /// Only explicit user clicks invoke handlers. Permission is the selected destination, never the model answer.
    func apply(_ binding: DecisionBinding, maestro: MaestroStore, allowedSessionID: String, allowedProjectID: String, comparisonSessionID: String) async -> DecisionBindingEffect? {
        do {
            guard result?.composed.bindings.contains(binding) == true else { throw DecisionFailure.invalid("현재 결과에 없는 handler입니다.") }
            try await validateForApplication(maestro: maestro)
            switch binding.handler {
            case "copyValue":
                guard let value = binding.arguments["value"] else { throw DecisionFailure.invalid("copyValue에는 value가 필요합니다.") }
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value.string ?? value.text, forType: .string)
                notice = "선택한 원본 값을 복사했습니다."; return .completed
            case "openContext":
                guard let kind = binding.arguments["kind"]?.string, let id = binding.arguments["id"]?.string else { throw DecisionFailure.invalid("openContext에는 kind·id가 필요합니다.") }
                let endpoint: LinkEndpoint
                if kind == "session", id == allowedSessionID { endpoint = .session(id) }
                else if kind == "project", id == allowedProjectID { endpoint = .project(id) }
                else { throw DecisionFailure.invalid("사용자가 선택한 적용 대상과 일치하지 않습니다.") }
                guard maestro.endpointExists(endpoint) else { throw DecisionFailure.stale("대상이 없습니다.") }
                maestro.openContext(for: endpoint); return .dismissWorkbench
            case "prepareDraft":
                guard let id = binding.arguments["sessionID"]?.string, id == allowedSessionID, let prompt = binding.arguments["prompt"]?.string else { throw DecisionFailure.invalid("prepareDraft의 sessionID가 적용 대상과 일치해야 하며, 원본 prompt가 필요합니다.") }
                guard maestro.prepareDecisionDraft(prompt, sessionID: id) else { throw DecisionFailure.invalid(maestro.error ?? "초안을 준비하지 못했습니다.") }
                notice = "초안을 준비했습니다. 대상 세션에서 확인한 뒤 직접 전송하세요."; return .completed
            case "compareSessions":
                guard let source = binding.arguments["sourceSessionID"]?.string, let target = binding.arguments["targetSessionID"]?.string,
                      source == allowedSessionID, target == comparisonSessionID, source != target,
                      let a = maestro.sessions.first(where: { $0.id == source }), let b = maestro.sessions.first(where: { $0.id == target }) else { throw DecisionFailure.invalid("비교 인수는 사용자가 선택한 두 세션과 일치해야 합니다.") }
                return .comparison(.init(source: a, target: b))
            default: throw DecisionFailure.invalid("등록하지 않은 handler: \(binding.handler)")
            }
        } catch { self.error = error.localizedDescription; return nil }
    }
}
struct DecisionSessionComparison: Identifiable { let id = UUID(); let source: Session; let target: Session }
enum DecisionBindingEffect { case completed, dismissWorkbench, comparison(DecisionSessionComparison) }
