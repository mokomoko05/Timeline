import SwiftUI
import TimelineCore

@main
struct TimelineMobileApp: App {
    @StateObject private var store: JournalStore
    @StateObject private var sync: SyncModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let store = JournalStore()
        store.writesInBackground = true
        _store = StateObject(wrappedValue: store)
        _sync = StateObject(wrappedValue: SyncModel(store: store))
    }

    var body: some Scene {
        WindowGroup {
            RootView(store: store, sync: sync)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: sync.setActive(true)
            case .background:
                store.save()
                sync.setActive(false)
            default: break
            }
        }
    }
}

struct RootView: View {
    @ObservedObject var store: JournalStore
    @ObservedObject var sync: SyncModel
    @State private var tab = Tab.tasks

    enum Tab: String { case tasks, journal, notes, boards, settings }

    var body: some View {
        TabView(selection: $tab) {
            TasksView(store: store, sync: sync)
                .tabItem { Label("待办", systemImage: "checklist") }
                .tag(Tab.tasks)
            JournalView(store: store, sync: sync)
                .tabItem { Label("日记", systemImage: "book") }
                .tag(Tab.journal)
            NotesView(store: store, sync: sync)
                .tabItem { Label("笔记", systemImage: "text.bubble") }
                .tag(Tab.notes)
            BoardsView(store: store)
                .tabItem { Label("工作板", systemImage: "doc.text") }
                .tag(Tab.boards)
            SyncSettingsView(store: store, sync: sync)
                .tabItem { Label("同步", systemImage: sync.isConfigured ? "icloud" : "icloud.slash") }
                .tag(Tab.settings)
        }
        .tint(Palette.accent)
        .onAppear {
            // 截图检查用：启动参数 `-startTab journal` 直接打开某个标签页。
            if let start = UserDefaults.standard.string(forKey: "startTab").flatMap(Tab.init(rawValue:)) { tab = start }
            else if !sync.isConfigured { tab = .settings }
        }
    }
}

/// 下拉刷新时同步一轮。
extension View {
    func syncOnRefresh(_ sync: SyncModel) -> some View {
        refreshable { await sync.syncNow() }
    }
}
