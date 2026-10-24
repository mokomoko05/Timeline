import AppKit
import SwiftUI
import TimelineCore

/// 带搜索的「关联待办」选择面板：待办多的时候不再是一长串菜单。
/// 输入标题、编号（`3` 或 `#3`）或 `#标签` 筛选；↑ ↓ 选择，回车确认；专注中的、最近关联过的排在最前。
struct LinkPickerView: View {
    @ObservedObject var store: JournalStore
    /// 当前已经关联的待办（打勾显示）。
    var current: UUID?
    /// 显示「不关联任务」。
    var allowsNone = true
    /// 正在写的标签等：带这些标签的待办排在前面。
    var contextTags: [String] = []
    let pick: (UUID?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var showCompleted = false
    @State private var selection = 0
    @FocusState private var searching: Bool

    private var results: [ScheduledTask] { store.linkCandidates(query: query, includeCompleted: showCompleted, contextTags: contextTags) }

    var body: some View {
        let list = results
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Palette.muted)
                TextField("搜索标题、编号、#标签或拼音", text: $query).textFieldStyle(.plain).focused($searching)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(Palette.muted).accessibilityLabel("清除搜索词")
                }
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 7))
            if allowsNone {
                Button { pick(nil); dismiss() } label: {
                    Label("不关联任务", systemImage: current == nil ? "checkmark" : "xmark.circle").font(.system(size: 12))
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(Palette.muted).raisedOnHover(radius: 6)
            }
            if list.isEmpty {
                Text(query.isEmpty ? AppLocalized("没有未完成的待办") : AppLocalizedFormat("没有匹配「%@」的待办", query)).font(.caption).foregroundStyle(Palette.muted)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(list.enumerated()), id: \.element.id) { index, item in
                                row(item, highlighted: index == selection).id(item.id)
                            }
                        }.padding(3)
                    }
                    .frame(height: min(CGFloat(list.count) * 46 + 4, 300))
                    .onChange(of: selection) { index in if list.indices.contains(index) { proxy.scrollTo(list[index].id) } }
                }
            }
            HStack {
                Toggle("显示已完成", isOn: $showCompleted).toggleStyle(.checkbox).font(.caption)
                Spacer()
                Text("↑ ↓ 选择 · 回车确认").font(.caption).foregroundStyle(Palette.muted)
            }
        }
        .padding(14).frame(width: 380)
        .background(SearchKeyCatcher(move: { amount in
            let count = results.count
            guard count > 0 else { return }
            selection = min(max(selection + amount, 0), count - 1)
        }, activate: {
            let items = results
            guard items.indices.contains(selection) else { return }
            pick(items[selection].id)
            dismiss()
        }))
        .onAppear { searching = true }
        .onChange(of: query) { _ in selection = 0 }
        .onChange(of: showCompleted) { _ in selection = 0 }
    }

    private func row(_ item: ScheduledTask, highlighted: Bool) -> some View {
        Button { pick(item.id); dismiss() } label: {
            HStack(alignment: .top, spacing: 8) {
                Text(item.task.number.map { "#\($0)" } ?? "").font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Palette.muted).frame(width: 34, alignment: .leading).padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(String(TaskText.rendered(item.task.title, alias: item.task.calendarName).characters))
                            .font(.system(size: 13)).lineLimit(1)
                        if item.id == store.focusTaskID { Image(systemName: "timer").foregroundStyle(Palette.success).font(.system(size: 10)) }
                        if item.id == store.pinnedTask?.id { Image(systemName: "pin.fill").foregroundStyle(Palette.accent).font(.system(size: 10)) }
                        if item.task.isDropped { Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.muted).font(.system(size: 10)) } else if item.task.completed { Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.success).font(.system(size: 10)) }
                    }
                    HStack(spacing: 6) {
                        if let due = item.task.dueDate { Text(AppLocalized("截止 ") + due.relativeLabel) }
                        ForEach(item.task.tags, id: \.self) { Text("#" + $0).foregroundStyle(Palette.accent) }
                    }.font(.system(size: 10)).foregroundStyle(Palette.muted).lineLimit(1)
                }
                Spacer(minLength: 0)
                if item.id == current { Image(systemName: "checkmark").foregroundStyle(Palette.accent) }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(highlighted ? Palette.soft : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .raisedOnHover(radius: 6)
        .accessibilityLabel((item.task.number.map { "#\($0) " } ?? "") + item.task.title)
    }
}

/// 一个会弹出 `LinkPickerView` 的按钮外壳。
struct LinkPickerButton<Label: View>: View {
    @ObservedObject var store: JournalStore
    var current: UUID?
    var allowsNone = true
    var contextTags: [String] = []
    let pick: (UUID?) -> Void
    @ViewBuilder let label: () -> Label
    @State private var showing = false

    var body: some View {
        Button { showing = true } label: { label() }
            .buttonStyle(.plain)
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                LinkPickerView(store: store, current: current, allowsNone: allowsNone, contextTags: contextTags, pick: pick)
            }
    }
}

/// 一条要写的日志会关联到哪个待办、带哪些标签：永远只占固定的一行（放不下就横向滚动），所以选了什么都不会让窗口变高。
/// 点 `@` / `#` 打开浮窗，也可在输入框中补全；选中的结果可以点 × 去掉。
/// 关联的优先级：明确选的 > 专注中的 > 固定的；选定的待办可以一键「固定」，之后的日志默认都记到它名下，不计时。
struct LogChipsBar: View {
    @Environment(\.typography) private var typography
    @ObservedObject var store: JournalStore
    @Binding var link: UUID?
    @Binding var unlinked: Bool
    @Binding var tags: [String]
    var contextTags: [String] = []
    /// 这个输入框能不能选待办（任务页里日志固定属于这个任务，不能）。
    var showsLink = true
    /// 什么都没选时显示的提示。
    var hint = ""
    var size: CGFloat = 11
    static let height: CGFloat = 22

    private var explicit: ScheduledTask? { link.flatMap(store.locate) }

    private func choose(_ id: UUID?) {
        if let id { link = id; unlinked = false } else { link = nil; unlinked = store.defaultLinkTask != nil }
    }

    private var hasChips: Bool {
        !tags.isEmpty || (showsLink && (explicit != nil || unlinked || store.defaultLinkTask != nil))
    }

    var body: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    if showsLink { linkChips }
                    ForEach(tags, id: \.self) { tag in tagChip(tag) }
                    if !hasChips, !hint.isEmpty {
                        Text(LocalizedStringKey(hint)).font(.system(size: typography.pt(size))).foregroundStyle(Palette.muted).lineLimit(1)
                    }
                }
                .padding(.vertical, 1)
            }
            if showsLink {
                LinkPickerButton(store: store, current: explicit?.id, contextTags: contextTags, pick: choose) {
                    MetadataSymbol(symbol: "@", active: explicit != nil)
                }
                .raisedOnHover(radius: 5)
                .foregroundStyle(Palette.muted).help("选择关联的待办")
                .accessibilityLabel("选择关联的待办")
            }
            TagSelectionButton(store: store, tags: $tags)
        }
        .frame(height: Self.height)
        .disabled(store.isReadOnly)
    }

    @ViewBuilder
    private var linkChips: some View {
        if let task = explicit {
            pill("link", FocusHint.label(task), tint: Palette.accent)
            let pinned = store.pinnedTask?.id == task.id
            small(pinned ? "pin.fill" : "pin", pinned ? "取消固定" : "固定为当前待办：之后的日志默认都记到它名下（不计时），再点一次取消",
                  tint: pinned ? Palette.accent : Palette.muted) { store.pinTask(pinned ? nil : task.id) }
            small("xmark", "取消这次的关联") { link = nil }
        } else if unlinked {
            pill("link.badge.plus", "这条不关联待办", tint: Palette.muted)
            small("arrow.uturn.backward", "恢复自动关联") { unlinked = false }
        } else if let focus = store.focusTask, !store.focusPaused {
            pill("timer", AppLocalized("专注中 ") + FocusHint.label(focus), tint: Palette.success)
            small("xmark", "这条不关联") { unlinked = true }
        } else if let pinned = store.pinnedTask {
            pill("pin.fill", AppLocalized("固定 ") + FocusHint.label(pinned), tint: Palette.accent)
            small("pin.slash", "取消固定") { store.pinTask(nil) }
            small("xmark", "这条不关联") { unlinked = true }
        }
    }

    private func tagChip(_ tag: String) -> some View {
        Button { tags.removeAll { TagText.key($0) == TagText.key(tag) } } label: {
            HStack(spacing: 3) {
                Text("#" + tag).lineLimit(1)
                Image(systemName: "xmark").font(.system(size: typography.pt(8), weight: .semibold))
            }
            .font(.system(size: typography.pt(size)))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .foregroundStyle(Palette.onAccent)
            .background(Palette.accent, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain).help("去掉标签 #\(tag)").accessibilityLabel("标签 #\(tag)，点按去掉")
    }

    private func pill(_ symbol: String, _ text: String, tint: Color) -> some View {
        Label(text, systemImage: symbol).font(.system(size: typography.pt(size))).lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .foregroundStyle(tint)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
    }

    private func small(_ symbol: String, _ help: String, tint: Color = Palette.muted, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: typography.pt(size))).frame(width: 20, height: 20).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(tint).help(help).accessibilityLabel(help)
    }
}

enum LogClipboard {
    /// 复制日志文字（只有文字，图片不算）。返回复制了几条；没有可复制的文字返回 0。
    @MainActor
    @discardableResult
    static func copy(store: JournalStore, ids: Set<UUID>) -> Int {
        guard let text = store.copyText(forLogs: ids) else { return 0 }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        return store.allLogs(includeFocus: true).filter { ids.contains($0.log.id) && $0.log.copyText != nil }.count
    }
}
