import Foundation
import MaestroCore

/// Read-only catalog snapshot for repeatable topology interaction profiling.
/// Demo mode suppresses IPC, refresh loops and workspace persistence writes.
@MainActor enum PerformanceFixture {
    static func store(catalog: Catalog) -> MaestroStore {
        let store = MaestroStore(demo: true)
        store.projects = catalog.projects
        store.sessions = catalog.sessions
        store.workspace = WorkspaceState()
        store.events = []
        store.scope = "all"
        store.selectedSessionID = nil
        store.selectedProjectID = nil
        store.expandedProjects = Set(catalog.sessions.map { $0.projectID ?? "unassigned" })
        return store
    }

    /// Synthetic, deterministic fixture; never claims real session connectivity.
    static func catalog(sessionCount: Int = 601, projectCount: Int = 31) -> Catalog {
        precondition(sessionCount > 0 && projectCount > 0)
        let projects = (0..<projectCount).map { Project(id: "stress-project-\($0)", name: "Stress Project \($0)") }
        let sessions = (0..<sessionCount).map { index -> Session in
            let projectID: String? = index == sessionCount - 1 ? nil : projects[index % projectCount].id
            var session = Session(id: "stress-session-\(index)", title: "Stress session \(index)", projectID: projectID,
                cwd: "/synthetic/project-\(index % projectCount)", model: "synthetic", updatedAt: Date(timeIntervalSince1970: Double(sessionCount - index)),
                parentID: index >= projectCount && index < sessionCount - 1 ? "stress-session-\(index - projectCount)" : nil)
            session.isLive = index % 11 == 0
            session.status = index % 13 == 0 ? .running : (session.isLive ? .idle : .unknown)
            return session
        }
        return Catalog(projects: projects, sessions: sessions)
    }
}
