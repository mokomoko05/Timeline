import AppKit
import SwiftUI

/// 笔记 / 日记页上用键盘选中的那一条，和主界面时间轴的选中一样：
/// ↑↓ 选择，⏎ 就地编辑，⌫ 删除（⌘Z 撤销），Esc 取消选中。输入框是空的时按 ↑ 选中最后一条。
@MainActor
final class LogKeyboardSelection: ObservableObject {
    static let shared = LogKeyboardSelection()

    /// 一页能做的事：当前从上到下的条目顺序、编辑、删除。闭包读的是页面当时的状态，注册一次即可。
    struct Page {
        var order: () -> [UUID]
        var edit: (UUID) -> Void
        var delete: (UUID) -> Void
    }

    @Published private(set) var selectedID: UUID?
    private var pages: [UnifiedNotesMode: Page] = [:]
    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    /// 页面现在是笔记还是日记；测试里可以替换。
    var currentMode: () -> UnifiedNotesMode = { NotesWindowController.shared.workspace.mode }
    /// 笔记页是不是当前接收键盘的窗口；测试里可以替换。
    var isActive: () -> Bool = { NotesWindowController.shared.isKey }

    func register(_ mode: UnifiedNotesMode, _ page: Page) { pages[mode] = page }

    func select(_ id: UUID?) { if selectedID != id { selectedID = id } }

    /// 由应用装一次。点了鼠标就取消选中（选中只给键盘用，鼠标有自己的悬停操作）。
    func install() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return MainActor.assumeIsolated { self.handle(event) } ? nil : event
        }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.select(nil) }
            return event
        }
    }

    /// 处理了返回 true（事件不再往下传）。
    func handle(_ event: NSEvent) -> Bool {
        guard isActive(), let page = pages[currentMode()], NSApp.keyWindow?.attachedSheet == nil,
              event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return false }
        let order = page.order()
        if let selectedID, !order.contains(selectedID) { select(nil) }
        if let editor = Self.focusedTextView {
            // 输入框是空的：↑ 离开输入框，选中最后一条（像聊天软件里按 ↑ 改上一条）。
            guard event.keyCode == 126, editor.string.isEmpty, let last = order.last else { return false }
            editor.window?.makeFirstResponder(nil)
            select(last)
            return true
        }
        guard !InlineMarkdownEditor.shared.handlesTextCommands, !Self.typingElsewhere else { return false }
        switch event.keyCode {
        case 126: return move(-1, in: order)
        case 125: return move(1, in: order)
        case 36, 76:
            guard let id = selectedID else { return false }
            select(nil)
            page.edit(id)
        case 51, 117:
            guard let id = selectedID, let index = order.firstIndex(of: id) else { return false }
            let rest = order.filter { $0 != id }
            page.delete(id)
            select(rest.isEmpty ? nil : rest[min(index, rest.count - 1)])
        case 53:
            guard selectedID != nil else { return false }
            select(nil)
        default: return false
        }
        return true
    }

    private func move(_ amount: Int, in order: [UUID]) -> Bool {
        guard !order.isEmpty else { return false }
        guard let id = selectedID, let index = order.firstIndex(of: id) else {
            select(amount > 0 ? order.first : order.last)
            return true
        }
        select(order[min(max(index + amount, 0), order.count - 1)])
        return true
    }

    /// 正在打字的多行输入框（写日志、写笔记的那个）；搜索框之类单行框的字段编辑器不算。
    private static var focusedTextView: NSTextView? {
        guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.isEditable, !editor.isFieldEditor else { return nil }
        return editor
    }

    /// 单行输入框（搜索、改名）正拿着键盘。
    private static var typingElsewhere: Bool {
        (NSApp.keyWindow?.firstResponder as? NSTextView)?.isEditable == true
    }
}

/// 被键盘选中的那一行：柔和底色加左侧强调条，和时间轴的选中一致。只有这一小块订阅选中状态，换选中时整页不重算。
struct LogSelectionMark: View {
    let id: UUID
    @ObservedObject private var selection = LogKeyboardSelection.shared

    var body: some View {
        let selected = selection.selectedID == id
        RoundedRectangle(cornerRadius: Metrics.radiusMedium, style: .continuous)
            .fill(Palette.accent.opacity(selected ? 0.08 : 0))
            .overlay(alignment: .leading) {
                Capsule().fill(Palette.accent).frame(width: 3).padding(.vertical, 6)
                    .opacity(selected ? 1 : 0)
            }
            .animation(Motion.reduced ? nil : Motion.quick, value: selected)
            .accessibilityHidden(true)
    }
}

extension View {
    /// 键盘选中的条目变了：滚到让它整条露出来（只滚需要的那么多）。
    func scrollsToKeyboardSelection(_ proxy: ScrollViewProxy) -> some View {
        onReceive(LogKeyboardSelection.shared.$selectedID.removeDuplicates()) { id in
            if let id { proxy.scrollTo(id) }
        }
    }
}
