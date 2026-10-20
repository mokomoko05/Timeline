import AppKit
import SwiftUI

enum WorkspacePane: String {
    case tasks = "待办清单", summary = "总结", calendar = "日历"
}

@MainActor
final class WorkspaceInteraction: ObservableObject {
    @Published var activePane: WorkspacePane = .tasks
    var suppressNextTaskScroll = false
    @Published var selectedTaskID: UUID?
    @Published var logFocusRequest = 0
    /// 日志按这些任务筛选（跨日期）；为空表示显示当天全部日志。
    @Published var logFilter: Set<UUID> = []
    /// 请某一行打开它的面板（键盘或菜单触发）；行打开后清掉。
    @Published var taskPopover: TaskPopoverRequest?
}

struct TaskPopoverRequest: Equatable {
    enum Kind { case details, tags }
    let id: UUID
    let kind: Kind
}

struct SummaryEditor: NSViewRepresentable {
    @Binding var text: String
    @EnvironmentObject private var interaction: WorkspaceInteraction
    var readOnly = false
    var startsEditing = false

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = ReviewScrollView()
        let editor = ReviewTextView(frame: .zero)
        editor.delegate = context.coordinator
        editor.font = .systemFont(ofSize: 13)
        editor.isRichText = false
        editor.allowsUndo = true
        editor.drawsBackground = false
        editor.textContainerInset = NSSize(width: 3, height: 6)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.editingAllowed = !readOnly
        editor.isEditable = startsEditing && !readOnly
        editor.isSelectable = true
        scroll.documentView = editor
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        context.coordinator.editor = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? ReviewTextView else { return }
        scroll.appearance = NSAppearance(named: context.environment.colorScheme == .dark ? .darkAqua : .aqua)
        if editor.string != text, !editor.hasMarkedText() {
            editor.string = text
            context.coordinator.history.removeAllActions()
        }
        editor.editingAllowed = !readOnly
        if readOnly { editor.finishEditing() }
        editor.textColor = .labelColor
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SummaryEditor
        weak var editor: ReviewTextView?
        let history = UndoManager()

        init(_ parent: SummaryEditor) {
            self.parent = parent
            super.init()
            NotificationCenter.default.addObserver(self, selector: #selector(commitEditing), name: .timelineCommitEditing, object: nil)
        }

        deinit { NotificationCenter.default.removeObserver(self) }

        @objc private func commitEditing() { editor?.finishEditing() }

        func textDidChange(_ notification: Notification) {
            if let editor = notification.object as? NSTextView { parent.text = editor.string }
        }

        func textDidBeginEditing(_ notification: Notification) { parent.interaction.activePane = .summary }
        func undoManager(for view: NSTextView) -> UndoManager? { history }
    }
}

final class ReviewScrollView: NSScrollView {
    override func tile() {
        super.tile()
        guard let editor = documentView as? ReviewTextView else { return }
        editor.minSize = NSSize(width: 0, height: contentSize.height)
        if editor.frame.height < contentSize.height {
            editor.setFrameSize(NSSize(width: contentSize.width, height: contentSize.height))
        }
    }
}

final class ReviewTextView: NSTextView {
    var editingAllowed = true

    func beginEditing() {
        guard editingAllowed else { return }
        NotificationCenter.default.post(name: .timelineCommitEditing, object: nil)
        isEditable = true
        window?.makeFirstResponder(self)
    }

    func finishEditing() {
        guard isEditable else { return }
        if hasMarkedText() { unmarkText() }
        isEditable = false
    }

    /// 单击就进入编辑（先变成可编辑，再交给系统把光标放到点击的位置）。只读时不进入。
    @discardableResult
    func beginEditingIfClicked() -> Bool {
        guard !isEditable, editingAllowed else { return false }
        beginEditing()
        return isEditable
    }

    override func mouseDown(with event: NSEvent) {
        beginEditingIfClicked()
        super.mouseDown(with: event)
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { finishEditing() }
        return resigned
    }

    override func cancelOperation(_ sender: Any?) {
        guard !hasMarkedText() else { super.cancelOperation(sender); return }
        finishEditing()
        window?.makeFirstResponder(nil)
    }
}
