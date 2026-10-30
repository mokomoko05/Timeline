import AppKit
import SwiftUI

struct BoardMarkdownEditor: NSViewRepresentable {
    @Environment(\.typography) private var typography
    @Binding var text: String
    let preview: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        let editor = BoardMarkdownTextView(frame: .zero)
        editor.font = .monospacedSystemFont(ofSize: typography.pt(13), weight: .regular)
        editor.textColor = NSColor(Palette.ink)
        editor.insertionPointColor = NSColor(Palette.ink)
        editor.isRichText = false
        editor.allowsUndo = true
        editor.drawsBackground = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainerInset = NSSize(width: 4, height: 6)
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.layoutManager?.allowsNonContiguousLayout = true
        editor.string = text
        editor.setAccessibilityLabel(AppLocalized("工作板 Markdown 内容"))
        scroll.documentView = editor
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.focusRingType = .none
        context.coordinator.attach(editor)
        DispatchQueue.main.async { [weak editor] in
            guard let editor, let window = editor.window, window.firstResponder !== editor else { return }
            window.makeFirstResponder(editor)
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let editor = scroll.documentView as? BoardMarkdownTextView else { return }
        let font = NSFont.monospacedSystemFont(ofSize: typography.pt(13), weight: .regular)
        if editor.font != font { editor.font = font }
        let color = NSColor(Palette.ink)
        if editor.textColor != color { editor.textColor = color }
        if editor.insertionPointColor != color { editor.insertionPointColor = color }
        coordinator.synchronize(text)
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.flush(finishingComposition: true)
        (scroll.documentView as? NSTextView)?.delegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: BoardMarkdownEditor
        private weak var editor: BoardMarkdownTextView?
        private var synchronizedText: String
        private var pending: Task<Void, Never>?

        init(_ parent: BoardMarkdownEditor) {
            self.parent = parent
            synchronizedText = parent.text
            super.init()
            NotificationCenter.default.addObserver(self, selector: #selector(commitEditing),
                                                   name: .timelineCommitEditing, object: nil)
        }

        deinit { NotificationCenter.default.removeObserver(self) }

        func attach(_ editor: BoardMarkdownTextView) {
            self.editor = editor
            editor.delegate = self
            editor.onFlush = { [weak self] in self?.flush(finishingComposition: true) }
            editor.onCompositionEnded = { [weak self] in self?.scheduleUpdate() }
            editor.onSubmitShortcut = { [weak self] in
                guard let self else { return }
                self.flush()
                self.parent.preview()
            }
        }

        func synchronize(_ text: String) {
            guard text != synchronizedText, let editor, !editor.hasMarkedText() else { return }
            pending?.cancel()
            pending = nil
            synchronizedText = text
            guard editor.string != text else { return }
            let selection = editor.selectedRanges
            let origin = editor.enclosingScrollView?.contentView.bounds.origin
            editor.string = text
            let length = (text as NSString).length
            editor.selectedRanges = selection.map {
                let range = $0.rangeValue
                let location = min(range.location, length)
                return NSValue(range: NSRange(location: location, length: min(range.length, length - location)))
            }
            editor.undoManager?.removeAllActions()
            if let origin, let scroll = editor.enclosingScrollView {
                scroll.contentView.scroll(to: origin)
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }

        func textDidChange(_ notification: Notification) { scheduleUpdate() }

        private func scheduleUpdate() {
            pending?.cancel()
            pending = nil
            guard let editor, !editor.hasMarkedText() else { return }
            pending = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
                self?.flush()
            }
        }

        func flush(finishingComposition: Bool = false) {
            if finishingComposition, editor?.hasMarkedText() == true { editor?.unmarkText() }
            pending?.cancel()
            pending = nil
            guard let editor, !editor.hasMarkedText(), editor.string != synchronizedText else { return }
            synchronizedText = editor.string
            parent.text = editor.string
        }

        @objc private func commitEditing() { flush(finishingComposition: true) }
    }
}

final class BoardMarkdownTextView: KeyTrackingTextView {
    var onFlush: (() -> Void)?
    var onCompositionEnded: (() -> Void)?

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFlush?() }
        return resigned
    }

    override func unmarkText() {
        super.unmarkText()
        onCompositionEnded?()
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
