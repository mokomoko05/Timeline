import AppKit
import SwiftUI

/// 复盘区里编辑单条日志的文本框：Enter 换行，⌥Enter 保存，点击别处失焦也保存，Esc 取消；输入法组词时不拦截。
struct LogTextEditor: NSViewRepresentable {
    @Binding var text: String
    let commit: () -> Void
    let cancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        let editor = KeyTrackingTextView(frame: .zero)
        editor.delegate = context.coordinator
        editor.font = .monospacedSystemFont(ofSize: UIScale.pt(13), weight: .regular)
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
        guard let editor = scroll.documentView as? NSTextView else { return }
        scroll.appearance = NSAppearance(named: .darkAqua)
        editor.textColor = .labelColor
        if editor.string != text, !editor.hasMarkedText() { editor.string = text }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: LogTextEditor
        init(_ parent: LogTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            if let editor = notification.object as? NSTextView { parent.text = editor.string }
        }

        /// 点击别处、切换窗口等导致失去第一响应者时，当成提交保存（和 Esc 取消区分开）。
        func textDidEndEditing(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
            parent.commit()
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            if selector == #selector(NSResponder.insertNewline(_:)) {
                let modifiers = (textView as? KeyTrackingTextView)?.lastKeyDownEvent?.modifierFlags ?? []
                if modifiers.contains(.option) {
                    parent.text = textView.string
                    parent.commit()
                    return true
                }
                return false
            }
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                parent.cancel()
                return true
            }
            return false
        }
    }
}

/// 记录触发 `doCommandBy` 的按键事件：⌥Enter 判断要用这个事件本身的修饰键，而不是
/// `NSApp.currentEvent`（在组词、候选框等场景下不一定是同一个事件）。
final class KeyTrackingTextView: NSTextView {
    var lastKeyDownEvent: NSEvent?

    override func keyDown(with event: NSEvent) {
        lastKeyDownEvent = event
        super.keyDown(with: event)
    }
}
