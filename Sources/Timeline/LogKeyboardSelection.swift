import AppKit
import Combine
import SwiftUI

/// 笔记 / 日记页的选中条目，和主界面时间轴的选中一样：
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
    let scrollRequests = PassthroughSubject<UUID, Never>()
    fileprivate let rowViews = NSHashTable<LogRowSelectionView>.weakObjects()
    private(set) var pages: [UnifiedNotesMode: Page] = [:]
    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    /// 页面现在是笔记还是日记；测试里可以替换。
    var currentMode: () -> UnifiedNotesMode = { NotesWindowController.shared.workspace.mode }
    /// 笔记页是不是当前接收键盘的窗口；测试里可以替换。
    var isActive: () -> Bool = { NotesWindowController.shared.isKey }

    func register(_ mode: UnifiedNotesMode, _ page: Page) { pages[mode] = page }

    func select(_ id: UUID?, reveal: Bool = true) {
        guard selectedID != id else { return }
        InlineMarkdownEditor.shared.cancelPreparation()
        selectedID = id
        if reveal, let id { scrollRequests.send(id) }
    }

    /// 由应用装一次。首次点击正文选中，之后的点击才交给正文编辑器。
    func install() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return MainActor.assumeIsolated { self.handle(event) } ? nil : event
        }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            // 只把 Bool 带出隔离闭包，NSEvent 不符合 Sendable。
            let consumed = MainActor.assumeIsolated { self.handleMouseDown(event) == nil }
            return consumed ? nil : event
        }
    }

    func handleMouseDown(_ event: NSEvent) -> NSEvent? {
        guard let window = event.window else { return event }
        let rows = rowViews.allObjects.filter { $0.window === window && !$0.isHiddenOrHasHiddenAncestor }
        guard !rows.isEmpty else { return event }
        guard let row = rows.first(where: { $0.bounds.intersection($0.visibleRect).contains($0.convert(event.locationInWindow, from: nil)) }),
              let id = row.id else {
            select(nil, reveal: false)
            return event
        }
        guard selectedID != id, !InlineMarkdownEditor.shared.isEditing(id) else { return event }
        InlineMarkdownEditor.shared.finish()
        select(id, reveal: false)
        // 只接管正文的第一次点击；链接、复选框、代码复制和折叠按钮保留直接操作。
        guard event.type == .leftMouseDown, !event.modifierFlags.contains(.control), let content = window.contentView else { return event }
        let point = content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
        var hit = content.hitTest(point)
        while let view = hit {
            if let text = view as? InteractiveTaskText {
                let point = text.convert(event.locationInWindow, from: nil)
                if text.link(at: point) != nil || text.headingKey(at: point) != nil
                    || text.taskRegions().contains(where: { $0.rect.contains(point) })
                    || text.codeRegions().contains(where: { $0.copy.contains(point) }) { return event }
                window.makeFirstResponder(nil)
                row.prepareForSelection()
                return nil
            }
            hit = view.superview
        }
        row.prepareForSelection()
        return event
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
            // 保持选中：编辑完按 Esc 退出后，↑↓ 从这一条接着走。
            guard let id = selectedID else { return false }
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

/// 被选中的那一行：柔和底色加左侧强调条，和时间轴的选中一致。只有这一小块订阅选中状态，换选中时整页不重算。
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
        onReceive(LogKeyboardSelection.shared.scrollRequests) { proxy.scrollTo($0) }
    }
}

/// 原生行区域只在点击时查询，不监听鼠标移动，也不向 SwiftUI 回传每帧几何信息。
struct LogRowSelectionArea: NSViewRepresentable {
    let id: UUID
    var prepare: (() -> Void)? = nil

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: LogRowSelectionView, context: Context) -> CGSize? {
        // 背景仅跟随正文的既有尺寸，不用 Auto Layout 重新推算行高。
        CGSize(width: proposal.width ?? nsView.bounds.width, height: proposal.height ?? nsView.bounds.height)
    }

    func makeNSView(context: Context) -> LogRowSelectionView {
        let view = LogRowSelectionView()
        view.id = id
        view.prepare = prepare
        return view
    }

    func updateNSView(_ view: LogRowSelectionView, context: Context) {
        view.id = id
        view.prepare = prepare
    }
}

final class LogRowSelectionView: NSView {
    var id: UUID?
    var prepare: (() -> Void)?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func prepareForSelection() {
        guard let id, prepare != nil else { return }
        InlineMarkdownEditor.shared.prepareSoon(id, selected: true) { [weak self] in
            guard let self, self.id == id, self.window != nil, !self.isHiddenOrHasHiddenAncestor,
                  LogKeyboardSelection.shared.selectedID == id else { return }
            self.prepare?()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { LogKeyboardSelection.shared.rowViews.add(self) }
    }
}
