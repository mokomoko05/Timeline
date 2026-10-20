import AppKit
import SwiftUI
import TimelineCore

/// 当天日志窗口里的内容（⌘J）：选中的那一天，按时间顺序列出所有日志，可以在里面写、改、删、关联待办、打标签、批量处理，右边是当天的复盘。
/// 它在独立窗口里，可以拖边缘调整大小；Esc、⌘J 或「完成」关闭。
struct DayLogView: View {
    @ObservedObject var store: JournalStore
    @ObservedObject var day: DayLogDay
    @ObservedObject private var themes = ThemeStore.shared
    @EnvironmentObject private var toast: ToastCenter
    let close: () -> Void
    let showMain: () -> Void

    init(store: JournalStore, day: DayLogDay, close: @escaping () -> Void, showMain: @escaping () -> Void = {}) {
        self.store = store
        self.day = day
        self.close = close
        self.showMain = showMain
    }

    /// 只显示一天、不做窗口的场景（测试、截图）。
    init(store: JournalStore, initialDate: Date, close: @escaping () -> Void, showMain: @escaping () -> Void = {}) {
        let day = DayLogDay()
        day.date = JournalDates.calendar.startOfDay(for: initialDate)
        self.init(store: store, day: day, close: close, showMain: showMain)
    }

    private var date: Date { day.date }
    private var isToday: Bool { JournalDates.calendar.isDateInToday(date) }

    private func shift(_ days: Int) {
        NotificationCenter.default.post(name: .timelineCommitEditing, object: nil)
        day.date = JournalDates.calendar.date(byAdding: .day, value: days, to: date) ?? date
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            DailyLogView(store: store, date: date, collapse: nil, autoFocus: true)
                .id(JournalDates.key(date))
        }
        .id(themes.themeID + themes.appearance.rawValue)
        .background(Palette.background)
        .frame(minWidth: DayLogWindowController.minSize.width, maxWidth: .infinity, minHeight: DayLogWindowController.minSize.height, maxHeight: .infinity)
        .overlay(alignment: .bottom) { ToastView(center: toast).padding(.bottom, 18) }
        // 在这个窗口里删了日志：撤销提示出现在这里（主窗口那边不再弹）。
        .onReceive(store.$lastAction.dropFirst()) { event in
            guard let event, DayLogWindowController.shared.isKey, let message = ToastCenter.undoMessages[event.name] else { return }
            toast.show(message, actionTitle: "撤销") { store.undo() }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "text.alignleft").foregroundStyle(Palette.accent)
            Text(date.formatted(.dateTime.year().month().day().weekday(.wide))).font(.system(size: 15, weight: .semibold))
            if isToday {
                Text("今天").font(.system(size: 11, weight: .medium)).padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Palette.soft, in: Capsule()).foregroundStyle(Palette.accent)
            } else {
                Button("回到今天") { shift(JournalDates.calendar.dateComponents([.day], from: date, to: JournalDates.calendar.startOfDay(for: Date())).day ?? 0) }
                    .buttonStyle(HitAreaButtonStyle(compact: true)).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.accent)
            }
            Text("\(store.entry(for: date).logs.count) 条").font(.system(size: 12)).foregroundStyle(Palette.muted)
            Spacer()
            Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(HitAreaButtonStyle()).foregroundStyle(Palette.muted).help("前一天").accessibilityLabel("前一天")
            Button { shift(1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(HitAreaButtonStyle()).foregroundStyle(Palette.muted).help("后一天").accessibilityLabel("后一天")
            Button("完成") { NotificationCenter.default.post(name: .timelineCommitEditing, object: nil); close() }
                .keyboardShortcut(.cancelAction).help("关闭 · Esc 或 ⌘J")
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
        .background(Palette.background)
        .foregroundStyle(Palette.ink)
    }
}
