import AppKit
import SwiftUI
import UniformTypeIdentifiers
import TimelineCore

/// 日志界面的颜色：和笔记窗口一样跟随当前配色（不再是固定的黑底）。
enum TerminalPalette {
    static var panel: Color { Palette.background }
    static var surface: Color { Palette.card }
    static var text: Color { Palette.ink }
    static var muted: Color { Palette.muted }
    static var green: Color { Palette.success }
    static var amber: Color { Palette.deadline }
    static var blue: Color { Palette.accent }
}

@MainActor
enum LogTaskLabel {
    static func current(_ task: ScheduledTask, store: JournalStore, logDate: Date) -> String {
        let number = task.task.number.map { "#\($0)" } ?? "任务"
        let title = String(TaskText.rendered(task.task.title, alias: task.task.calendarName).characters)
        return "\(number) \(title)"
    }

    static func saved(_ log: DailyLogEntry, store: JournalStore, logDate: Date) -> String? {
        if let id = log.taskID, let task = store.locate(id) { return current(task, store: store, logDate: logDate) }
        guard let title = log.taskTitle else { return nil }
        let number = log.taskNumber.map { "#\($0) " } ?? ""
        return number + AppLocalizedFormat("%@（已删除）", title)
    }
}

struct DailyLogView: View {
    @Environment(\.typography) private var typography
    @ObservedObject var store: JournalStore
    let date: Date
    var collapse: (() -> Void)?
    /// 出现时光标直接进输入框（在 sheet 里用）。
    var autoFocus = false
    @EnvironmentObject private var interaction: WorkspaceInteraction
    @EnvironmentObject private var toast: ToastCenter
    @AppStorage("logReviewSplit") private var split = 0.6
    @State private var showingHelp = false
    @State private var preparingReview = false
    @State private var focused = false
    @State private var unlinked = false
    @State private var error: String?
    @StateObject private var mention = MentionState()
    @State private var historyIndex: Int?
    @State private var pendingDraft = ""
    @State private var pendingTaskID: UUID?
    @State private var editingLogID: UUID?
    @State private var editingLogDate = Date()
    @State private var showingFilter = false
    @State private var editText = ""
    @State private var dropTargeted = false
    @State private var selectedLogs: Set<UUID> = []
    @State private var showingBatchTags = false
    /// 输入只刷新这个视图，停顿后才写回仓库（其他窗口不随按键重绘）。
    @StateObject private var logDraft: LogDraftBuffer

    init(store: JournalStore, date: Date, collapse: (() -> Void)? = nil, autoFocus: Bool = false) {
        self.store = store
        self.date = date
        self.collapse = collapse
        self.autoFocus = autoFocus
        _logDraft = StateObject(wrappedValue: LogDraftBuffer(store: store, date: date))
    }

    private var entry: DayEntry { store.entry(for: date) }
    private var draft: Binding<String> {
        Binding(get: { logDraft.text }, set: {
            if historyIndex != nil { historyIndex = nil }
            if error != nil { error = nil }
            logDraft.update($0)
        })
    }
    private var completions: [String] {
        let text = logDraft.text.lowercased()
        guard focused, text.hasPrefix("/"), !text.contains(where: \.isWhitespace) else { return [] }
        return LogCommand.commands.filter { $0.hasPrefix(text) }
    }

    var body: some View {
        GeometryReader { geometry in
            let total = geometry.size.width
            let left = min(max(total * split, 300), max(300, total - 240))
            HStack(spacing: 0) {
                logColumn.padding(.leading, 16).padding(.trailing, 6).padding(.bottom, 12).frame(width: left)
                divider(total: total)
                reviewColumn.frame(maxWidth: .infinity)
            }
            .coordinateSpace(name: "logSplit")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(TerminalPalette.text)
        .tint(TerminalPalette.blue)
        .background(TerminalPalette.panel)
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { interaction.activePane = .summary })
        .onChange(of: interaction.logFocusRequest) { _ in focused = true }
        .onAppear { if autoFocus { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { focused = true } } }
        .onChange(of: date) { value in selectedLogs = []; logDraft.attach(store: store, date: value) }
        .onDisappear { logDraft.flush() }
        .onChange(of: interaction.logFilter) { _ in selectedLogs = [] }
        .sheet(isPresented: $preparingReview) {
            ReviewDraftView(store: store, date: date)
        }
    }

    /// 左侧：日志流与输入。
    private var logColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "terminal").foregroundStyle(TerminalPalette.green)
                Text("\(filtering ? filteredLogs.count : entry.logs.count)").font(.system(size: typography.pt(11), design: .monospaced)).foregroundStyle(TerminalPalette.muted)
                Spacer(minLength: 4)
                Button { showingFilter = true } label: {
                    Image(systemName: filtering ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                        .foregroundStyle(filtering ? TerminalPalette.blue : TerminalPalette.text)
                }
                .buttonStyle(HitAreaButtonStyle(compact: true)).help("按任务筛选日志")
                .accessibilityLabel("按任务筛选日志")
                .popover(isPresented: $showingFilter) {
                    LogFilterPopover(store: store, date: date, selection: $interaction.logFilter)
                }
                Button { showingHelp = true } label: { Image(systemName: "questionmark") }
                    .buttonStyle(HitAreaButtonStyle(compact: true)).help("日志命令")
                    .popover(isPresented: $showingHelp) { commandHelp }
            }
            if filtering { filterBar }
            stream
            if !validSelection.isEmpty { batchBar }
            input
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 8).strokeBorder(TerminalPalette.blue, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .background(TerminalPalette.blue.opacity(0.08)).allowsHitTesting(false)
                    .overlay(Text("松开以添加图片").foregroundStyle(TerminalPalette.blue))
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { providers in
            guard !store.isReadOnly else { return false }
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, ImageTools.isImageFile(url), let data = try? Data(contentsOf: url) else { return }
                    Task { @MainActor in addImages([data]) }
                }
            }
            return true
        }
    }

    private func addImages(_ datas: [Data]) {
        guard !store.isReadOnly else { return }
        for name in ImageTools.save(datas, in: store) { store.addDraftImage(name, on: date) }
        focused = true
    }

    private var editingLog: DailyLogEntry? { editingLogID.flatMap { id in store.entry(for: editingLogDate).logs.first { $0.id == id } } }

    /// 右侧：每日复盘，常驻显示，单击即可编辑。点日志行的铅笔时，临时变成这条日志的编辑框。
    private var reviewColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if let log = editingLog {
                    Image(systemName: "pencil").foregroundStyle(TerminalPalette.blue)
                    Text("编辑记录").font(.system(size: typography.pt(12), weight: .semibold))
                    Text(Self.time(log.createdAt)).font(.system(size: typography.pt(11), design: .monospaced)).foregroundStyle(TerminalPalette.muted)
                    Spacer(minLength: 4)
                    Button("取消") { cancelLogEdit() }
                        .buttonStyle(HitAreaButtonStyle(compact: true)).font(.system(size: typography.pt(12)))
                        .help("取消编辑 · Esc")
                } else {
                    Image(systemName: "doc.text").foregroundStyle(TerminalPalette.amber)
                    Text("复盘").font(.system(size: typography.pt(12), weight: .semibold))
                    Spacer(minLength: 4)
                    Button { openReview() } label: { Image(systemName: "text.badge.plus") }
                        .buttonStyle(HitAreaButtonStyle(compact: true)).help("整理复盘草稿")
                        .accessibilityLabel("整理复盘草稿")
                }
                if let collapse {
                    Button(action: collapse) { Image(systemName: "chevron.down") }
                        .buttonStyle(HitAreaButtonStyle()).help("关闭 · ⌘J").accessibilityLabel("关闭当天日志")
                }
            }
            if let log = editingLog {
                taskPicker(for: log)
                LogTextEditor(text: $editText, commit: saveLogEdit, cancel: cancelLogEdit)
                    .id(log.id)
                    .padding(.horizontal, 4)
                    .background(TerminalPalette.surface)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(TerminalPalette.blue.opacity(0.6)))
                    .accessibilityLabel("编辑日志文字")
                Text("⌘Enter 保存 · Esc 取消").font(.system(size: typography.pt(11))).foregroundStyle(TerminalPalette.muted)
            } else {
                SummaryEditor(text: Binding(get: { entry.summary }, set: { store.setSummary($0, on: date) }), readOnly: store.isReadOnly)
                    .padding(.horizontal, 4)
                    .background(TerminalPalette.surface)
                    .overlay(alignment: .topLeading) {
                        if entry.summary.isEmpty {
                            Text("写下复盘…")
                                .font(.system(size: typography.pt(12))).foregroundStyle(TerminalPalette.muted)
                                .padding(10).allowsHitTesting(false)
                        }
                    }
                    .accessibilityLabel("每日复盘，包含原有总结")
            }
        }
        .padding(.leading, 10).padding(.trailing, 16).padding(.bottom, 12)
    }

    /// 给这条日志（包括历史日志）选择或更换关联的任务。
    private func taskPicker(for log: DailyLogEntry) -> some View {
        let logDate = editingLogDate
        return LinkPickerButton(store: store, current: log.taskID, pick: { store.setLogTask($0, forLog: log.id, on: logDate) }) {
            Label(LogTaskLabel.saved(log, store: store, logDate: logDate).map { "关联：" + $0 } ?? "关联任务…", systemImage: "link")
                .font(.system(size: typography.pt(11))).lineLimit(1)
                .foregroundStyle(log.taskID == nil ? TerminalPalette.muted : TerminalPalette.blue)
        }
        .fixedSize()
        .help("关联任务")
    }

    private static func time(_ date: Date) -> String {
        let parts = JournalDates.calendar.dateComponents([.hour, .minute, .second], from: date)
        return String(format: "[%02d:%02d:%02d]", parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
    }

    private func beginLogEdit(_ log: DailyLogEntry, on logDate: Date) {
        guard !store.isReadOnly else { return }
        // 不能在这里广播「提交编辑」：复盘区自己也监听它，会把刚打开的编辑框立刻保存并关闭。
        guard editingLogID == nil else { return }
        interaction.activePane = .summary
        editText = log.text
        editingLogDate = logDate
        editingLogID = log.id
    }

    private func saveLogEdit() {
        guard let id = editingLogID else { return }
        editingLogID = nil
        store.updateLog(id, text: editText, on: editingLogDate)
        focused = true
    }

    private func cancelLogEdit() {
        editingLogID = nil
        focused = true
    }

    private func divider(total: CGFloat) -> some View {
        Rectangle().fill(Palette.line).frame(width: 1)
            .frame(width: 9).contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("logSplit")).onChanged { value in
                split = min(max(value.location.x / max(total, 1), 0.3), 0.8)
            })
            .help("拖动调整日志与复盘的宽度")
            .accessibilityLabel("日志与复盘分隔线")
    }

    private var filtering: Bool { !interaction.logFilter.isEmpty }

    // MARK: - 多选

    /// 当前列表里能选的日志（筛选模式是跨日期的）。
    private var visibleLogIDs: [UUID] { filtering ? filteredLogs.map(\.log.id) : entry.logs.map(\.id) }

    /// 只保留还在当前列表里的选中项（切换日期、筛选、删除后自动去掉）。
    private var validSelection: Set<UUID> { selectedLogs.intersection(visibleLogIDs) }

    private func copyLogs(_ ids: Set<UUID>) {
        let copied = LogClipboard.copy(store: store, ids: ids)
        toast.show(copied == 0 ? "没有可复制的文字（只有图片）" : AppLocalizedFormat("已复制 %lld 条日志", copied))
    }

    /// 批量删除：一次操作，⌘Z 整批恢复；删完清掉选择。
    private func deleteSelected(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        NotificationCenter.default.post(name: .timelineCommitEditing, object: nil)
        let count = store.deleteLogs(ids)
        selectedLogs = []
        if count > 0 { toast.show(AppLocalizedFormat("已删除 %lld 条日志", count), actionTitle: "撤销") { store.undo() } }
    }

    private func selectionState(_ id: UUID) -> LogSelection {
        LogSelection(selected: selectedLogs.contains(id), toggle: {
            if selectedLogs.contains(id) { selectedLogs.remove(id) } else { selectedLogs.insert(id) }
        }, anySelected: !validSelection.isEmpty)
    }

    private var batchBar: some View {
        let ids = validSelection
        let all = visibleLogIDs
        return HStack(spacing: 8) {
            Text("已选 \(ids.count) / \(all.count) 条").font(.system(size: typography.pt(11), design: .monospaced)).foregroundStyle(TerminalPalette.muted)
            Button(ids.count == all.count && !all.isEmpty ? "全不选" : "全选") {
                selectedLogs = ids.count == all.count ? [] : Set(all)
            }
            .buttonStyle(HitAreaButtonStyle(compact: true)).font(.system(size: typography.pt(11)))
            Spacer(minLength: 4)
            Button { copyLogs(ids) } label: { Label("复制", systemImage: "doc.on.doc") }
                .buttonStyle(HitAreaButtonStyle(compact: true)).font(.system(size: typography.pt(12)))
                .disabled(ids.isEmpty).help("复制文字")
            Button { showingBatchTags = true } label: { Label("加标签", systemImage: "tag") }
                .buttonStyle(HitAreaButtonStyle(compact: true)).font(.system(size: typography.pt(12)))
                .disabled(ids.isEmpty || store.isReadOnly)
                .popover(isPresented: $showingBatchTags) { LogBatchTagView(store: store, logIDs: ids) }
            LinkPickerButton(store: store, pick: { store.setLogTask($0, forLogs: ids) }) {
                Label("关联待办", systemImage: "link").font(.system(size: typography.pt(12))).padding(.horizontal, 5).frame(height: 26).contentShape(Rectangle())
            }
            .fixedSize().disabled(ids.isEmpty || store.isReadOnly)
            Button(role: .destructive) { deleteSelected(ids) } label: { Label("删除", systemImage: "trash") }
                .buttonStyle(HitAreaButtonStyle(compact: true)).font(.system(size: typography.pt(12)))
                .foregroundStyle(TerminalPalette.amber)
                .disabled(ids.isEmpty || store.isReadOnly).help("删除所选日志 · ⌘Z 整批撤销")
            Button("取消选择") { selectedLogs = [] }
                .buttonStyle(HitAreaButtonStyle(compact: true)).font(.system(size: typography.pt(12), weight: .semibold))
                .foregroundStyle(TerminalPalette.blue)
        }
        .padding(.horizontal, 6).frame(minHeight: 30)
        .background(TerminalPalette.surface, in: RoundedRectangle(cornerRadius: 6))
    }
    private var filteredLogs: [JournalStore.LoggedLog] { store.logs(linkedTo: interaction.logFilter) }

    /// 筛选条：显示当前筛选的任务，可逐个移除或清除。
    private var filterBar: some View {
        let summaries = store.logTaskSummaries(on: date).filter { interaction.logFilter.contains($0.id) }
        return HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease.circle.fill").foregroundStyle(TerminalPalette.blue)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(summaries) { task in
                        Button { interaction.logFilter.remove(task.id) } label: {
                            HStack(spacing: 4) {
                                Text(task.number.map { "#\($0) " } ?? "").foregroundStyle(TerminalPalette.blue)
                                Text(task.title).lineLimit(1)
                                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                            }
                            .font(.system(size: typography.pt(11)))
                            .padding(.horizontal, 7).frame(height: 22)
                            .background(TerminalPalette.blue.opacity(0.16), in: Capsule())
                        }
                        .buttonStyle(.plain).help("移除这个筛选条件").accessibilityLabel(AppLocalizedFormat("移除筛选：%@", task.title))
                    }
                }
            }
            Spacer(minLength: 0)
            Button("清除筛选") { interaction.logFilter = [] }
                .buttonStyle(HitAreaButtonStyle(compact: true)).font(.system(size: typography.pt(11))).foregroundStyle(TerminalPalette.blue)
        }
    }

    @ViewBuilder
    private var stream: some View {
        if filtering { filteredStream } else { dayStream }
    }

    /// 筛选模式：跨日期显示所选任务相关的全部日志，按日期分组。
    private var filteredStream: some View {
        let logs = filteredLogs
        let segments = store.timelineSegments()
        let groups = Dictionary(grouping: logs, by: \.key).sorted { $0.key < $1.key }
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if logs.isEmpty {
                    Text("没有匹配的日志")
                        .font(.system(size: typography.pt(12))).foregroundStyle(TerminalPalette.muted).padding(10)
                }
                ForEach(groups, id: \.key) { group in
                    Text("── \(group.key) ──").font(.system(size: typography.pt(11), design: .monospaced))
                        .foregroundStyle(TerminalPalette.muted).padding(.top, 8).padding(.bottom, 2)
                    ForEach(Array(group.value.enumerated()), id: \.element.id) { index, item in
                        DailyLogRow(store: store, date: item.date, log: item.log, hasPrevious: index > 0, hasNext: index < group.value.count - 1, segment: segments[item.id], highlighted: editingLogID == item.log.id, next: { focused = true },
                                    selection: selectionState(item.log.id), copy: { copyLogs([$0.id]) },
                                    edit: { beginLogEdit($0, on: $1) },
                                    preview: { ImageViewerController.shared.openPreview(store: store, around: item.log, index: $0) })
                    }
                }
            }.padding(.horizontal, 4).padding(.vertical, 5)
        }
        .background(TerminalPalette.surface)
    }

    private var dayStream: some View {
        let segments = store.timelineSegments()
        return GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        let logs = entry.logsInTimeOrder
                        ForEach(Array(logs.enumerated()), id: \.element.id) { index, log in
                            DailyLogRow(store: store, date: date, log: log, hasPrevious: index > 0, hasNext: index < logs.count - 1, segment: segments[log.id], highlighted: editingLogID == log.id, next: { focused = true },
                                        selection: selectionState(log.id), copy: { copyLogs([$0.id]) },
                                        edit: { beginLogEdit($0, on: $1) },
                                    preview: { ImageViewerController.shared.openPreview(store: store, around: log, index: $0) })
                        }
                        Color.clear.frame(height: 1).id("tail")
                    }
                    .padding(.horizontal, 4).padding(.vertical, 5)
                    // 内容比窗口短时顶对齐，不会被滚到下面留出一片空白。
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .topLeading)
                    .contentShape(Rectangle())
                }
                .background(TerminalPalette.surface)
                .overlay(alignment: .bottomTrailing) {
                    GoToBottomButton { proxy.scrollTo("tail", anchor: .bottom) }
                        .padding(10).disabled(entry.logs.isEmpty)
                }
                // 打开时不滚动，停在顶部。只有自己刚写了一条新日志时，才跟到那一条。
                .onChange(of: entry.logs.count) { [count = entry.logs.count] new in
                    if focused, new > count { proxy.scrollTo("tail", anchor: .bottom) }
                }
            }
        }
    }

    private var input: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let error { Text(error).font(.system(size: typography.pt(10), design: .monospaced)).foregroundStyle(TerminalPalette.amber) }
            if !completions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(completions, id: \.self) { command in
                            Button(command) { logDraft.set(command + " "); focused = true }
                                .font(.system(size: typography.pt(10), design: .monospaced)).buttonStyle(HitAreaButtonStyle(compact: true))
                        }
                    }
                }
            }
            if !entry.logDraftImages.isEmpty {
                PendingImagesStrip(store: store, names: entry.logDraftImages,
                                   remove: { store.removeDraftImage($0, on: date) },
                                   preview: { ImageViewerController.shared.openPreview(store: store, names: entry.logDraftImages, index: $0) })
            }
            if let selected = entry.logTaskID {
                HStack(spacing: 4) {
                    Image(systemName: "link")
                    Text(store.locate(selected).map { "关联：" + LogTaskLabel.current($0, store: store, logDate: date) } ?? "关联任务已删除，请重新选择")
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Button { store.setLogTask(nil, on: date) } label: { Image(systemName: "xmark") }
                        .buttonStyle(HitAreaButtonStyle(compact: true)).disabled(store.isReadOnly)
                }.font(.system(size: typography.pt(10))).foregroundStyle(TerminalPalette.muted)
            }
            if !unlinked, entry.logTaskID == nil, let task = store.focusTask, !store.focusPaused {
                HStack(spacing: 4) {
                    Image(systemName: "timer")
                    Text("专注中：日志会关联到 \(FocusHint.label(task))").lineLimit(1)
                    Spacer(minLength: 0)
                }.font(.system(size: typography.pt(10))).foregroundStyle(TerminalPalette.green)
            }
            if entry.logTaskID == nil, let task = store.focusTask, store.focusPaused {
                HStack(spacing: 4) {
                    Image(systemName: "pause.circle")
                    Text("专注已暂停：日志不会关联到 \(FocusHint.label(task))")
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }.font(.system(size: typography.pt(10))).foregroundStyle(TerminalPalette.muted)
            }
            if !unlinked, entry.logTaskID == nil, store.focusTask == nil, let task = store.pinnedTask {
                HStack(spacing: 4) {
                    Image(systemName: "pin.fill")
                    Text("固定关联：日志会记到 \(FocusHint.label(task))").lineLimit(1)
                    Spacer(minLength: 0)
                    Button("取消固定") { store.pinTask(nil) }.buttonStyle(.plain).foregroundStyle(Palette.accent)
                }.font(.system(size: typography.pt(10))).foregroundStyle(TerminalPalette.muted)
            }
            LogChipsBar(store: store, link: Binding(get: { entry.logTaskID }, set: { store.setLogTask($0, on: date) }), unlinked: $unlinked,
                        tags: Binding(get: { entry.logDraftTags }, set: { new in
                            for tag in entry.logDraftTags where !new.contains(tag) { store.removeDraftTag(tag, on: date) }
                            for tag in new { store.addDraftTag(tag, on: date) }
                        }))
            HStack(spacing: 5) {
                Text("❯").font(.system(size: typography.pt(15), weight: .semibold, design: .monospaced))
                    .foregroundStyle(TerminalPalette.green)
                TaskInput(text: draft, focused: $focused, placeholder: "记录…  @ 待办 · # 标签", fontSize: 12, submit: submit,
                          monospaced: true, historyUp: historyUp, historyDown: historyDown, complete: completeCommand,
                          onPasteImages: addImages, minHeight: 24, maxLines: 10, mention: mention, returnSubmits: true)
                    .disabled(store.isReadOnly)
                    .accessibilityLabel("日志命令输入，回车提交，Shift+回车换行")
                    .onChange(of: focused) { if $0 { interaction.activePane = .summary } else { logDraft.flush() } }
                Button(action: submit) { Image(systemName: "arrow.turn.down.left") }
                    .buttonStyle(HitAreaButtonStyle(compact: true)).help("提交日志")
                    .disabled(store.isReadOnly || (logDraft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && entry.logDraftImages.isEmpty))
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(TerminalPalette.surface)
            .popover(isPresented: Binding(get: { mention.isActive }, set: { if !$0 { mention.dismiss() } }), arrowEdge: .bottom) {
                MentionList(state: mention, store: store).frame(width: 340)
            }
        }
        .onAppear(perform: configureMention)
        .onChange(of: date) { _ in unlinked = false; configureMention() }
    }

    /// 输入框里的 `@`：选中的待办成为下一条日志的关联（和「关联任务」按钮一样）。
    private func configureMention() {
        let store = store, date = date
        mention.triggers = [.task, .tag]
        mention.provider = MentionProviders.make(store: store, chosenTags: { store.entry(for: date).logDraftTags })
        mention.onPick = { item in
            switch item {
            case .task(let task): store.setLogTask(task.id, on: date); unlinked = false
            case .tag(let tag): store.addDraftTag(tag.name, on: date)
            }
        }
    }

    private var commandHelp: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("日志命令").font(.headline)
            ForEach(DailyLogKind.allCases) { kind in
                HStack {
                    Text("/\(kind.rawValue)").font(.system(size: typography.pt(12), design: .monospaced)).frame(width: 84, alignment: .leading)
                    Text(LocalizedStringKey(kind.title))
                }
            }
            Text("/link #1   关联任务 #1（之后的日志都记在它名下）\n/unlink    取消关联\n/filter #1 #3  只看这些任务的日志\n/filter    清除筛选\n/summary   整理复盘\n/help      显示命令")
                .font(.system(size: typography.pt(12), design: .monospaced))
            Text("普通文字直接记录。↑ ↓ 调取历史，Tab 补全命令。\n#编号是任务的永久编号（显示在任务行左边）。命令里可直接写：/done #1 完成了方法部分，或 #2 卡在配置，只关联这一条。\n/done 关联任务后同时勾选完成。")
                .font(.caption).foregroundStyle(Palette.muted)
        }.padding(18)
    }

    private func submit() {
        guard !store.isReadOnly, !logDraft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !entry.logDraftImages.isEmpty else { return }
        logDraft.flush()
        do {
            let command = try store.commitLog(on: date, linkDefault: !unlinked)
            error = nil
            historyIndex = nil
            switch command {
            case .entry:
                unlinked = false
                focused = true
                ImageIndexer.run(store: store)
            case .help: logDraft.set(""); showingHelp = true
            case .summary: logDraft.set(""); openReview()
            case .link: focused = true
            case .filter(let numbers): applyFilter(numbers)
            }
        } catch { self.error = error.localizedDescription }
    }

    /// `/filter #1 #3` 按任务编号筛选；`/filter` 清除。
    private func applyFilter(_ numbers: [Int]) {
        let located = numbers.map { ($0, store.locate(number: $0)) }
        if let missing = located.first(where: { $0.1 == nil }) {
            error = LogInputError.unknownTask(missing.0).localizedDescription
            return
        }
        logDraft.set("")
        interaction.logFilter = Set(located.compactMap { $0.1?.id })
        focused = true
    }

    private func openReview() {
        NotificationCenter.default.post(name: .timelineCommitEditing, object: nil)
        interaction.activePane = .summary
        preparingReview = true
    }

    private func completeCommand() {
        if let command = completions.first { logDraft.set(command + " ") }
    }

    private func historyUp() {
        guard !entry.logs.isEmpty else { return }
        if historyIndex == nil { pendingDraft = logDraft.text; pendingTaskID = entry.logTaskID }
        let index = max(0, min((historyIndex ?? entry.logs.count) - 1, entry.logs.count - 1))
        historyIndex = index
        recall(entry.logs[index])
    }

    private func historyDown() {
        guard let index = historyIndex else { return }
        if index + 1 < entry.logs.count {
            historyIndex = index + 1
            recall(entry.logs[index + 1])
        } else {
            historyIndex = nil
            logDraft.set(pendingDraft)
            store.setLogTask(pendingTaskID, on: date)
        }
    }

    private func recall(_ log: DailyLogEntry) {
        logDraft.set(log.command)
        store.setLogTask(log.taskID.flatMap { store.locate($0)?.id }, on: date)
    }
}

struct LogSelection {
    let selected: Bool
    let toggle: () -> Void
    /// 列表里已经有选中的日志：这时每一行的选择圈常驻显示，方便继续点选。
    var anySelected = false
}

private struct DailyLogRow: View {
    @Environment(\.typography) private var typography
    @ObservedObject var store: JournalStore
    let date: Date
    let log: DailyLogEntry
    let hasPrevious: Bool
    let hasNext: Bool
    let segment: LogTimelineSegment?
    let highlighted: Bool
    let next: () -> Void
    /// 这条是否被选中，以及点击右侧选择按钮时切换。
    let selection: LogSelection
    let copy: (DailyLogEntry) -> Void
    let edit: (DailyLogEntry, Date) -> Void
    let preview: (Int) -> Void
    @State private var expanded = false
    @EnvironmentObject private var interaction: WorkspaceInteraction
    /// 这条日志的标签面板。
    @State private var editingTags = false
    @State private var hovered = false
    /// 标签 / 关联待办的浮窗还开着：鼠标移进浮窗时浮出的按钮不能收起。
    @State private var holding = false

    var body: some View {
        line.animation(Motion.quick, value: expanded)
    }

    private func toggleImages() {
        guard !log.images.isEmpty else { return }
        expanded.toggle()
    }

    private var rowContent: some View {
        HStack(alignment: .top, spacing: 3) {
            LogEventBadge(log: log)
            if log.showsTimelineContext || !hasPrevious, let label = LogTaskLabel.saved(log, store: store, logDate: date) {
                Button {
                    // 不论有没有截止日期，都把主窗口调出来并选中这个任务。
                    if let id = log.taskID, store.locate(id) != nil {
                        AppRouter.presentMain()
                        NotificationCenter.default.post(name: .timelineReveal, object: id)
                    }
                } label: {
                    Text("[\(label)]").font(.system(size: typography.pt(11), design: .monospaced)).lineLimit(1)
                        .padding(.horizontal, 3).frame(height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(TerminalPalette.blue)
                .frame(maxWidth: 220, alignment: .leading).fixedSize(horizontal: true, vertical: false)
                .help(label).accessibilityLabel(AppLocalizedFormat("关联任务：%@", label))
                .disabled(log.taskID.flatMap { store.locate($0) } == nil)
            }
            VStack(alignment: .leading, spacing: 4) {
                if log.text.isEmpty, !log.images.isEmpty {
                    Button(action: toggleImages) {
                        Text(expanded ? "收起图片" : "图片 · 点击查看")
                            .font(.system(size: typography.pt(12), design: .monospaced)).foregroundStyle(TerminalPalette.muted)
                            .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                } else if !LogEventStyle.body(log).isEmpty {
                    TaskLinkText(source: LogEventStyle.body(log), completed: false, color: TerminalPalette.text, fontSize: 12,
                                 edit: { guard !store.isReadOnly else { return }; edit(log, date) }, open: SafariLinks.open,
                                 maxLines: 0, monospaced: true, markdown: true, compactLines: true,
                                 click: log.images.isEmpty ? nil : toggleImages, menuItems: menuItems)
                }
                if let detail = LogEventStyle.detail(log) {
                    Text(detail).font(.system(size: typography.pt(11), design: .monospaced))
                        .foregroundStyle(TerminalPalette.muted)
                }
                LogFocusGoal(log: log)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if !log.images.isEmpty {
                Button(action: toggleImages) {
                    Label("\(log.images.count)", systemImage: expanded ? "photo.fill" : "photo")
                        .font(.system(size: typography.pt(11), design: .monospaced))
                        .padding(.horizontal, 5).frame(height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(TerminalPalette.blue)
                .help(expanded ? AppLocalized("收起图片") : AppLocalizedFormat("点击查看 %lld 张图片", log.images.count))
                .accessibilityLabel(expanded ? AppLocalized("收起图片") : AppLocalizedFormat("查看 %lld 张图片", log.images.count))
            }
            if log.showsTimelineTags, !log.tags.isEmpty { TaskTagLine(tags: log.tags, log: log.id).padding(.top, 2) }
        }
    }

    private var line: some View {
        LogTimelineRow(log: log, hasPrevious: hasPrevious, hasNext: hasNext, segment: segment) {
            VStack(alignment: .leading, spacing: 4) {
                rowContent
                if expanded, !log.images.isEmpty {
                    LogImageGallery(store: store, names: log.images, preview: preview)
                        .transition(Motion.reduced ? .identity : .opacity)
                }
            }
        }
        .frame(minHeight: 22, alignment: .top)
        .background(highlighted || selection.selected ? TerminalPalette.blue.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 3))
        .contentShape(Rectangle())
        // 操作按钮浮在行的右上角，不占布局：平时这一行是干净的，文字可以用满整行。
        .overlay(alignment: .topTrailing) { floatingActions }
        .onContinuousHover { phase in
            switch phase {
            case .active: hovered = true
            case .ended: hovered = false
            }
        }
        .contextMenu {
            ForEach(Array(menuItems.enumerated()), id: \.offset) { _, item in
                if item.separator { Divider() } else {
                    Button(role: item.destructive ? .destructive : nil, action: item.action) {
                        if let symbol = item.symbol { Label(LocalizedStringKey(item.title), systemImage: symbol) } else { Text(LocalizedStringKey(item.title)) }
                    }
                }
            }
        }
        .popover(isPresented: $editingTags, arrowEdge: .trailing) { LogBatchTagView(store: store, logIDs: [log.id]) }
    }

    /// 右键菜单（和浮出的按钮是同一批操作，另外有删除）。
    private var menuItems: [TextMenuItem] {
        guard !store.isReadOnly else {
            return [TextMenuItem(title: "复制文字", symbol: "doc.on.doc", action: { copy(log) })]
        }
        return [
            TextMenuItem(title: "复制文字（不含图片）", symbol: "doc.on.doc", action: { copy(log) }),
            TextMenuItem(title: "编辑", symbol: "pencil", action: { edit(log, date) }),
            TextMenuItem(title: log.tags.isEmpty ? "加标签…" : "标签…", symbol: "tag", action: { editingTags = true }),
        ] + (log.taskID.flatMap { store.locate($0) }.map { task in
            [TextMenuItem(title: AppLocalizedFormat("打开「%@」的笔记", FocusHint.label(task)), symbol: "note.text", action: { AppRouter.openNotes(task.id) })]
        } ?? []) + [
            TextMenuItem(title: selection.selected ? "取消选中" : "选中这条日志", symbol: selection.selected ? "checkmark.circle" : "circle", action: selection.toggle),
            .divider,
            TextMenuItem(title: "删除（可撤销）", symbol: "trash", destructive: true, action: delete),
        ]
    }

    /// 悬停时才出现的小胶囊：复制、编辑，加上选择圈；已经选了几条之后，选择圈常驻，方便继续点选。
    @ViewBuilder
    private var floatingActions: some View {
        let showsButtons = (hovered || holding) && !store.isReadOnly
        let showsSelect = hovered || selection.selected || selection.anySelected
        if showsButtons || showsSelect {
            HStack(spacing: 0) {
                if showsButtons {
                    EntryMetadataButtons(store: store, log: log, date: date)
                        .environment(\.holdHoverActions) { holding = $0 }
                    ItemActionButton(symbol: "doc.on.doc", title: log.copyText == nil ? "没有可复制的文字（只有图片）" : "复制文字", compact: true) { copy(log) }
                        .disabled(log.copyText == nil)
                    ItemActionButton(symbol: "pencil", title: "编辑这条日志", compact: true) { edit(log, date) }
                }
                if showsSelect {
                    Button(action: selection.toggle) {
                        Image(systemName: selection.selected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: typography.pt(13)))
                            .frame(width: 22, height: 22).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(selection.selected ? TerminalPalette.blue : TerminalPalette.muted)
                    .help(selection.selected ? "取消选中" : "选中这条日志")
                    .accessibilityLabel(selection.selected ? "取消选中这条日志" : "选中这条日志")
                }
            }
            .padding(.horizontal, 2)
            .background {
                if showsButtons {
                    Capsule().fill(TerminalPalette.surface)
                        .overlay(Capsule().strokeBorder(TerminalPalette.muted.opacity(0.28), lineWidth: 0.75))
                        .shadow(color: .black.opacity(0.28), radius: 3, y: 1.5)
                }
            }
            .padding(.trailing, 4)
            .transition(.opacity)
        }
    }

    private func delete() {
        guard !store.isReadOnly else { return }
        store.deleteLog(log.id, on: date)
    }
}

private struct ReviewDraftView: View {
    @ObservedObject var store: JournalStore
    let date: Date
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var append = true

    init(store: JournalStore, date: Date) {
        self.store = store
        self.date = date
        _text = State(initialValue: DailyReview.render(store.entry(for: date)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("复盘草稿").font(.headline)
            SummaryEditor(text: $text, readOnly: store.isReadOnly, startsEditing: true)
            if !store.entry(for: date).summary.isEmpty {
                PillSegmentedControl(selection: $append, segments: [
                    .init(value: true, title: "追加到已有总结", symbol: "text.append"),
                    .init(value: false, title: "替换已有总结", symbol: "arrow.triangle.2.circlepath"),
                ], fillsWidth: true)
                .accessibilityLabel("保存方式")
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存复盘") { store.applyReview(text, on: date, append: append); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(store.isReadOnly || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(20).frame(width: 540, height: 420)
    }
}
