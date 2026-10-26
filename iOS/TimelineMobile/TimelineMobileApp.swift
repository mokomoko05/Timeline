import SwiftUI
import TimelineCore

@main
struct TimelineMobileApp: App {
    @StateObject private var store: JournalStore
    @StateObject private var sync: SyncModel
    @StateObject private var focus: FocusTimer
    @StateObject private var languages = LanguageStore()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let store = JournalStore()
        store.writesInBackground = true
        _store = StateObject(wrappedValue: store)
        _sync = StateObject(wrappedValue: SyncModel(store: store))
        _focus = StateObject(wrappedValue: FocusTimer(store: store))
    }

    var body: some Scene {
        WindowGroup {
            RootView(store: store, sync: sync)
                .environmentObject(focus)
                .environmentObject(languages)
                // 换语言：整个界面按新语言重建（拼出来的字符串也要重新算）。
                .environment(\.locale, languages.language.locale)
                .id(languages.language)
        }
        .onChange(of: scenePhase) { _, phase in
            PerfProbe.mark("scene \(phase)")
            switch phase {
            case .active:
                sync.setActive(true)
                focus.refresh()
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
    @EnvironmentObject private var focus: FocusTimer
    @SceneStorage("rootTab") private var tab = Tab.tasks

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
                .tabItem { Label("设置", systemImage: sync.isConfigured ? "gearshape" : "exclamationmark.icloud") }
                .tag(Tab.settings)
        }
        .tint(Palette.accent)
        .onAppear {
            // 截图检查用：启动参数 `-startTab journal` 直接打开某个标签页。
            if let start = UserDefaults.standard.string(forKey: "startTab").flatMap(Tab.init(rawValue:)) { tab = start }
            else if !sync.isConfigured { tab = .settings }
            PerfProbe.start()
            prewarmJournal()
            PerfProbe.runScript { tab = $0 }
            PerfProbe.demoFocus(focus)
        }
    }
}

extension RootView {
    /// 日记页第一次打开时要显示今天：今天和昨天的正文先在后台解析好。
    func prewarmJournal() {
        let calendar = JournalDates.calendar
        let keys = [Date(), calendar.date(byAdding: .day, value: -1, to: Date()) ?? Date()].map(JournalDates.key)
        let sources = store.allLogs(includeFocus: true).suffix(200).filter { keys.contains($0.key) }.map { LogStyle.body($0.log) }
        MarkdownBlock.prewarm(sources.filter { !$0.isEmpty })
    }
}

/// 下拉刷新时同步一轮。
extension View {
    func syncOnRefresh(_ sync: SyncModel) -> some View {
        refreshable { await sync.syncNow() }
    }
}
