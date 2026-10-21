import AppKit
import SwiftUI

/// 复盘区里编辑单条日志的文本框：Enter 换行，⌘Enter 保存，Esc 取消；输入法组词时不拦截。
struct LogTextEditor: NSViewRepresentable {
    @Environment(\.typography) private var typography
    @Binding var text: String
    let commit: () -> Void
    let cancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        let editor = KeyTrackingTextView(frame: .zero)
        editor.delegate = context.coordinator
        editor.font = .monospacedSystemFont(ofSize: typography.pt(13), weight: .regular)
        editor.isRichText = false
        editor.allowsUndo = true
        editor.drawsBackground = false
        editor.textContainerInset = NSSize(width: 3, height: 6)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.string = text
        scroll.documentView = editor
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        DispatchQueue.main.async {
            guard let window = scroll.window else { return }
            window.makeFirstResponder(editor)
            editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? KeyTrackingTextView else { return }
        scroll.appearance = NSAppearance(named: .darkAqua)
        let font = NSFont.monospacedSystemFont(ofSize: typography.pt(13), weight: .regular)
        if editor.font != font { editor.font = font }
        editor.textColor = .labelColor
        if editor.string != text, !editor.hasMarkedText() { editor.string = text }
        editor.onSubmitShortcut = { [weak editor, weak coordinator = context.coordinator] in
            guard let editor, let coordinator else { return }
            coordinator.parent.text = editor.string
            coordinator.parent.commit()
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: LogTextEditor
        init(_ parent: LogTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            if let editor = notification.object as? NSTextView { parent.text = editor.string }
        }

        /// 失焦只同步草稿，保存仅由 ⌘Enter 触发。
        func textDidEndEditing(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            // 普通 Enter 换行，交给系统处理；保存走 ⌘Enter（`KeyTrackingTextView.onSubmitShortcut`，在 keyDown 里直接拦截）。
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                parent.cancel()
                return true
            }
            return false
        }
    }
}

/// ⌘Enter 保存：在 `keyDown` 里直接拦截，不走 `doCommandBy`（`insertNewline` 这个 selector 在输入法组词、
/// 候选框等场景下的派发时机不可靠，`NSApp.currentEvent` 和「记录上一次 keyDown 再在 doCommandBy 里读」
/// 都验证过不准）。`keyDown` 拿到的 `event` 就是这次按键本身，修饰键判断不会错。
class KeyTrackingTextView: NSTextView {
    var onSubmitShortcut: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if shouldInterceptReturn(event), let onSubmitShortcut {
            onSubmitShortcut()
            return
        }
        super.keyDown(with: event)
    }

    /// 这次按键要不要当成提交拦截掉。拆出来是因为脱离 window 的 `NSTextView` 调用 `super.keyDown`
    /// 走 `interpretKeyEvents` 行为不稳定，单测只验证这个判断本身。
    func shouldInterceptReturn(_ event: NSEvent) -> Bool {
        event.keyCode == 36 && event.modifierFlags.contains(.command) && !hasMarkedText()
    }
}
