import AppKit
import SwiftUI
import XCTest
@testable import Timeline
@testable import TimelineCore

@MainActor
final class MentionTests: XCTestCase {
    private static var keepAlive: [AnyObject] = []
    private let day = JournalDates.calendar.date(from: DateComponents(year: 2026, month: 10, day: 7))!

    private func makeStore() -> JournalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        for title in ["读论文 #论文", "写周报", "整理发票"] { _ = store.addParsedTodo(title, on: day) }
        return store
    }

    private func numbers(_ state: MentionState) -> [Int] {
        state.results.compactMap { if case .task(let t) = $0 { return t.task.number } else { return nil } }
    }

    // MARK: - 词元

    func testTokenNeedsAtAtWordStartAndCaretRightAfter() {
        func token(_ text: String, caret: Int? = nil) -> MentionToken? { MentionToken.find(in: text, caret: caret ?? (text as NSString).length) }
        XCTAssertEqual(token("@")?.query, "")
        XCTAssertEqual(token("@lw")?.query, "lw")
        XCTAssertEqual(token("今天读了 @论文")?.query, "论文")
        XCTAssertEqual(token("今天读了 @论文")?.range, NSRange(location: 5, length: 3))
        XCTAssertEqual(token("＠论文")?.query, "论文", "全角 @ 也算")
        XCTAssertNil(token("name@example.com"), "邮箱里的 @ 不触发")
        XCTAssertNil(token("@论文 读完了"), "光标已经离开这个词")
        XCTAssertEqual(token("@论文 读完了", caret: 3)?.query, "论文", "光标在词中间时取光标前的部分")
        XCTAssertNil(token("没有at符号"))
        XCTAssertNil(token("@" + String(repeating: "长", count: 40)), "太长的不是在找待办")
        XCTAssertEqual(token("@ni'hao")?.query, "nihao", "拼音输入法的分隔符去掉")
        XCTAssertEqual(token("第一行\n@周报")?.query, "周报", "换行后也算词开头")
    }

    // MARK: - 状态

    func testStateListsCandidatesNavigatesAndRespectsDismiss() {
        let store = makeStore()
        let state = MentionState()
        state.provider = MentionProviders.make(store: store)
        var picked: UUID?
        state.onPick = { if case .task(let t) = $0 { picked = t.id } }

        state.update(MentionToken(range: NSRange(location: 0, length: 1), query: ""))
        XCTAssertTrue(state.isActive)
        XCTAssertEqual(state.results.count, 3)
        state.move(1)
        XCTAssertEqual(state.selection, 1)
        state.move(-2)
        XCTAssertEqual(state.selection, 2, "到头后循环")

        state.update(MentionToken(range: NSRange(location: 0, length: 3), query: "zb"))
        XCTAssertEqual(numbers(state), [2], "按拼音首字母缩小")
        XCTAssertEqual(state.selection, 0, "查询变了，选择回到第一个")

        state.dismiss()
        XCTAssertFalse(state.isActive)
        state.update(MentionToken(range: NSRange(location: 0, length: 4), query: "zbz"))
        XCTAssertFalse(state.isActive, "Esc 关掉后继续往这个 @ 后面输入，不再弹出")
        state.update(nil)
        state.update(MentionToken(range: NSRange(location: 0, length: 1), query: ""))
        XCTAssertTrue(state.isActive, "删掉再重新输入 @ 又能弹出")

        let expected = state.results[state.selection].id
        let taken = state.take()
        XCTAssertEqual(taken?.item.id, expected)
        XCTAssertFalse(state.isActive, "取走之后关闭")
        XCTAssertNil(picked, "take 只取走，不触发 onPick（由输入框删掉 @ 之后再调）")
    }

    func testNoMatchHidesTheList() {
        let store = makeStore()
        let state = MentionState()
        state.provider = MentionProviders.make(store: store)
        state.update(MentionToken(range: NSRange(location: 0, length: 6), query: "完全没有"))
        XCTAssertFalse(state.isActive, "没有候选时不显示空列表，回车照常提交")
        XCTAssertNil(state.take())
    }

    // MARK: - 真实输入框

    /// mention（@ # 补全）只接在多行输入框上，走的是 `GrowingTaskInput`：这里直接用它的 `NSTextView` 当「输入框」。
    private func makeField(text: String, mention: MentionState, onSubmit: @escaping () -> Void = {}) -> (ImagePasteTextView, GrowingTaskInput.Coordinator, () -> String) {
        var value = text
        let input = GrowingTaskInput(text: Binding(get: { value }, set: { value = $0 }), focused: .constant(true), submit: onSubmit,
                                     minHeight: 24, maxLines: 6, mention: mention)
        let editor = ImagePasteTextView()
        let window = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = editor
        Self.keepAlive += [window]
        let coordinator = input.makeCoordinator()
        editor.delegate = coordinator
        coordinator.editor = editor
        window.makeFirstResponder(editor)
        editor.string = text
        editor.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        return (editor, coordinator, { value })
    }

    func testTypingAtOpensListAndAcceptingRemovesTheTokenAndPicksTheTask() throws {
        let store = makeStore()
        let state = MentionState()
        state.provider = MentionProviders.make(store: store)
        var picked: UUID?
        state.onPick = { if case .task(let t) = $0 { picked = t.id } }
        let (editor, coordinator, value) = makeField(text: "今天读了 @zb", mention: state)
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: editor))
        XCTAssertTrue(state.isActive)
        XCTAssertEqual(numbers(state).first, 2)

        XCTAssertTrue(coordinator.acceptMention())
        XCTAssertEqual(picked, store.locate(number: 2)?.id, "选中的是「写周报」")
        XCTAssertEqual(value(), "今天读了 ", "@zb 从输入框里删掉，前面的字保留")
        XCTAssertFalse(state.isActive)
    }

    func testEnterAcceptsWhileListIsOpenAndIsOtherwiseJustANewline() throws {
        let store = makeStore()
        let state = MentionState()
        state.provider = MentionProviders.make(store: store)
        var picked: UUID?
        state.onPick = { if case .task(let t) = $0 { picked = t.id } }
        var submitted = 0
        let (editor, coordinator, value) = makeField(text: "@", mention: state, onSubmit: { submitted += 1 })
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: editor))
        XCTAssertTrue(state.isActive)

        XCTAssertTrue(coordinator.textView(editor, doCommandBy: #selector(NSResponder.moveDown(_:))))
        XCTAssertEqual(state.selection, 1, "↑ ↓ 在列表里移动，不翻历史")
        XCTAssertTrue(coordinator.textView(editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(submitted, 0, "列表打开时回车是选择，不是提交")
        XCTAssertNotNil(picked)
        XCTAssertEqual(value(), "")

        editor.string = "写好了"
        XCTAssertFalse(coordinator.textView(editor, doCommandBy: #selector(NSResponder.insertNewline(_:))), "没有 @ 时回车只是换行，不拦截、不提交")
        XCTAssertEqual(submitted, 0)
    }

    func testEscapeClosesOnlyTheListAndTabAlsoAccepts() throws {
        let store = makeStore()
        let state = MentionState()
        state.provider = MentionProviders.make(store: store)
        var picked = 0
        state.onPick = { _ in picked += 1 }
        let (editor, coordinator, value) = makeField(text: "@", mention: state)
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: editor))

        XCTAssertTrue(coordinator.textView(editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertFalse(state.isActive)
        XCTAssertEqual(value(), "@", "Esc 只关列表，文字保留（窗口不会跟着关）")
        XCTAssertEqual(picked, 0)

        editor.string = "@"
        editor.selectedRange = NSRange(location: 1, length: 0)
        state.update(nil)
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: editor))
        XCTAssertTrue(coordinator.textView(editor, doCommandBy: #selector(NSResponder.insertTab(_:))))
        XCTAssertEqual(picked, 1, "Tab 也确认")
    }

    func testClickingARowAcceptsItEvenWhenFieldLostFocus() throws {
        let store = makeStore()
        let state = MentionState()
        state.provider = MentionProviders.make(store: store)
        var picked: UUID?
        state.onPick = { if case .task(let t) = $0 { picked = t.id } }
        let (editor, coordinator, value) = makeField(text: "读 @fp", mention: state)
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: editor))
        coordinator.bindMention()
        editor.window?.makeFirstResponder(nil)
        state.choose(0)
        XCTAssertEqual(picked, store.locate(number: 3)?.id, "点到「整理发票」")
        XCTAssertEqual(value(), "读 ", "输入框没有焦点时也把 @fp 删掉")
    }

    // MARK: - 视图

    func testMentionListRendersCandidatesAndLinkBarShowsPinnedState() {
        let store = makeStore()
        store.pinTask(store.locate(number: 2)!.id)
        let state = MentionState()
        state.provider = MentionProviders.make(store: store, contextTags: { ["论文"] })
        state.update(MentionToken(range: NSRange(location: 0, length: 1), query: ""))
        let view = VStack {
            MentionList(state: state, store: store, contextTags: ["论文"])
            LogChipsBar(store: store, link: .constant(nil), unlinked: .constant(false), tags: .constant(["论文"]))
        }.frame(width: 480)
        let host = NSHostingView(rootView: view)
        let window = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        Self.keepAlive += [window, host]
        XCTAssertGreaterThan(host.fittingSize.height, 100, "三行候选 + 提示 + 关联条")
        XCTAssertEqual(numbers(state).first, 2, "固定的排在带上下文标签的之前")
    }

    // MARK: - # 标签

    func testHashTriggerFindsTagsOnlyWhenEnabledAndAtWordStart() {
        let both: Set<MentionTrigger> = [.task, .tag]
        XCTAssertEqual(MentionToken.find(in: "读了 #论", caret: 5, triggers: both)?.trigger, .tag)
        XCTAssertEqual(MentionToken.find(in: "读了 #论", caret: 5, triggers: both)?.query, "论")
        XCTAssertNil(MentionToken.find(in: "读了 #论", caret: 5), "默认只认 @")
        XCTAssertNil(MentionToken.find(in: "C#", caret: 2, triggers: both), "C# 里的 # 不触发")
        XCTAssertEqual(MentionToken.find(in: "＃论文", caret: 3, triggers: both)?.trigger, .tag, "全角 ＃ 也算")
        XCTAssertEqual(MentionToken.find(in: "@zb #", caret: 5, triggers: both)?.trigger, .tag, "取光标前最近的一个")
    }

    func testTagCandidatesRankExcludeAndOfferCreate() {
        let store = makeStore()
        store.createTag("读书笔记")
        _ = store.addParsedTodo("看公式 #论文/方法", on: day)
        func names(_ query: String, excluding: [String] = []) -> [String] {
            store.tagCandidates(query: query, excluding: excluding).map { ($0.isNew ? "+" : "") + $0.name }
        }
        XCTAssertEqual(names("论"), ["论文", "论文/方法", "+论"], "开头匹配的已有标签在前，最后一项是新建")
        XCTAssertEqual(names("论文"), ["论文", "论文/方法"], "和已有标签完全一致时不再提供新建")
        XCTAssertEqual(names("dsbj"), ["读书笔记", "+dsbj"], "拼音首字母")
        XCTAssertEqual(names("论", excluding: ["论文"]), ["论文/方法", "+论"], "已选的不再出现")
        XCTAssertEqual(names("3"), [], "纯数字是任务编号，不是标签")
        XCTAssertTrue(names("").allSatisfy { !$0.hasPrefix("+") }, "只有 # 时列出已有标签，不提供新建")
    }

    func testPickingATagRemovesHashTokenAndReportsIt() throws {
        let store = makeStore()
        let state = MentionState()
        state.triggers = [.task, .tag]
        state.provider = MentionProviders.make(store: store)
        var tags: [String] = []
        state.onPick = { if case .tag(let tag) = $0 { tags.append(tag.name) } }
        let (editor, coordinator, value) = makeField(text: "今天读了 #论", mention: state)
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: editor))
        XCTAssertTrue(state.isActive)
        XCTAssertEqual(state.token?.trigger, .tag)
        XCTAssertTrue(coordinator.acceptMention())
        XCTAssertEqual(tags, ["论文"])
        XCTAssertEqual(value(), "今天读了 ")
    }

    func testChosenTagsAndLinkNeverChangeTheQuickPanelHeight() {
        let store = makeStore()
        let model = QuickCaptureModel()
        model.mode = .log
        func height() -> CGFloat {
            let host = NSHostingView(rootView: QuickCaptureView(store: store, model: model, close: {}, resize: { _ in }))
            host.setFrameSize(NSSize(width: 520, height: 160))
            host.layoutSubtreeIfNeeded()
            return host.fittingSize.height
        }
        let bare = height()
        model.tags = ["论文", "读书笔记", "很长很长的标签名称一二三四五六七", "甲", "乙", "丙", "丁"]
        model.link = store.locate(number: 1)?.id
        XCTAssertEqual(height(), bare, accuracy: 0.5, "选了标签和待办，窗口高度不变，不用再「展开」")
    }

    func testAtCompletionFindsCompletedAndDroppedTasksAfterOpenOnes() {
        let store = makeStore()   // 读论文 / 写周报 / 整理发票
        _ = store.addParsedTodo("论文终稿", on: day)
        _ = store.addParsedTodo("论文参考文献", on: day)
        store.toggleTodo(store.locate(number: 1)!.id, on: store.locate(number: 1)!.date)
        store.dropTodo(store.locate(number: 5)!.id, on: store.locate(number: 5)!.date)
        let state = MentionState()
        state.provider = MentionProviders.make(store: store)
        state.update(MentionToken(range: NSRange(location: 0, length: 3), query: "论文"))
        XCTAssertEqual(numbers(state), [4, 5, 1], "未完成的在前；已完成（#1）、已放弃（#5）也搜得到，关闭的这一组内部仍按匹配度排（#5 以「论文」开头，比 #1 包含更靠前）")
        state.update(MentionToken(range: NSRange(location: 0, length: 3), query: "lw"))
        XCTAssertEqual(Set(numbers(state)), [1, 4, 5], "拼音首字母同样能搜到")
    }
}
