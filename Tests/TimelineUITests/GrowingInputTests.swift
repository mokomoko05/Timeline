import AppKit
import SwiftUI
import XCTest
@testable import Timeline

@MainActor
final class GrowingInputTests: XCTestCase {
    private let font = NSFont.systemFont(ofSize: 13)
    private let long = String(repeating: "这是一大段粘贴进来的内容，会折成很多行。Pasted text that wraps. ", count: 12)

    private func input(_ text: String, minHeight: CGFloat? = 24, maxLines: Int = 10, allowsNewlines: Bool = true) -> TaskInput {
        TaskInput(text: .constant(text), focused: .constant(false), submit: {}, minHeight: minHeight, maxLines: maxLines, allowsNewlines: allowsNewlines)
    }

    /// 粘贴进来的换行是否变成空格，只有单行（标题）场景才会发生，走的是 `SingleLineTaskInput`。
    private func singleLine(allowsNewlines: Bool, text: Binding<String>) -> SingleLineTaskInput {
        SingleLineTaskInput(text: text, focused: .constant(false), submit: {}, minHeight: 22, maxLines: 6, allowsNewlines: allowsNewlines)
    }

    func testHeightGrowsWithWrappedAndExplicitLinesUpToTheCap() {
        let one = TaskInput.height(for: "一行", font: font, width: 400, minHeight: 24, maxLines: 10)
        XCTAssertEqual(one, 24, accuracy: 0.5, "单行时就是原来的高度")
        XCTAssertEqual(TaskInput.height(for: "", font: font, width: 400, minHeight: 24, maxLines: 10), 24, accuracy: 0.5)
        let three = TaskInput.height(for: "甲\n乙\n丙", font: font, width: 400, minHeight: 24, maxLines: 10)
        XCTAssertGreaterThan(three, one + 20, "显式换行也增高")
        XCTAssertGreaterThan(TaskInput.height(for: "甲\n", font: font, width: 400, minHeight: 24, maxLines: 10), one, "末尾的空行也算")
        let wide = TaskInput.height(for: long, font: font, width: 800, minHeight: 24, maxLines: 40)
        let narrow = TaskInput.height(for: long, font: font, width: 300, minHeight: 24, maxLines: 40)
        XCTAssertGreaterThan(narrow, wide, "越窄折行越多")
        XCTAssertGreaterThan(wide, one)
        let capped = TaskInput.height(for: long, font: font, width: 200, minHeight: 24, maxLines: 5)
        XCTAssertEqual(capped, 5 * ceil(font.ascender - font.descender + font.leading) + (24 - ceil(font.ascender - font.descender + font.leading)), accuracy: 0.5, "到上限为止")
    }

    func testGrowingHeightChangesOnlyByWholeLinesNearWrapBoundaries() {
        var previous: CGFloat = 24
        let line = ceil(font.ascender - font.descender + font.leading)
        for count in 1...240 {
            let height = TaskInput.height(for: String(repeating: "中文 English ", count: count),
                                          font: font, width: 180, minHeight: 24, maxLines: 6)
            XCTAssertGreaterThanOrEqual(height, previous, "输入变长时高度不能回跳")
            XCTAssertTrue(height == previous || abs(height - previous - line) < 0.5 || height == 24 + 5 * line,
                          "高度只应按完整行变化，不应出现亚像素抖动")
            previous = height
        }
    }

    /// 估算的高度不能比真实排版矮，否则最后一行会被裁掉。
    func testEstimateIsNeverShorterThanRealTextFieldLayout() {
        for width in [180.0, 260, 340, 480, 700] {
            let cell = NSTextFieldCell(textCell: long)
            cell.font = font
            cell.wraps = true
            cell.isScrollable = false
            cell.lineBreakMode = .byWordWrapping
            let real = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 10_000)).height
            let estimate = TaskInput.height(for: long, font: font, width: width, minHeight: 24, maxLines: 100)
            let lineHeight = ceil(font.ascender - font.descender + font.leading)
            XCTAssertGreaterThanOrEqual(estimate - (24 - lineHeight), real - 4, "宽 \(width)：估算 \(estimate) 不应明显低于真实 \(real)")
        }
    }

    func testSwiftUIReportsTheGrownHeightAndLegacySingleLineIsUntouched() {
        func fitted(_ view: TaskInput) -> NSSize {
            let host = NSHostingView(rootView: view.frame(width: 320))
            let window = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            Self.keepAlive += [window, host]
            return host.fittingSize
        }
        let short = fitted(input("短"))
        let tall = fitted(input(long))
        XCTAssertEqual(short.height, 24, accuracy: 1)
        XCTAssertGreaterThan(tall.height, short.height * 3, "粘贴大段内容后输入框自动增高")
        XCTAssertLessThanOrEqual(tall.height, 10 * 17 + 8, "不超过 10 行")
    }

    func testPastedNewlinesBecomeSpacesOnlyForSingleLineContent() {
        // 待办标题这种一行一条的场景（allowsNewlines: false，没单独说 collapsesPastedNewlines）才会把粘贴进来的换行变成空格；
        // 日志、笔记走的是 GrowingTaskInput，原样保留换行。
        var text = ""
        let todo = singleLine(allowsNewlines: false, text: Binding(get: { text }, set: { text = $0 }))
        let field = TaskTextField()
        let window = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = field
        Self.keepAlive += [window]
        window.makeFirstResponder(field)
        field.stringValue = "甲\n乙\n丙"
        if let editor = field.currentEditor() { editor.string = "甲\n乙\n丙" }
        todo.makeCoordinator().controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        XCTAssertEqual(text, "甲 乙 丙", "待办标题里粘贴的换行变成空格")
    }

    /// 添加待办框：外观是单行、回车直接提交，但 `collapsesPastedNewlines: false` 让粘贴的多行原样保留，
    /// 这样 `JournalStore.commitDraft` 才能把它们拆成好几条独立待办（见 QuickAddTests）。
    func testAddTodoInputKeepsPastedNewlinesSoEachLineBecomesItsOwnTask() {
        var text = ""
        let input = SingleLineTaskInput(text: Binding(get: { text }, set: { text = $0 }), focused: .constant(true),
                                         submit: {}, minHeight: 22, maxLines: 6, allowsNewlines: false, collapsesPastedNewlines: false)
        let field = TaskTextField()
        let window = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = field
        Self.keepAlive += [window]
        window.makeFirstResponder(field)
        field.stringValue = "明天 开会\n买牛奶"
        if let editor = field.currentEditor() { editor.string = "明天 开会\n买牛奶" }
        input.makeCoordinator().controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        XCTAssertEqual(text, "明天 开会\n买牛奶", "添加待办框粘贴多行不会被压成一行")
    }

    /// 日志、笔记这类多行输入框：普通 Enter 不拦截（交给系统换行），失焦只保留草稿。
    func testGrowingInputPlainEnterAndBlurDoNotSubmit() {
        var submitted = 0
        var text = ""
        let input = GrowingTaskInput(text: Binding(get: { text }, set: { text = $0 }), focused: .constant(true),
                                      submit: { submitted += 1 }, minHeight: 24, maxLines: 10)
        let editor = ImagePasteTextView()
        let coordinator = input.makeCoordinator()
        editor.delegate = coordinator
        editor.string = "第一行"
        XCTAssertFalse(coordinator.textView(editor, doCommandBy: #selector(NSResponder.insertNewline(_:))), "普通 Enter 不拦截，交给系统换行")
        XCTAssertEqual(submitted, 0)

        coordinator.textDidEndEditing(Notification(name: NSText.didEndEditingNotification, object: editor))
        XCTAssertEqual(submitted, 0, "失焦只保留草稿")
        XCTAssertEqual(text, "第一行")
    }

    private func keyEvent(modifiers: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil,
                         characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
    }

    /// 默认（`returnSubmits == false`，笔记/标签这类）：⌘Enter 提交，判断用触发这次按键的 `event` 本身
    /// （在 `keyDown` 里直接拦截，不走 `doCommandBy`：`NSApp.currentEvent`、「记录上一次 keyDown 再在
    /// doCommandBy 里读」都验证过不准，只有在真正触发按键的那次 `keyDown` 调用里判断才可靠）。普通 Enter 不拦截。
    /// 不断言 `super.keyDown` 之后的真实换行效果：脱离 window 的 `NSTextView` 走 `interpretKeyEvents`
    /// 行为不稳定，和真机不一致（这也是放弃「记录上一次按键再在 doCommandBy 里判断」这个方案的原因之一）。
    func testGrowingInputCommandReturnSubmitsPlainReturnDoesNot() {
        var submitted = 0
        let input = GrowingTaskInput(text: .constant("第一行"), focused: .constant(true),
                                      submit: { submitted += 1 }, minHeight: 24, maxLines: 10)
        let editor = ImagePasteTextView()
        let coordinator = input.makeCoordinator()
        editor.delegate = coordinator
        editor.onSubmitShortcut = { submitted += 1 }
        editor.string = "第一行"

        XCTAssertFalse(editor.shouldInterceptReturn(keyEvent(modifiers: [])), "普通 Enter 不拦截，交给系统换行")
        XCTAssertTrue(editor.shouldInterceptReturn(keyEvent(modifiers: .command)), "⌘Enter 拦截去提交")
    }

    /// 快速日志命令行用 `returnSubmits: true`：Enter 直接提交，Shift+Enter 换行（不拦截）。
    func testGrowingInputReturnSubmitsModeFlipsEnterAndShiftEnter() {
        let editor = ImagePasteTextView()
        editor.returnSubmits = true
        editor.mentionActive = { false }

        XCTAssertFalse(editor.shouldInterceptReturn(keyEvent(modifiers: .shift)), "Shift+Enter 不拦截，交给系统换行")
        XCTAssertTrue(editor.shouldInterceptReturn(keyEvent(modifiers: [])), "普通 Enter 拦截去提交")
        XCTAssertTrue(editor.shouldInterceptReturn(keyEvent(modifiers: .command)), "⌘Enter 是全应用统一的提交键，这里也提交")
    }

    /// `returnSubmits: true` 时，@/# 候选激活中按 Enter 要让 `doCommandBy` 去确认候选，不能被 `keyDown` 抢先提交。
    func testGrowingInputReturnSubmitsModeYieldsToActiveMention() {
        let editor = ImagePasteTextView()
        editor.returnSubmits = true
        editor.mentionActive = { true }

        XCTAssertFalse(editor.shouldInterceptReturn(keyEvent(modifiers: [])), "候选激活时不拦截，交给 doCommandBy 确认候选")
    }

    /// 待办标题这类单行场景（`allowsNewlines: false`）：Enter 始终提交，不受修饰键影响。
    func testSingleLineInputReturnAlwaysSubmits() {
        var submitted = 0
        var text = ""
        let input = SingleLineTaskInput(text: Binding(get: { text }, set: { text = $0 }), focused: .constant(true),
                                         submit: { submitted += 1 }, minHeight: 22, maxLines: 6, allowsNewlines: false)
        let editor = ImagePasteFieldEditorView()
        let coordinator = input.makeCoordinator()
        let field = TaskTextField()
        field.delegate = coordinator
        coordinator.field = field
        editor.string = "标题"

        XCTAssertTrue(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))), "单行场景 Enter 始终提交")
        XCTAssertEqual(submitted, 1)
    }

    private static var keepAlive: [AnyObject] = []
}

/// 快速浮窗的位置按顶边记：高度变了，顶边也不动。
@MainActor
final class QuickPanelPositionTests: XCTestCase {
    func testTopEdgeSurvivesAHeightChange() {
        let closed = NSRect(x: 300, y: 500, width: 520, height: 230)
        let saved = QuickCaptureController.topLeft(of: closed)
        // 下次打开时窗口先是 160 高，布局后长到 190：两种高度下顶边都回到同一处。
        for height in [160.0, 190, 230, 320] {
            let origin = QuickCaptureController.origin(topLeft: saved, height: height)
            XCTAssertEqual(origin.y + height, closed.maxY, accuracy: 0.001)
            XCTAssertEqual(origin.x, closed.minX)
        }
    }
}
