import SwiftUI
import AppKit
import MaestroCore

@main struct CodexMaestroApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = Self.makeStore()
    @AppStorage("appearance") private var appearance = "system"
    @MainActor private static func makeStore() -> MaestroStore {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--performance-catalog") {
            do { return PerformanceFixture.store(catalog: try CodexCatalog().read()) }
            catch {
                let store = MaestroStore(demo: true)
                store.error = "성능 검증용 카탈로그를 읽지 못했습니다: \(error.localizedDescription)"
                return store
            }
        }
        if arguments.contains("--performance-demo") { return PerformanceFixture.store(catalog: PerformanceFixture.catalog()) }
        return MaestroStore(demo: arguments.contains("--demo"))
    }
    var body: some Scene {
        Window("Codex Maestro", id: "maestro") {
            WorkspaceView(store: store)
                .preferredColorScheme(appearance == "light" ? .light : appearance == "dark" ? .dark : nil)
                .frame(minWidth: 1120, minHeight: 720)
                .task { await store.run() }
                .onAppear { delegate.onQuit = { store.saveDrafts() } }
                .onDisappear { store.saveDrafts() }
        }
        .defaultSize(width: 1480, height: 920)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(after: .newItem) {
                Button("새로고침") { Task { await store.refresh() } }.keyboardShortcut("r", modifiers: .command)
                Button("Codex 다시 연결") { Task { await store.reconnect() } }
                Divider()
                Button("토폴로지 내보내기…") { store.exportGraph() }.keyboardShortcut("e", modifiers: [.command, .shift])
            }
        }
    }
}
final class AppDelegate: NSObject, NSApplicationDelegate {
    var onQuit: (() -> Void)?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { onQuit?() }
}
