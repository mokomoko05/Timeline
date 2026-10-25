import AppKit
import SwiftUI
import TimelineCore

/// 待办标题、日志/笔记正文等各处共用的输入框。单行（标题）用 `NSTextField`；多行自动增高（`minHeight` 非空且允许换行）用
/// `NSScrollView` + `NSTextView`，这样内容超过 `maxLines` 封顶高度后能在框内滚动，而不是带着外面的列表一起滚。
struct TaskInput: View {
    @ObservedObject private var languages = LanguageStore.shared
    @Binding var text: String
    @Binding var focused: Bool
    var placeholder = ""
    var fontSize: CGFloat = 13
    let submit: () -> Void
    var cancel: () -> Void = {}
    var previous: () -> Void = {}
    var monospaced = false
    var historyUp: (() -> Void)?
    var historyDown: (() -> Void)?
    var complete: (() -> Void)?
    /// 设置后，粘贴图片会交给它处理（文字照常粘贴）。
    var onPasteImages: (([Data]) -> Void)?
    /// 设置后输入框自动换行、随内容向下增高：这是单行时的高度，最多长到 `maxLines` 行，到顶后框内自己滚动。
    /// Enter 换行，⌘Enter 提交；失焦保留编辑内容。
    var minHeight: CGFloat?
    var maxLines = 10
    /// 能不能有多行：回车是换行（true）还是始终提交（false）。待办标题、添加待办这种一行一条内容为 false。
    var allowsNewlines = true
    /// 粘贴进来的换行要不要变成空格。默认跟 `allowsNewlines` 相反（标题这类场景粘贴多行会变成一行空格分隔）；
    /// 添加待办框单独设成 false：粘贴多行是批量加好几条待办，保留换行给 `commitDraft` 按行拆。
    var collapsesPastedNewlines: Bool?
    /// 设置后，在开头或空白之后输入 `@`（待办）或 `#`（标签）会弹出候选（见 `MentionList`）：↑ ↓ 选择，回车 / Tab 确认，Esc 只关掉候选。
    var mention: MentionState?
    /// 只在 `allowsNewlines` 为 true 时有意义：true 时回车直接提交（Shift+Enter 换行），而不是回车换行、⌘Enter 提交。
    /// 快速日志命令行这种「主要是单行命令，偶尔需要在框内滚动」的场景用它：既要保留 `GrowingTaskInput`
    /// 的框内滚动、mention 候选等能力，又要回车直接提交。
    var returnSubmits = false
    /// 编辑已有条目时仅接受 ⌘Enter；新建输入框仍可用普通 Enter。
    var commandReturnOnly = false

    private var growing: Bool { minHeight != nil && allowsNewlines }

    /// 内容需要的高度：行数（按宽度折行）乘行高，再加上单行时上下的留白；到 `maxLines` 行为止。单行、多行两套实现用的是同一个算法。
    static func height(for text: String, font: NSFont, width: CGFloat, minHeight: CGFloat, maxLines: Int) -> CGFloat {
        GrowingTaskInput.height(for: text, font: font, width: width, minHeight: minHeight, maxLines: maxLines)
    }

    var body: some View {
        if growing {
            GrowingTaskInput(text: $text, focused: $focused, placeholder: AppLocalized(placeholder), fontSize: fontSize, submit: submit,
                              cancel: cancel, monospaced: monospaced, historyUp: historyUp, historyDown: historyDown,
                              complete: complete, onPasteImages: onPasteImages, minHeight: minHeight ?? 24, maxLines: maxLines,
                              returnSubmits: returnSubmits, mention: mention)
        } else {
            SingleLineTaskInput(text: $text, focused: $focused, placeholder: AppLocalized(placeholder), fontSize: fontSize, submit: submit,
                                 cancel: cancel, previous: previous, monospaced: monospaced, onPasteImages: onPasteImages,
                                 minHeight: minHeight, maxLines: maxLines, allowsNewlines: allowsNewlines,
                                 collapsesPastedNewlines: collapsesPastedNewlines ?? !allowsNewlines, complete: complete,
                                 commandReturnOnly: commandReturnOnly)
        }
    }
}

/// 只测量可见行数，按正文、字体和行数上限更新独立排版栈，复用宽度缓存。
/// 编辑器仍保留全文，不改变其文本容器或滚动范围。
final class InputHeightMeasurer {
    private let measurer = TextMeasurer()
    private var source: String?
    private var font: NSFont?
    private var lineLimit = 0

    func height(for text: String, font: NSFont, width: CGFloat, minHeight: CGFloat, maxLines: Int) -> CGFloat {
        let limit = max(1, maxLines)
        if source != text || self.font != font || lineLimit != limit {
            source = text
            self.font = font
            lineLimit = limit
            let measuredText = text.isEmpty ? " " : (text.hasSuffix("\n") ? text + " " : text)
            measurer.update(NSAttributedString(string: measuredText, attributes: [.font: font]), maxLines: limit)
        }
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let measured = measurer.height(forWidth: max(20, width - 8))
        let lines = min(CGFloat(limit), max(1, ceil(measured / lineHeight)))
        return lines * lineHeight + max(0, minHeight - lineHeight)
    }
}

/// 单行（标题）场景：原来的 `NSTextField` 实现，回车提交，不支持框内滚动（本来也用不到）。
struct SingleLineTaskInput: NSViewRepresentable {
    @Environment(\.typography) private var typography
    @Environment(\.isEnabled) private var enabled
    @Binding var text: String
    @Binding var focused: Bool
    var placeholder = ""
    var fontSize: CGFloat = 13
    let submit: () -> Void
    var cancel: () -> Void = {}
    var previous: () -> Void = {}
    var monospaced = false
    var onPasteImages: (([Data]) -> Void)?
    var minHeight: CGFloat?
    var maxLines = 10
    var allowsNewlines = true
    /// 粘贴进来的换行要不要变成空格。省略时跟 `allowsNewlines` 相反。
    var collapsesPastedNewlines: Bool?
    var complete: (() -> Void)?
    var commandReturnOnly = false
    private var collapsesNewlines: Bool { collapsesPastedNewlines ?? !allowsNewlines }

    private var growing: Bool { minHeight != nil }

    private var resolvedFont: NSFont {
        monospaced ? .monospacedSystemFont(ofSize: typography.pt(fontSize), weight: .regular) : .systemFont(ofSize: typography.pt(fontSize))
    }

    /// 内容需要的高度：行数（按宽度折行）乘行高，再加上单行时上下的留白；到 `maxLines` 行为止。
    static func height(for text: String, font: NSFont, width: CGFloat, minHeight: CGFloat, maxLines: Int) -> CGFloat {
        InputHeightMeasurer().height(for: text, font: font, width: width, minHeight: minHeight, maxLines: maxLines)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context) -> CGSize? {
        guard let minHeight else { return nil }
        let width = proposal.width ?? max(nsView.bounds.width, 200)
        return CGSize(width: width, height: context.coordinator.heightMeasurer.height(for: text, font: resolvedFont, width: width, minHeight: minHeight, maxLines: maxLines))
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = TaskTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = context.coordinator
        context.coordinator.field = field
        field.onAttach = { [weak field, weak coordinator = context.coordinator] in
            if let field { coordinator?.requestFocus(field) }
        }
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if growing, let cell = field.cell as? NSTextFieldCell {
            cell.wraps = true
            cell.isScrollable = false
            cell.usesSingleLineMode = false
            cell.lineBreakMode = .byWordWrapping
            field.maximumNumberOfLines = 0
        }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        field.appearance = NSAppearance(named: context.environment.colorScheme == .dark ? .darkAqua : .aqua)
        field.placeholderString = placeholder
        if field.font != resolvedFont { field.font = resolvedFont }
        field.textColor = .labelColor
        field.isEditable = enabled
        field.isSelectable = true
        (field as? TaskTextField)?.onPasteImages = onPasteImages
        // ⌘Enter 在所有输入框里都是「保存 / 提交」；普通 Enter 是否提交另看 commandReturnOnly。
        (field as? TaskTextField)?.onCommandReturn = { [weak coordinator = context.coordinator, weak field] in
            guard let coordinator, let field else { return }
            coordinator.parent.text = (field.currentEditor() as? NSTextView)?.string ?? field.stringValue
            coordinator.parent.submit()
        }
        if field.stringValue != text, (field.currentEditor() as? NSTextView)?.hasMarkedText() != true { field.stringValue = text }
        let wantsFocus = focused && enabled
        if wantsFocus, !context.coordinator.focusRequested { context.coordinator.requestFocus(field) }
        context.coordinator.focusRequested = wantsFocus
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SingleLineTaskInput
        let heightMeasurer = InputHeightMeasurer()
        var focusRequested = false
        weak var field: NSTextField?
        init(_ parent: SingleLineTaskInput) { self.parent = parent }

        func requestFocus(_ field: NSTextField) {
            DispatchQueue.main.async { [weak self, weak field] in
                guard let self, let field, field.isEditable, self.parent.focused,
                      field.currentEditor() == nil, field.window?.isKeyWindow == true,
                      field.window?.attachedSheet == nil else { return }
                field.window?.makeFirstResponder(field)
            }
        }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            if parent.collapsesNewlines, field.stringValue.contains(where: \.isNewline),
               let editor = field.currentEditor() as? NSTextView {
                // 粘贴进来的换行变成空格，光标位置不变。
                let selection = editor.selectedRange()
                editor.string = editor.string.components(separatedBy: .newlines).joined(separator: " ")
                editor.setSelectedRange(selection)
            }
            parent.text = field.stringValue
        }
        func controlTextDidBeginEditing(_ notification: Notification) {
            parent.focused = true
        }
        func controlTextDidEndEditing(_ notification: Notification) {
            focusRequested = false
            parent.focused = false
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            // 这里走到的都是 allowsNewlines == false 的单行场景（`allowsNewlines == true` 时 `TaskInput.body`
            // 选的是 `GrowingTaskInput`）；编辑已有标题时只允许 ⌘Enter 保存。
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                guard !parent.commandReturnOnly else { return true }
                parent.text = textView.string
                parent.submit()
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                parent.cancel()
                parent.focused = false
                control.window?.makeFirstResponder(nil)
                return true
            }
            if commandSelector == #selector(NSResponder.insertTab(_:)), let complete = parent.complete {
                complete()
                return true
            }
            if commandSelector == #selector(NSResponder.deleteBackward(_:)), textView.string.isEmpty {
                parent.previous()
                return true
            }
            return false
        }
    }
}

/// 多行自动增高场景：`NSScrollView` + `NSTextView`，封顶高度后框内滚动。
/// Enter 换行，⌘Enter 提交（`returnSubmits` 为 true 时反过来：Enter 直接提交，Shift+Enter 换行）；
/// 失焦保留编辑内容，Esc 取消。
struct GrowingTaskInput: NSViewRepresentable {
    @Environment(\.typography) private var typography
    @Environment(\.isEnabled) private var enabled
    @Binding var text: String
    @Binding var focused: Bool
    var placeholder = ""
    var fontSize: CGFloat = 13
    let submit: () -> Void
    var cancel: () -> Void = {}
    var monospaced = false
    var historyUp: (() -> Void)?
    var historyDown: (() -> Void)?
    var complete: (() -> Void)?
    var onPasteImages: (([Data]) -> Void)?
    var minHeight: CGFloat
    var maxLines = 10
    /// true 时回车直接提交（Shift+Enter 换行），而不是回车换行、⌘Enter 提交。
    var returnSubmits = false
    var mention: MentionState?

    private var resolvedFont: NSFont {
        monospaced ? .monospacedSystemFont(ofSize: typography.pt(fontSize), weight: .regular) : .systemFont(ofSize: typography.pt(fontSize))
    }

    static func height(for text: String, font: NSFont, width: CGFloat, minHeight: CGFloat, maxLines: Int) -> CGFloat {
        InputHeightMeasurer().height(for: text, font: font, width: width, minHeight: minHeight, maxLines: maxLines)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        let width = proposal.width ?? max(nsView.bounds.width, 200)
        return CGSize(width: width, height: context.coordinator.heightMeasurer.height(for: text, font: resolvedFont, width: width, minHeight: minHeight, maxLines: maxLines))
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        let editor = ImagePasteTextView(frame: .zero)
        editor.delegate = context.coordinator
        editor.font = resolvedFont
        editor.isRichText = false
        editor.allowsUndo = true
        editor.drawsBackground = false
        editor.textContainerInset = NSSize(width: 3, height: 4)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.string = text
        context.coordinator.editor = editor
        context.coordinator.placeholderField.stringValue = placeholder
        context.coordinator.placeholderField.isBordered = false
        context.coordinator.placeholderField.drawsBackground = false
        context.coordinator.placeholderField.isEditable = false
        context.coordinator.placeholderField.isSelectable = false
        context.coordinator.placeholderField.textColor = .placeholderTextColor
        context.coordinator.placeholderField.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = editor
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.addSubview(context.coordinator.placeholderField)
        NSLayoutConstraint.activate([
            context.coordinator.placeholderField.leadingAnchor.constraint(equalTo: scroll.leadingAnchor, constant: 6),
            context.coordinator.placeholderField.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 5),
        ])
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? ImagePasteTextView else { return }
        scroll.appearance = NSAppearance(named: context.environment.colorScheme == .dark ? .darkAqua : .aqua)
        if editor.font != resolvedFont { editor.font = resolvedFont }
        editor.textColor = .labelColor
        editor.onPasteImages = onPasteImages
        editor.returnSubmits = returnSubmits
        editor.mentionActive = { [weak mention = self.mention] in mention?.isActive == true }
        editor.onSubmitShortcut = { [weak editor, weak coordinator = context.coordinator] in
            guard let editor, let coordinator else { return }
            coordinator.parent.text = editor.string
            coordinator.parent.submit()
        }
        editor.isEditable = enabled
        if editor.string != text, !editor.hasMarkedText() { editor.string = text }
        context.coordinator.placeholderField.stringValue = placeholder
        context.coordinator.placeholderField.font = resolvedFont
        context.coordinator.placeholderField.isHidden = !text.isEmpty
        context.coordinator.bindMention()
        let wantsFocus = focused && enabled
        if wantsFocus, !context.coordinator.focusRequested { context.coordinator.requestFocus() }
        context.coordinator.focusRequested = wantsFocus
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: GrowingTaskInput
        let heightMeasurer = InputHeightMeasurer()
        var focusRequested = false
        weak var editor: NSTextView?
        let placeholderField = NSTextField(labelWithString: "")
        private var selectionObserver: NSObjectProtocol?
        init(_ parent: GrowingTaskInput) { self.parent = parent }
        deinit { if let selectionObserver { NotificationCenter.default.removeObserver(selectionObserver) } }

        func bindMention() {
            parent.mention?.acceptAction = { [weak self] in self?.acceptMention() ?? false }
        }

        func requestFocus() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let editor = self.editor, editor.isEditable, self.parent.focused,
                      editor.window?.firstResponder !== editor, editor.window?.isKeyWindow == true,
                      editor.window?.attachedSheet == nil else { return }
                editor.window?.makeFirstResponder(editor)
            }
        }

        /// 光标所在位置有没有 `@xxx`：有就更新候选。
        func refreshMention() {
            guard let mention = parent.mention, let editor else { return }
            let selected = editor.selectedRange()
            mention.update(selected.length == 0 ? MentionToken.find(in: editor.string, caret: selected.location, triggers: mention.triggers) : nil)
        }

        @discardableResult
        func acceptMention() -> Bool {
            guard let mention = parent.mention, let (token, item) = mention.take() else { return false }
            if let editor, NSMaxRange(token.range) <= (editor.string as NSString).length {
                editor.insertText("", replacementRange: token.range)
                parent.text = editor.string
            } else {
                let ns = parent.text as NSString
                if NSMaxRange(token.range) <= ns.length { parent.text = ns.replacingCharacters(in: token.range, with: "") }
            }
            mention.onPick(item)
            parent.focused = true
            return true
        }

        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
            placeholderField.isHidden = !editor.string.isEmpty
            refreshMention()
        }

        func textDidBeginEditing(_ notification: Notification) {
            focusRequested = true
            parent.focused = true
            guard let editor = notification.object as? NSTextView else { return }
            if let selectionObserver { NotificationCenter.default.removeObserver(selectionObserver) }
            selectionObserver = NotificationCenter.default.addObserver(forName: NSTextView.didChangeSelectionNotification, object: editor, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshMention() }
            }
        }

        /// 失去第一响应者只更新草稿与焦点，不提交条目。
        func textDidEndEditing(_ notification: Notification) {
            focusRequested = false
            parent.focused = false
            if let selectionObserver { NotificationCenter.default.removeObserver(selectionObserver) }
            selectionObserver = nil
            // 候选列表收起延后一点：点候选列表时输入框会先失去焦点，立刻收掉就点不到了。
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard let self, self.editor?.window?.firstResponder !== self.editor else { return }
                self.parent.mention?.update(nil)
            }
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            if let mention = parent.mention, mention.isActive {
                switch selector {
                case #selector(NSResponder.moveUp(_:)): mention.move(-1); return true
                case #selector(NSResponder.moveDown(_:)): mention.move(1); return true
                case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
                    if acceptMention() { return true }
                case #selector(NSResponder.cancelOperation(_:)): mention.dismiss(); return true
                default: break
                }
            }
            if selector == #selector(NSResponder.moveUp(_:)), let historyUp = parent.historyUp {
                historyUp(); return true
            }
            if selector == #selector(NSResponder.moveDown(_:)), let historyDown = parent.historyDown {
                historyDown(); return true
            }
            if selector == #selector(NSResponder.insertTab(_:)), let complete = parent.complete { complete(); return true }
            // 普通 Enter 换行，交给系统处理；提交走 ⌘Enter（`ImagePasteTextView.onSubmitShortcut`，在 keyDown 里直接拦截）。
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                parent.cancel()
                parent.focused = false
                textView.window?.makeFirstResponder(nil)
                return true
            }
            return false
        }
    }
}

/// 字段编辑器：⌘V 时如果剪贴板是图片，交给输入框的 onPasteImages，而不是粘贴成乱码或什么都不做。
final class ImagePasteTextView: NSTextView {
    var onPasteImages: (([Data]) -> Void)?
    /// ⌘Enter 始终提交（全应用统一的保存 / 提交键）；`returnSubmits == true` 时普通 Enter 也提交，Shift+Enter 换行。
    /// 在 `keyDown` 里直接拦截，不走 `doCommandBy`（`insertNewline` 这个 selector 在输入法组词、候选框等场景下
    /// 的派发时机不可靠，`NSApp.currentEvent` 和「记录上一次 keyDown 再在 doCommandBy 里读」都验证过不准）。
    /// `keyDown` 拿到的 `event` 就是这次按键本身，修饰键判断不会错。
    var onSubmitShortcut: (() -> Void)?
    var returnSubmits = false
    /// 设置后，`@`/`#` 候选激活时普通 Enter 要让 `doCommandBy` 去确认候选，这里不能抢先拦截提交。
    var mentionActive: (() -> Bool)?

    override func keyDown(with event: NSEvent) {
        if shouldInterceptReturn(event), let onSubmitShortcut {
            onSubmitShortcut()
            return
        }
        super.keyDown(with: event)
    }

    /// 这次按键要不要当成提交拦截掉（不交给 `super.keyDown` 走 `insertNewline`）。拆出来是因为脱离 window 的
    /// `NSTextView` 调用 `super.keyDown` 走 `interpretKeyEvents` 行为不稳定，单测只验证这个判断本身。
    func shouldInterceptReturn(_ event: NSEvent) -> Bool {
        guard event.keyCode == 36, !hasMarkedText(), mentionActive?() != true else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if modifiers == .command { return true }
        return returnSubmits && modifiers.isEmpty
    }

    override func paste(_ sender: Any?) {
        if let handler = onPasteImages {
            let images = ImageTools.images(from: .general)
            if !images.isEmpty {
                handler(images)
                return
            }
        }
        super.paste(sender)
    }

    private var canPasteImages: Bool {
        onPasteImages != nil && ImageTools.hasImage(.general)
    }

    // 默认情况下纯文本输入框遇到只有图片的剪贴板会禁用「粘贴」，⌘V 就不会触发。
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(NSText.paste(_:)), canPasteImages { return true }
        return super.validateUserInterfaceItem(item)
    }

    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(NSText.paste(_:)), canPasteImages { return true }
        return super.validateMenuItem(item)
    }
}

final class TaskTextField: NSTextField {
    var onAttach: (() -> Void)?
    var onPasteImages: (([Data]) -> Void)?
    var onCommandReturn: (() -> Void)?
    override class var cellClass: AnyClass? {
        get { ImagePasteCell.self }
        set {}
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { onAttach?() }
    }
}

/// 单行输入框（`SingleLineTaskInput`）的字段编辑器：同样支持 ⌘V 粘贴图片。
final class ImagePasteFieldEditorView: NSTextView {
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36,
           event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
           !hasMarkedText(), let submit = (delegate as? TaskTextField)?.onCommandReturn {
            submit()
            return
        }
        super.keyDown(with: event)
    }

    override func paste(_ sender: Any?) {
        if let field = delegate as? TaskTextField, let handler = field.onPasteImages {
            let images = ImageTools.images(from: .general)
            if !images.isEmpty {
                handler(images)
                return
            }
        }
        super.paste(sender)
    }

    private var canPasteImages: Bool {
        (delegate as? TaskTextField)?.onPasteImages != nil && ImageTools.hasImage(.general)
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(NSText.paste(_:)), canPasteImages { return true }
        return super.validateUserInterfaceItem(item)
    }

    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(NSText.paste(_:)), canPasteImages { return true }
        return super.validateMenuItem(item)
    }
}

final class ImagePasteCell: NSTextFieldCell {
    private static let editor: ImagePasteFieldEditorView = {
        let view = ImagePasteFieldEditorView()
        view.isFieldEditor = true
        return view
    }()

    override func fieldEditor(for controlView: NSView) -> NSTextView? { Self.editor }
}

@MainActor
final class LinkInsertion {
    static var presenting = false
    weak var field: NSTextField?
    var range = NSRange(location: 0, length: 0)
    var initialAddress = ""
    var initialLabel = ""

    init() {
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.isFieldEditor,
           let field = editor.delegate as? NSTextField {
            self.field = field
            range = editor.selectedRange()
            let selected = (editor.string as NSString).substring(with: range)
            let rendered = TaskText.rendered(selected)
            if selected.hasPrefix("["), let url = rendered.runs.compactMap(\.link).first {
                initialAddress = url.absoluteString
                initialLabel = String(rendered.characters)
            } else if let url = TaskText.linkURL(selected) {
                initialAddress = url.absoluteString
            } else {
                initialLabel = selected
            }
        }
        if initialAddress.isEmpty, let clipboard = NSPasteboard.general.string(forType: .string), let url = TaskText.linkURL(clipboard) {
            initialAddress = url.absoluteString
        }
        Self.presenting = true
    }

    func finish(inserting link: String?) -> Bool {
        Self.presenting = false
        guard let field, let window = field.window else { return false }
        window.makeFirstResponder(field)
        if let link, let editor = field.currentEditor() as? NSTextView {
            let length = (editor.string as NSString).length
            let start = min(range.location, length)
            editor.insertText(link, replacementRange: NSRange(location: start, length: min(range.length, length - start)))
        }
        return true
    }
}
