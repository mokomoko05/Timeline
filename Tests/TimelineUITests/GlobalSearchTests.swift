import AppKit
import XCTest
import TimelineCore
@testable import Timeline

@MainActor
final class GlobalSearchTests: XCTestCase {
    func testSearchFindsBoardContentWithMatchingLine() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        let board = try XCTUnwrap(store.ensureBoard(for: .tag("Reading")))
        store.setBoardMarkdown("# 议程\n\n  - 讨论 Transformer 结构\n- 其他", for: board.id)
        let other = try XCTUnwrap(store.ensureBoard(for: .tag("Old")))
        store.setBoardMarkdown("Transformer 旧笔记", for: other.id)

        let hits = AgendaView.searchHits(store: store, query: "transformer", filter: .all)
        let boards = hits.compactMap { hit -> (UUID, String)? in
            if case .board(let found, let line) = hit { return (found.id, line) }
            return nil
        }
        XCTAssertEqual(boards.map(\.0).sorted { $0.uuidString < $1.uuidString },
                       [board.id, other.id].sorted { $0.uuidString < $1.uuidString })
        XCTAssertTrue(boards.contains { $0.0 == board.id && $0.1 == "- 讨论 Transformer 结构" }, "命中的那一行去掉缩进后显示")
        XCTAssertTrue(AgendaView.searchHits(store: store, query: "", filter: .all).allSatisfy {
            if case .board = $0 { return false } else { return true }
        }, "空搜索不列出工作板")
    }
}

@MainActor
final class GlobalSearchPanelTests: XCTestCase {
    private let day = JournalDates.calendar.date(from: DateComponents(year: 2026, month: 10, day: 7))!

    private func makeStore() -> JournalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return JournalStore(directory: directory)
    }

    /// 工作板里每一处命中都单列一行，带上行号（点开跳到那一行）；行首的 Markdown 记号去掉。
    func testBoardHitsCarryTheirLineNumbers() throws {
        let store = makeStore()
        let board = try XCTUnwrap(store.ensureBoard(for: .tag("Reading")))
        store.setBoardMarkdown("# Transformer 议程\n\n- [ ] 读 transformer 论文\n其他\n> transformer 引用", for: board.id)
        let hits = GlobalSearch.hits(store: store, query: "transformer").filter { $0.kind == .board }
        XCTAssertEqual(hits.map(\.title), ["Transformer 议程", "读 transformer 论文", "transformer 引用"])
        XCTAssertEqual(hits.map(\.target), [1, 3, 5].map { .board(.tag("Reading"), line: $0) })
        XCTAssertTrue(GlobalSearch.hits(store: store, query: "  ").isEmpty, "空搜索不列结果")
    }

    /// 文字只在图片里：结果标成图片，标题是图片里命中的那一行，带上那张图；有关联待办的日志在笔记里打开。
    func testImageTextHitsCarryTheImageAndLinkedLogsOpenUnderTheirTask() throws {
        let store = makeStore()
        let task = try XCTUnwrap(store.addParsedTodo("读论文", on: day))
        let note = try XCTUnwrap(store.quickLogEntry("截图", images: ["shot.png"], taskID: task.id, on: day, now: day.addingTimeInterval(60)).entry)
        store.setImageTexts(["shot.png": "第一行\n注意力机制 Attention\n最后"])
        let plain = try XCTUnwrap(store.quickLogEntry("聊了 attention 的细节", on: day, now: day.addingTimeInterval(120)).entry)
        store.setSummary("今天\n收获：attention", on: day)

        let hits = GlobalSearch.hits(store: store, query: "attention")
        let image = try XCTUnwrap(hits.first { $0.kind == .image })
        XCTAssertEqual(image.title, "注意力机制 Attention")
        XCTAssertEqual(image.image, store.imageURL("shot.png"))
        XCTAssertEqual(image.target, .log(date: day, id: note.id, taskID: task.id))
        let log = try XCTUnwrap(hits.first { $0.kind == .log })
        XCTAssertEqual(log.target, .log(date: day, id: plain.id, taskID: nil), "没关联待办的在日记里打开")
        XCTAssertEqual(hits.last?.kind, .summary)
        XCTAssertEqual(hits.last?.title, "收获：attention")

        let model = GlobalSearchModel()
        model.store = store
        model.query = "attention"
        model.recompute()
        XCTAssertEqual(model.count(.images), 1)
        XCTAssertEqual(model.count(.logs), 2, "日志和每日总结")
        model.scope = .images
        XCTAssertEqual(model.hits.map(\.kind), [.image])
    }

    /// 多个词各自出现即可；待办能按拼音和首字母找到；标题正好是搜索词的排最前，其次是开头匹配。
    func testTermsPinyinAndRanking() throws {
        let store = makeStore()
        _ = try XCTUnwrap(store.addParsedTodo("整理论文笔记", on: day))
        _ = try XCTUnwrap(store.addParsedTodo("论文", on: day))
        _ = try XCTUnwrap(store.addParsedTodo("提交论文", on: day))
        _ = try store.quickLogEntry("预算的事明天和会议一起说", on: day, now: day.addingTimeInterval(60))
        _ = try store.quickLogEntry("只有会议", on: day, now: day.addingTimeInterval(120))

        let ranked = GlobalSearch.hits(store: store, query: "论文").filter { $0.kind == .task }.map(\.title)
        XCTAssertEqual(ranked.first, "论文", "完全相同的标题排第一")
        XCTAssertEqual(Set(ranked), ["论文", "整理论文笔记", "提交论文"])

        XCTAssertEqual(GlobalSearch.hits(store: store, query: "lunwen").filter { $0.kind == .task }.count, 3, "拼音")
        XCTAssertEqual(GlobalSearch.hits(store: store, query: "zllw").filter { $0.kind == .task }.map(\.title), ["整理论文笔记"], "拼音首字母")

        let logs = GlobalSearch.hits(store: store, query: "会议 预算").filter { $0.kind == .log }
        XCTAssertEqual(logs.map(\.title), ["预算的事明天和会议一起说"], "两个词都要出现，不必挨着")
    }

    /// 打字时走后台扫描：结果和同步算的一样；数据变了重新建语料。
    func testBackgroundSearchMatchesSynchronousResults() async throws {
        let store = makeStore()
        let board = try XCTUnwrap(store.ensureBoard(for: .tag("Reading")))
        store.setBoardMarkdown("一\n目标 needle 行", for: board.id)
        _ = try store.quickLogEntry("日志里的 needle", on: day)
        let model = GlobalSearchModel()
        model.store = store
        model.query = "needle"
        model.recomputeInBackground(resetSelection: true)
        for _ in 0..<100 where model.allHits.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.allHits, GlobalSearch.hits(store: store, query: "needle"))
        XCTAssertEqual(model.allHits.map(\.kind), [.board, .log])

        store.setBoardMarkdown("改掉了", for: board.id)
        model.recomputeInBackground(resetSelection: false)
        for _ in 0..<100 where model.allHits.count != 1 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.allHits.map(\.kind), [.log], "改过的工作板不再命中")
    }

    private static var keepAlive: [NotesWindowController] = []

    /// 笔记结果：笔记窗口打开到那个待办后，接住要定位的那条笔记（滚过去并闪一下）。
    func testNotesPageTakesTheNoteToReveal() throws {
        let store = makeStore()
        let task = try XCTUnwrap(store.addParsedTodo("读论文", on: day))
        let note = try XCTUnwrap(store.quickLogEntry("要找的那条", taskID: task.id, on: day).entry)
        let nav = NotesNavigation(defaults: InMemoryDefaults())
        let controller = NotesWindowController(nav: nav)
        Self.keepAlive.append(controller)
        nav.revealNote = note.id
        controller.show(store: store, taskID: task.id, reveal: { _ in }, openDay: { _ in })
        defer { controller.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        XCTAssertNil(nav.revealNote, "笔记页接住了定位请求")
        XCTAssertEqual(nav.selection, task.id)
    }

    /// 面板不依赖主窗口：直接打开、关闭；选中工作板结果后打开工作板并跳到那一行。
    func testPanelOpensOnItsOwnAndOpensBoardHitsAtTheirLine() throws {
        let store = makeStore()
        let board = try XCTUnwrap(store.ensureBoard(for: .tag("Panel")))
        store.setBoardMarkdown("一\n二\n目标行 needle", for: board.id)
        let controller = GlobalSearchController.shared
        controller.show(store: store)
        XCTAssertTrue(controller.isVisible)
        controller.model.query = "needle"
        controller.model.recompute()
        let hit = try XCTUnwrap(controller.model.hits.first)
        XCTAssertEqual(hit.target, .board(.tag("Panel"), line: 3))
        controller.open(hit)
        XCTAssertFalse(controller.isVisible, "打开结果后面板收起")
        XCTAssertEqual(BoardWindowController.shared.navigation.selection, board.id)
        BoardWindowController.shared.hide()
        controller.model.query = ""
    }
}

@MainActor
final class NotesSearchShortcutTests: XCTestCase {
    private static var keepAlive: [NotesWindowController] = []

    private func focusedPlaceholder(_ window: NSWindow) -> String? {
        guard let editor = window.firstResponder as? NSTextView, editor.isFieldEditor,
              let field = editor.delegate as? NSTextField else { return nil }
        return field.placeholderString
    }

    func testCommandFFocusesTheSearchFieldOfTheVisiblePage() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        let controller = NotesWindowController(nav: NotesNavigation(defaults: InMemoryDefaults()))
        Self.keepAlive.append(controller)
        controller.show(store: store, taskID: nil, reveal: { _ in }, openDay: { _ in })
        let window = try XCTUnwrap(controller.window)
        defer { controller.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        controller.workspace.focusSearch()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(focusedPlaceholder(window), AppLocalized("搜索任务或标签（#标签）"))

        controller.setDate(Date())
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        window.makeFirstResponder(nil)
        controller.workspace.focusSearch()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(focusedPlaceholder(window), AppLocalized("搜索日期或日志"), "日记页聚焦自己的搜索框，不是隐藏的笔记页")
    }
}
