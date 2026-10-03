import Foundation
import MaestroCore

@main struct MaestroProbe {
    @MainActor static func main() async {
        do {
            let catalog = CodexCatalog()
            let arguments = Array(CommandLine.arguments.dropFirst())
            if !arguments.isEmpty {
                guard arguments.count == 2, ["--context", "--project-context"].contains(arguments[0]), !arguments[1].isEmpty else {
                    fputs("Usage: MaestroProbe [--context SESSION_ID | --project-context PROJECT_ID]\n", stderr)
                    exit(2)
                }
                let snapshot = try await Task.detached { try catalog.read(includeArchived: true) }.value
                let loader = ContextTopologyLoader(home: catalog.home)
                let graph: ContextTopology
                if arguments[0] == "--context" {
                    guard let session = snapshot.sessions.first(where: { $0.id == arguments[1] }) else {
                        throw MaestroError.message("Requested session is absent from the catalog.")
                    }
                    graph = try await loader.load(session: session, catalog: snapshot.sessions)
                } else {
                    guard let project = snapshot.projects.first(where: { $0.id == arguments[1] }) else {
                        throw MaestroError.message("Requested project is absent from the catalog.")
                    }
                    graph = try await loader.load(project: project, sessions: snapshot.sessions)
                }
                printContextSummary(graph)
                return
            }
            let snapshot = try await Task.detached { try catalog.read() }.value
            print("Catalog: \(snapshot.projects.count) projects, \(snapshot.sessions.count) unarchived sessions")
            let bridge = DesktopBridge()
            var observed: Set<String> = []
            bridge.onSnapshot = { id, state in
                guard !state.owner.isEmpty else { return }
                if observed.insert(id).inserted { print("Live session: \(id), \(state.status.rawValue)") }
            }
            try await bridge.connect(socketPath: catalog.home.appendingPathComponent("ipc/ipc.sock").path)
            try bridge.follow(snapshot.sessions.map(\.id))
            try await Task.sleep(for: .seconds(4))
            print("Desktop IPC: connected; live snapshots: \(observed.count)")
            if let id = snapshot.sessions.first?.id {
                let messages = try catalog.transcript(threadID: id)
                print("Latest session transcript: \(messages.count) messages")
            }
            bridge.disconnect()
        } catch { fputs("MaestroProbe: \(error.localizedDescription)\n", stderr); exit(1) }
    }

    private static func printContextSummary(_ graph: ContextTopology) {
        print("Context read: \(graph.scope.kind.rawValue); sessions: \(graph.sessions.count); archived: \(graph.sessions.filter(\.isArchived).count)")
        print("Graph: \(graph.nodes.count) nodes, \(graph.edges.count) edges")
        for kind in ContextNodeKind.allCases {
            let nodes = graph.nodes.filter { $0.kind == kind }
            guard !nodes.isEmpty else { continue }
            print("Node kind \(kind.rawValue): \(nodes.count); records: \(nodes.reduce(0) { $0 + $1.recordCount })")
        }
        print("Coverage: \(graph.coverage.count) sources; records: \(graph.coverage.reduce(0) { $0 + $1.records }); bytes: \(graph.coverage.reduce(0) { $0 + $1.bytes }); issues: \(graph.coverage.reduce(0) { $0 + $1.issues.count })")
        for status in [ContextCoverageStatus.complete, .partial, .missing, .error, .skipped] {
            let sources = graph.coverage.filter { $0.status == status }
            if !sources.isEmpty { print("Coverage status \(status.rawValue): \(sources.count) sources") }
        }
        let tools = graph.nodes.filter { $0.kind == .tool }
        print("Observed tool groups: \(tools.count); tool calls: \(graph.nodes.filter { $0.kind == .toolCall }.count); tool results: \(graph.nodes.filter { $0.kind == .toolResult }.count)")
        // Labels describe telemetry provenance, not raw record content or metadata.
        let cumulative = graph.usage.filter { $0.source == "Codex state database" }.count
        print("Usage label recorded cumulative catalog usage: \(cumulative) samples")
        print("Usage label recorded token telemetry: \(graph.usage.count - cumulative) samples")
        print("Read-only recorded evidence; no current model-input or tool-availability claim")
    }
}
