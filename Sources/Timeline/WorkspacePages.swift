import AppKit

/// 主窗口：Esc 在笔记 / 日记页上收起窗口（没有文字框先处理它时），和原来独立的笔记窗口一致。
final class MainWindow: NSWindow {
    var cancel: (() -> Bool)?
    override func cancelOperation(_ sender: Any?) {
        if cancel?() != true { super.cancelOperation(sender) }
    }
}

/// 主窗口的内容：主界面和笔记 / 日记两页叠在一起，一次只显示一页，窗口的位置和大小两页共用。
/// 藏起来的那页视图和状态（草稿、滚动位置、打开的笔记本）都留着，切回来是原样。
/// 每页记住自己的键盘焦点：切走时记下，切回来时还给它，打字不会落进看不见的那页。
@MainActor
final class WorkspacePagesView: NSView {
    private(set) var main: NSView?
    private(set) var notes: NSView?
    private(set) var showsNotes = false
    private weak var mainResponder: NSResponder?
    private weak var notesResponder: NSResponder?

    /// 换上（或释放掉）主界面。
    func setMain(_ view: NSView?) {
        main?.removeFromSuperview()
        main = view
        if let view { add(view) }
        update()
    }

    func setNotes(_ view: NSView) {
        notes?.removeFromSuperview()
        notes = view
        add(view)
        update()
    }

    /// 切到笔记页（`true`）或主界面。
    func show(notes showNotes: Bool) {
        guard showNotes != showsNotes, !showNotes || notes != nil else { return }
        let leaving = showsNotes ? notes : main
        // 文字框在编辑时，焦点在共用的字段编辑器上（离开后它会被拿走）：记下文字框本身。
        let current = window?.firstResponder
        let field = (current as? NSTextView).flatMap { $0.isFieldEditor ? $0.delegate as? NSView : nil }
        if let responder = field ?? current as? NSView, let leaving, responder.isDescendant(of: leaving) {
            if showsNotes { notesResponder = responder } else { mainResponder = responder }
        }
        showsNotes = showNotes
        update()
        guard let window else { return }
        let page = showNotes ? notes : main
        let saved = showNotes ? notesResponder : mainResponder
        if let saved = saved as? NSView, let page, saved.isDescendant(of: page), saved.window === window {
            window.makeFirstResponder(saved)
        } else {
            window.makeFirstResponder(nil)
        }
    }

    private func add(_ view: NSView) {
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
    }

    private func update() {
        main?.isHidden = showsNotes
        notes?.isHidden = !showsNotes
    }
}
