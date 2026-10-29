import AppKit
import Combine
import SwiftUI
import TimelineCore

/// 输入在独立视图中即时显示，停顿后再同步草稿，避免每个字都刷新所有观察仓库的窗口。
/// 只有直接观察它的输入视图随按键重绘；提交、切换日期、失焦、退出前都会先写回。
@MainActor
final class LogDraftBuffer: ObservableObject {
    enum Field { case log, deadline }

    @Published private(set) var text: String
    private var store: JournalStore?
    private var date: Date
    private let field: Field
    private var storedText: String
    private var pending: Task<Void, Never>?
    private var subscriptions: [AnyCancellable] = []

    init(store: JournalStore, date: Date, field: Field = .log) {
        self.field = field
        self.date = date
        text = ""
        storedText = ""
        attach(store: store, date: date)
    }

    /// 还没拿到仓库时先建一个空缓冲（放进 @State 时用，避免每次构造视图都订阅仓库）。
    init(field: Field) {
        self.field = field
        date = Date()
        text = ""
        storedText = ""
    }

    private func stored(in entry: DayEntry?) -> String {
        switch field {
        case .log: return entry?.logDraft ?? ""
        case .deadline: return entry?.deadlineDraft ?? ""
        }
    }

    /// 绑定到某一天的草稿；换日期前先把旧日期的输入写回。
    func attach(store: JournalStore, date: Date) {
        if self.store === store, JournalDates.key(self.date) == JournalDates.key(date) { return }
        flush()
        let first = self.store == nil
        self.store = store
        self.date = date
        let initial = stored(in: store.entry(for: date))
        storedText = initial
        if text != initial { text = initial }
        guard first else { return }
        // `$days` 在赋值前发出新值：其他窗口、提交、历史调取改了草稿时立即同步。
        store.$days.sink { [weak self] days in
            guard let self else { return }
            self.synchronize(self.stored(in: days[JournalDates.key(self.date)]))
        }.store(in: &subscriptions)
        let center = NotificationCenter.default
        for name in [Notification.Name.timelineCommitEditing, NSApplication.willTerminateNotification] {
            center.publisher(for: name).sink { [weak self] _ in self?.flush() }.store(in: &subscriptions)
        }
    }

    func update(_ text: String) {
        guard let store, !store.isReadOnly, text != self.text else { return }
        self.text = text
        pending?.cancel()
        pending = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            self?.flush()
        }
    }

    /// 程序写入（补全命令、调取历史、清空）：立即写回仓库。
    func set(_ text: String) {
        pending?.cancel()
        pending = nil
        self.text = text
        storedText = text
        write(text)
    }

    func flush() {
        pending?.cancel()
        pending = nil
        guard store != nil, text != storedText else { return }
        storedText = text
        write(text)
    }

    private func write(_ text: String) {
        guard let store else { return }
        switch field {
        case .log: store.setLogDraft(text, on: date)
        case .deadline: store.setDeadlineDraft(text, on: date)
        }
    }

    /// 其他窗口、提交或历史调取改变了草稿时，取消旧输入的延迟写入。
    func synchronize(_ text: String) {
        guard text != storedText else { return }
        pending?.cancel()
        pending = nil
        storedText = text
        if self.text != text { self.text = text }
    }
}

/// 只有它观察草稿缓冲：输入时重绘的范围限于输入行本身。
struct ObservingDraft<Content: View>: View {
    @ObservedObject var draft: LogDraftBuffer
    @ViewBuilder let content: (String) -> Content

    var body: some View { content(draft.text) }
}

struct JournalComposer: View {
    @ObservedObject var store: JournalStore
    let date: Date
    @Binding var focused: Bool
    @Binding var unlinked: Bool
    @ObservedObject var mention: MentionState
    let submit: () -> Void
    @StateObject private var draft: LogDraftBuffer

    init(store: JournalStore, date: Date, focused: Binding<Bool>, unlinked: Binding<Bool>, mention: MentionState, submit: @escaping () -> Void) {
        self.store = store
        self.date = date
        _focused = focused
        _unlinked = unlinked
        self.mention = mention
        self.submit = submit
        _draft = StateObject(wrappedValue: LogDraftBuffer(store: store, date: date))
    }

    private var entry: DayEntry { store.entry(for: date) }

    private func commit() {
        guard store.imageImports(for: "journal:" + JournalDates.key(date)).pending == 0 else { return }
        draft.flush()
        submit()
        draft.synchronize(store.entry(for: date).logDraft)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !entry.logDraftImages.isEmpty {
                PendingImagesStrip(store: store, names: entry.logDraftImages,
                                   remove: { store.removeDraftImage($0, on: date) },
                                   preview: { ImageViewerController.shared.openPreview(store: store, names: entry.logDraftImages, index: $0) })
            }
            HStack(spacing: 8) {
                Image(systemName: "square.and.pencil").foregroundStyle(Palette.accent)
                ImageImportStatus(queue: store.imageImports(for: "journal:" + JournalDates.key(date)), compact: true)
                TaskInput(text: Binding(get: { draft.text }, set: draft.update),
                          focused: $focused, placeholder: "写下日志…", fontSize: 13,
                          submit: commit, onPasteImages: { datas in
                    ImageTools.importImages(datas, in: store, queue: store.imageImports(for: "journal:" + JournalDates.key(date))) { [store, date] names in
                        for name in names { store.addDraftImage(name, on: date) }
                    }
                    focused = true
                }, minHeight: 24, maxLines: 10, mention: mention)
                .disabled(store.isReadOnly)
                Button(action: commit) { Image(systemName: "arrow.turn.down.left") }
                    .buttonStyle(HitAreaButtonStyle())
                    .disabled(store.isReadOnly || (draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && entry.logDraftImages.isEmpty))
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .inputFieldSurface(focused: focused)
            LogChipsBar(store: store,
                        link: Binding(get: { entry.logTaskID }, set: { store.setLogTask($0, on: date) }),
                        unlinked: $unlinked,
                        tags: Binding(get: { entry.logDraftTags }, set: { tags in
                            for tag in entry.logDraftTags where !tags.contains(tag) { store.removeDraftTag(tag, on: date) }
                            for tag in tags { store.addDraftTag(tag, on: date) }
                        }))
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .onChange(of: focused) { if !$0 { draft.flush() } }
        .onChange(of: date) { draft.attach(store: store, date: $0) }
        .onDisappear { draft.flush() }
        .popover(isPresented: Binding(get: { mention.isActive }, set: { if !$0 { mention.dismiss() } }), arrowEdge: .bottom) {
            MentionList(state: mention, store: store).frame(width: 340)
        }
    }

}
