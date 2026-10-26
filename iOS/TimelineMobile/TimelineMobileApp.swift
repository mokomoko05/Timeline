import CoreSpotlight
import SwiftUI
import TimelineCore

@main
struct TimelineMobileApp: App {
    @StateObject private var store: JournalStore
    @StateObject private var sync: SyncModel
    @StateObject private var focus: FocusTimer
    @StateObject private var reminders: ReminderScheduler
    @StateObject private var languages = LanguageStore()
    @StateObject private var quickEntry = QuickEntry.shared
    @UIApplicationDelegateAdaptor(QuickEntryAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let services = AppServices.shared
        _store = StateObject(wrappedValue: services.store)
        _sync = StateObject(wrappedValue: services.sync)
        _focus = StateObject(wrappedValue: services.focus)
        _reminders = StateObject(wrappedValue: services.reminders)
    }

    var body: some Scene {
        WindowGroup {
            RootView(store: store, sync: sync)
                .environmentObject(focus)
                .environmentObject(reminders)
                .environmentObject(quickEntry)
                .onOpenURL { quickEntry.open($0) }
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
                reminders.refresh()
            case .background:
                store.save()
                sync.setActive(false)
                BackgroundRefresh.schedule()
            default: break
            }
        }
        .backgroundTask(.appRefresh(BackgroundRefresh.identifier)) {
            await BackgroundRefresh.run(sync: AppServices.shared.sync, reminders: AppServices.shared.reminders)
        }
    }
}

/// 应用里只有一份的数据和服务。界面、快捷指令（App Intents）和后台刷新都从这里拿，
/// 快捷指令在后台把应用拉起来时也不会建出第二份数据。
@MainActor
final class AppServices {
    static let shared = AppServices()
    let store: JournalStore
    let sync: SyncModel
    let focus: FocusTimer
    let reminders: ReminderScheduler
    let spotlight: SpotlightIndexer

    private init() {
        let store = JournalStore()
        store.writesInBackground = true
        self.store = store
        sync = SyncModel(store: store)
        focus = FocusTimer(store: store)
        reminders = ReminderScheduler(store: store)
        spotlight = SpotlightIndexer(store: store)
        spotlight.start()
    }
}

struct RootView: View {
    @ObservedObject var store: JournalStore
    @ObservedObject var sync: SyncModel
    @EnvironmentObject private var focus: FocusTimer
    @SceneStorage("rootTab") private var tab = Tab.tasks
    @State private var showingSettings = false

    enum Tab: String { case tasks, journal, notes, boards, settings, search }

    var body: some View {
        tabs
        .tint(Palette.accent)
        .onContinueUserActivity(CSSearchableItemActionType) { Navigator.shared.open($0) }
        .onReceive(Navigator.shared.$target) { target in
            switch target {
            case .task: tab = .tasks
            case .log, .day: tab = .journal
            case .board: tab = .boards
            case nil: break
            }
        }
        .onReceive(QuickEntry.shared.$request) { kind in
            switch kind {
            case .log: tab = .journal
            case .task: tab = .tasks
            case nil: break
            }
        }
        .onAppear {
            QuickEntry.installHomeScreenActions()
            // 截图检查用：`-quickEntry log|task` 和点小组件一样直接进到输入框。
            if let kind = UserDefaults.standard.string(forKey: "quickEntry").flatMap(QuickEntry.Kind.init(rawValue:)) { QuickEntry.shared.request = kind }
            // 截图检查用：启动参数 `-startTab journal` 直接打开某个标签页。
            if let start = UserDefaults.standard.string(forKey: "startTab").flatMap(Tab.init(rawValue:)) { tab = start }
            else if !sync.isConfigured { tab = .settings }
            if #available(iOS 18.0, *), tab == .settings { tab = .tasks; showingSettings = true }
            PerfProbe.start()
            prewarmJournal()
            PerfProbe.runScript { tab = $0 }
            PerfProbe.runTyping { tab = $0 }
            PerfProbe.demoFocus(focus)
        }
    }
}

extension RootView {
    /// iOS 18 起搜索是标签栏里单独的一个（iOS 26 上是右边单独的圆钮）；更早的系统没有全局搜索标签。
    @ViewBuilder var tabs: some View {
        if #available(iOS 18.0, *) {
            TabView(selection: $tab) {
                SwiftUI.Tab("待办", systemImage: "checklist", value: Tab.tasks) { TasksView(store: store, sync: sync) }
                SwiftUI.Tab("日记", systemImage: "book", value: Tab.journal) { JournalView(store: store, sync: sync) }
                SwiftUI.Tab("笔记", systemImage: "text.bubble", value: Tab.notes) { NotesView(store: store, sync: sync) }
                SwiftUI.Tab("工作板", systemImage: "doc.text", value: Tab.boards) { BoardsView(store: store) }
                SwiftUI.Tab(value: Tab.search, role: .search) { GlobalSearchView(store: store) }
            }
            // 标签栏最多 5 格：设置收进待办页左上角的齿轮，腾出位置给搜索。
            .environment(\.openSettings, OpenSettingsAction { showingSettings = true })
            .sheet(isPresented: $showingSettings) { SyncSettingsView(store: store, sync: sync, presented: true) }
            .onChange(of: tab) { _, value in
                if value == .settings { tab = .tasks; showingSettings = true }
            }
        } else {
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
        }
    }

    /// 日记页第一次打开时要显示今天：今天和昨天的正文先在后台解析好。
    func prewarmJournal() {
        let calendar = JournalDates.calendar
        let keys = [Date(), calendar.date(byAdding: .day, value: -1, to: Date()) ?? Date()].map(JournalDates.key)
        let sources = store.allLogs(includeFocus: true).suffix(200).filter { keys.contains($0.key) }.map { LogStyle.body($0.log) }
        MarkdownBlock.prewarm(sources.filter { !$0.isEmpty })
    }
}

/// 打开设置：iOS 18 起设置不在标签栏里，待办页左上角的齿轮用它弹出设置。没有时（iOS 17）不显示齿轮。
struct OpenSettingsAction {
    let open: () -> Void
    func callAsFunction() { open() }
}

private struct OpenSettingsKey: EnvironmentKey {
    static let defaultValue: OpenSettingsAction? = nil
}

extension EnvironmentValues {
    var openSettings: OpenSettingsAction? {
        get { self[OpenSettingsKey.self] }
        set { self[OpenSettingsKey.self] = newValue }
    }
}

/// 下拉刷新时同步一轮。
extension View {
    func syncOnRefresh(_ sync: SyncModel) -> some View {
        refreshable { await sync.syncNow() }
    }
}
