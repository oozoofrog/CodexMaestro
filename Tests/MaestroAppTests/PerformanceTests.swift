import XCTest
import Observation
import MaestroCore
@testable import CodexMaestro

private final class InvalidationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); defer { lock.unlock() }; count += 1 }
}

final class PerformanceTests: XCTestCase {
    @MainActor func test601SessionsExpandedGroupingPreservesEverySessionExactlyOnce() {
        let store = PerformanceFixture.store(catalog: PerformanceFixture.catalog())
        XCTAssertEqual(store.sessions.count, 601)
        let filtered = store.filteredSessions
        let grouped = Dictionary(grouping: filtered) { $0.projectID ?? "unassigned" }
        let projects = store.orderedProjects(for: filtered)
        let displayed = projects.flatMap { store.displayedSessions(grouped[$0.id] ?? [], projectID: $0.id) }
        XCTAssertEqual(projects.count, 32)
        XCTAssertEqual(displayed.count, 601)
        XCTAssertEqual(Set(displayed.map(\.id)), Set(store.sessions.map(\.id)))
        XCTAssertEqual(Set(displayed.map(\.id)).count, displayed.count)
        XCTAssertEqual(projects.filter { $0.id == "unassigned" }.count, 1)
        for project in projects {
            XCTAssertEqual(store.displayedSessions(in: project), grouped[project.id] ?? [])
        }
    }

    @MainActor func testProjectOrderingMatchesRunningThenFirstSessionAcross601Items() {
        let store = PerformanceFixture.store(catalog: PerformanceFixture.catalog())
        let filtered = store.filteredSessions
        let expected = store.projects + [Project(id: "unassigned", name: "")]
        // Deliberately simple independent reference, exercised outside the measured hot loop.
        let sorted = expected.sorted { a, b in
            let aRunning = filtered.contains { ($0.projectID ?? "unassigned") == a.id && $0.status == .running }
            let bRunning = filtered.contains { ($0.projectID ?? "unassigned") == b.id && $0.status == .running }
            if aRunning != bRunning { return aRunning }
            return (filtered.firstIndex { ($0.projectID ?? "unassigned") == a.id } ?? Int.max)
                < (filtered.firstIndex { ($0.projectID ?? "unassigned") == b.id } ?? Int.max)
        }
        XCTAssertEqual(store.orderedProjects(for: filtered).map(\.id), sorted.map(\.id))
        XCTAssertEqual(store.orderedProjects(for: filtered).map(\.id), store.orderedProjects(for: filtered).map(\.id))
        store.selectedProjectID = "stress-project-30"
        store.search = "does-not-match"
        XCTAssertEqual(store.visibleProjects.map(\.id), ["stress-project-30"])
    }

    @MainActor func testCollapsedCardsRetainLiveAndSelectedAndExpansionIsLossless() {
        let store = PerformanceFixture.store(catalog: PerformanceFixture.catalog())
        store.expandedProjects = []
        let project = store.projects[0]
        let items = store.sessions.filter { $0.projectID == project.id }
        let selected = items.last { !$0.isLive }!
        store.selectedSessionID = selected.id
        let firstThree = Set(items.prefix(3).map(\.id))
        let expected = items.filter { firstThree.contains($0.id) || $0.isLive || $0.id == selected.id }
        XCTAssertEqual(store.displayedSessions(items, projectID: project.id), expected)
        store.expandedProjects.insert(project.id)
        XCTAssertEqual(store.displayedSessions(items, projectID: project.id), items)
        store.expandedProjects = []
        store.search = "stress"
        XCTAssertEqual(store.displayedSessions(items, projectID: project.id), items)
        store.search = ""
        store.selectedProjectID = project.id
        XCTAssertEqual(store.displayedSessions(in: project), items)
    }

    @MainActor func testDragObservationDoesNotInvalidateCatalogLayoutDependencies() {
        let store = PerformanceFixture.store(catalog: PerformanceFixture.catalog())
        let drag = TopologyDragState()
        let layoutInvalidations = InvalidationCounter()
        let edgeInvalidations = InvalidationCounter()
        withObservationTracking {
            let filtered = store.filteredSessions
            _ = store.orderedProjects(for: filtered)
            _ = store.workspace.positions
            _ = store.expandedProjects
        } onChange: { layoutInvalidations.increment() }
        withObservationTracking {
            _ = drag.endpoint
            _ = drag.offset
        } onChange: { edgeInvalidations.increment() }
        drag.basePoint = CGPoint(x: 180, y: 240)
        for index in 0..<120 {
            drag.endpoint = .session("stress-session-0")
            drag.offset = CGSize(width: index, height: index / 2)
        }
        XCTAssertEqual(layoutInvalidations.value, 0)
        XCTAssertEqual(edgeInvalidations.value, 1, "Observation invalidation fires once until a consumer registers its next evaluation")
        drag.clear()
        XCTAssertNil(drag.endpoint)
        XCTAssertNil(drag.basePoint)
        XCTAssertEqual(drag.offset, .zero)
        store.setPosition("stress-session-0", point: CGPoint(x: 180, y: 240))
        XCTAssertEqual(layoutInvalidations.value, 1, "Committing a position must invalidate persisted layout")
        XCTAssertEqual(store.workspace.positions["stress-session-0"], NodePosition(x: 180, y: 240))
    }

    @MainActor func test601SessionGroupingTimingSample() {
        let store = PerformanceFixture.store(catalog: PerformanceFixture.catalog())
        var totals = 0
        let start = ContinuousClock.now
        for _ in 0..<200 {
            let filtered = store.filteredSessions
            let grouped = Dictionary(grouping: filtered) { $0.projectID ?? "unassigned" }
            totals += store.orderedProjects(for: filtered).reduce(0) {
                $0 + store.displayedSessions(grouped[$1.id] ?? [], projectID: $1.id).count
            }
        }
        let elapsed = start.duration(to: .now)
        XCTAssertEqual(totals, 200 * 601)
        print("PERFORMANCE_SAMPLE 601 sessions, 200 grouped layout preparations: \(elapsed); no rendering/FPS claim")
    }
}
