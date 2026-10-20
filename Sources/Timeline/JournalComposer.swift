import AppKit
import SwiftUI
import TimelineCore

/// 输入在独立视图中即时显示，停顿后再同步草稿，避免每个字都刷新整个日记窗口。
@MainActor
final class LogDraftBuffer: ObservableObject {
    @Published private(set) var text: String
    private let store: JournalStore
    private let date: Date
    private var storedText: String
    private var pending: Task<Void, Never>?

    init(store: JournalStore, date: Date) {
        self.store = store
        self.date = date
        let initial = store.entry(for: date).logDraft
        text = initial
        storedText = initial
    }

    func update(_ text: String) {
        guard !store.isReadOnly, text != self.text else { return }
        self.text = text
        pending?.cancel()
        pending = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            self?.flush()
        }
    }

    func flush() {
        pending?.cancel()
        pending = nil
        guard text != storedText else { return }
        storedText = text
        store.setLogDraft(text, on: date)
    }

    /// 其他窗口、提交或历史调取改变了草稿时，取消旧输入的延迟写入。
    func synchronize(_ text: String) {
        guard text != storedText else { return }
        pending?.cancel()
        pending = nil
        storedText = text
        self.text = text
    }
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
        draft.flush()
        submit()
        draft.synchronize(store.entry(for: date).logDraft)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !entry.logDraftImages.isEmpty {
                PendingImagesStrip(store: store, names: entry.logDraftImages,
                                   remove: { store.removeDraftImage($0, on: date) },
                                   preview: { ImageViewerController.shared.show(store: store, names: entry.logDraftImages, index: $0) })
            }
            HStack(spacing: 8) {
                Image(systemName: "square.and.pencil").foregroundStyle(Palette.accent)
                TaskInput(text: Binding(get: { draft.text }, set: draft.update),
                          focused: $focused, placeholder: "写下日志…", fontSize: 13,
                          submit: commit, onPasteImages: { datas in
                    for name in ImageTools.save(datas, in: store) { store.addDraftImage(name, on: date) }
                    focused = true
                }, minHeight: 24, maxLines: 10, mention: mention)
                .disabled(store.isReadOnly)
                Button(action: commit) { Image(systemName: "arrow.turn.down.left") }
                    .buttonStyle(HitAreaButtonStyle())
                    .disabled(store.isReadOnly || (draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && entry.logDraftImages.isEmpty))
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 8))
            LogChipsBar(store: store,
                        link: Binding(get: { entry.logTaskID }, set: { store.setLogTask($0, on: date) }),
                        unlinked: $unlinked,
                        tags: Binding(get: { entry.logDraftTags }, set: { tags in
                            for tag in entry.logDraftTags where !tags.contains(tag) { store.removeDraftTag(tag, on: date) }
                            for tag in tags { store.addDraftTag(tag, on: date) }
                        }))
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .onReceive(store.$days) { draft.synchronize($0[JournalDates.key(date)]?.logDraft ?? "") }
        .onChange(of: focused) { if !$0 { draft.flush() } }
        .onDisappear { draft.flush() }
        .onReceive(NotificationCenter.default.publisher(for: .timelineCommitEditing)) { _ in draft.flush() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in draft.flush() }
        .popover(isPresented: Binding(get: { mention.isActive }, set: { if !$0 { mention.dismiss() } }), arrowEdge: .bottom) {
            MentionList(state: mention, store: store).frame(width: 340)
        }
    }

}
