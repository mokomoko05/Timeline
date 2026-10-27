import AppKit
import SwiftUI
import XCTest
import TimelineCore
@testable import Timeline

/// 设计预览：把主要界面离屏渲染成 PNG，用于调整视觉时对照。
/// 默认跳过；`TIMELINE_DESIGN_PREVIEW=/输出目录 swift test --filter DesignPreviewTests` 时运行。
/// 窗口不排到屏幕上、不激活应用，渲染全程不打扰前台。
@MainActor
final class DesignPreviewTests: XCTestCase {
    private var output: URL!
    private var directory: URL!

    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["TIMELINE_DESIGN_PREVIEW"], !path.isEmpty else {
            throw XCTSkip("设置 TIMELINE_DESIGN_PREVIEW 时才渲染设计预览")
        }
        output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.sampleJournal().write(to: directory.appendingPathComponent("journal.json"))
        // 同一份示例数据也给 iPhone 模拟器截图用（scripts/screenshots-ios.sh）。
        try Self.sampleJournal().write(to: output.appendingPathComponent("sample-journal.json"))
        // README 截图用英文界面渲染（scripts/screenshots.sh 让测试进程的主 bundle 带上应用的 strings）。
        if let language = ProcessInfo.processInfo.environment["TIMELINE_PREVIEW_LANGUAGE"] {
            previousLanguage = UserDefaults.standard.string(forKey: Prefs.language)
            UserDefaults.standard.set(language, forKey: Prefs.language)
        }
    }

    private var previousLanguage: String?

    override func tearDown() {
        if ProcessInfo.processInfo.environment["TIMELINE_PREVIEW_LANGUAGE"] != nil {
            UserDefaults.standard.set(previousLanguage, forKey: Prefs.language)
        }
        if let directory { try? FileManager.default.removeItem(at: directory) }
        super.tearDown()
    }

    /// README 截图用的示例数据：待办散在这个月前后，过去的大多已完成并有专注时长，几天里有日志。
    private static func sampleJournal() throws -> Data {
        let today = JournalDates.calendar.startOfDay(for: Date())
        func stamp(_ day: Int = 0, hour: Int = 0, minute: Int = 0) -> Double {
            today.addingTimeInterval(Double(day * 86400 + hour * 3600 + minute * 60)).timeIntervalSinceReferenceDate
        }
        var days: [String: [String: Any]] = [:]
        var titles: [Int: (id: String, title: String, tags: [String])] = [:]
        var number = 0
        func entry(_ day: Int) -> String {
            let key = JournalDates.key(today.addingTimeInterval(Double(day * 86400)))
            if days[key] == nil { days[key] = ["todos": [], "logs": [], "summary": "", "deadlineDraft": "", "logDraft": ""] }
            return key
        }
        @discardableResult
        func task(_ title: String, _ priority: String = "normal", day: Int? = 0, hour: Int? = nil, done: Bool = false,
                  dropped: Bool = false, tags: [String] = [], minutes: Int = 0, created: Int? = nil) -> Int {
            number += 1
            let id = UUID().uuidString
            var value: [String: Any] = ["id": id, "number": number, "title": title, "priority": priority, "completed": done || dropped,
                                        "dueHasTime": hour != nil, "tags": tags, "focusSeconds": minutes * 60]
            if let day { value["dueDate"] = stamp(day, hour: hour ?? 0) }
            if dropped { value["dropped"] = true }
            let key = entry(created ?? min(day ?? 0, 0))
            days[key]!["todos"] = (days[key]!["todos"] as! [[String: Any]]) + [value]
            titles[number] = (id, title, tags)
            return number
        }
        func log(_ day: Int, _ hour: Int, _ minute: Int, _ text: String, task: Int? = nil, kind: String = "note",
                 tags: [String] = [], _ extra: [String: Any] = [:]) {
            var value: [String: Any] = ["id": UUID().uuidString, "createdAt": stamp(day, hour: hour, minute: minute), "kind": kind,
                                        "text": text, "tags": tags]
            if let task, let linked = titles[task] {
                value.merge(["taskID": linked.id, "taskNumber": task, "taskTitle": linked.title, "taskTags": linked.tags]) { $1 }
            }
            let key = entry(day)
            days[key]!["logs"] = (days[key]!["logs"] as! [[String: Any]]) + [value.merging(extra) { $1 }]
        }
        func focus(_ day: Int, _ hour: Int, task: Int, minutes: Int, goal: String, review: String) {
            log(day, hour, 0, "▶ Focus started · planned \(minutes) min", task: task,
                ["focus": true, "focusEvent": "start", "focusGoal": goal, "focusPlannedSeconds": minutes * 60])
            log(day, hour, minutes, review, task: task, ["focus": true, "focusEvent": "review"])
            log(day, hour, minutes, "■ Focus ended · \(minutes) min", task: task,
                ["focus": true, "focusEvent": "end", "focusElapsedSeconds": minutes * 60, "focusEndReason": "Phase complete"])
        }

        // 过去：大多已完成，带专注时长。
        let proposal = task("Draft the sync design proposal", "high", day: -24, done: true, tags: ["work"], minutes: 90)
        let ci = task("Set up CI for the iOS build", day: -20, done: true, tags: ["dev"], minutes: 45)
        let paper = task("Read “Attention Is All You Need”", day: -16, done: true, tags: ["reading"], minutes: 60)
        task("Dentist appointment", "lower", day: -13, hour: 15, done: true, tags: ["life"])
        let resolver = task("Refactor the conflict resolver", "high", day: -9, done: true, tags: ["dev"], minutes: 120)
        task("Weekly review", day: -6, done: true, tags: ["work"], minutes: 20)
        task("Try another note template", day: -5, dropped: true, tags: ["ideas"])
        let bench = task("Benchmark log scrolling", day: -3, done: true, tags: ["dev"], minutes: 50)
        task("Fix the flaky window test", day: -2, tags: ["dev"])
        // 今天。
        task("Team stand-up", day: 0, hour: 10, done: true, tags: ["work"])
        let highlight = task("Ship code-block highlighting", "high", day: 0, tags: ["dev"], minutes: 35)
        let flash = task("Read FlashAttention, note open questions", "high", day: 0, tags: ["reading"], minutes: 50)
        task("1:1 with mentor", day: 0, hour: 16, tags: ["work"])
        // 将来。
        task("Review open pull requests", day: 1, tags: ["dev"])
        task("Prepare demo-day slides", "high", day: 2, tags: ["work"])
        task("Renew passport", "lower", day: 4, tags: ["life"])
        task("Plan the next sprint", day: 6, tags: ["work"])
        task("Submit the conference talk", "high", day: 9, tags: ["work"])
        task("Weekend hike", "low", day: 11, tags: ["life"])
        // 没有日期。
        task("Learn Rust ownership", day: nil, tags: ["reading"])
        task("Reorganize the bookshelf", day: nil, tags: ["life"])

        focus(-24, 9, task: proposal, minutes: 50, goal: "Outline the three sync options", review: "Per-device files win: no write conflicts, easy merge.")
        log(-20, 14, 30, "CI runs the simulator build and the unit tests on every push.", task: ci, kind: "done")
        focus(-16, 20, task: paper, minutes: 60, goal: "Understand multi-head attention", review: "Scaled dot-product attention:\n\n$$\\mathrm{Attention}(Q,K,V)=\\mathrm{softmax}\\left(\\frac{QK^\\top}{\\sqrt{d_k}}\\right)V$$")
        focus(-9, 10, task: resolver, minutes: 45, goal: "Merge field by field", review: "Each field keeps the newest edit; conflicts get a marker instead of being dropped.")
        log(-6, 18, 0, "## Week in review\n\n- Sync proposal accepted\n- CI is green again\n- Next: scrolling performance", tags: ["work"])
        focus(-3, 15, task: bench, minutes: 50, goal: "Find the slow frame", review: "Layout was cached per width — scrolling went from 18 ms to 4 ms per frame.")
        log(-1, 17, 30, "First pass of the tokenizer: comments for `//`, `#` and `--`, strings with escapes.", task: highlight)
        log(-1, 21, 10, "Idea: the calendar should list tasks in the same order as the list.", tags: ["ideas"])
        log(0, 10, 20, "Stand-up: demo on Thursday, slides due tomorrow.", kind: "done")
        focus(0, 15, task: highlight, minutes: 35, goal: "Highlight Swift and Python", review: "Comments and strings are scanned together, so `//` inside a string is not a comment.")
        log(0, 15, 40, """
        ## Tokenizer notes

        One combined regex, left to right:

        ```swift
        let combined = "(" + comment + ")|(" + strings + ")"
        for match in regex.matches(in: code, range: full) {
            claim(match.range, isComment(match) ? .comment : .string)
        }
        ```

        - Keywords per language family
        - Cached by code + language
        """, task: highlight)
        focus(0, 11, task: flash, minutes: 25, goal: "Read the method, leave two questions", review: "Tiling keeps the softmax in SRAM; memory drops from $O(N^2)$ to $O(N)$.")
        log(0, 11, 30, """
        ## Online softmax

        Running max $m$ and sum $\\ell$ are updated per block:

        $$m^{new}=\\max(m, \\tilde m),\\quad \\ell^{new}=e^{m-m^{new}}\\ell+e^{\\tilde m-m^{new}}\\tilde\\ell$$

        1. Why is the backward pass recomputed instead of stored?
        2. How does block size depend on SRAM?
        """, task: flash)

        // 工作板：一个跟着任务，一个跟着标签。
        let now = Date()
        let boards = [
            Board(owner: .task(UUID(uuidString: titles[highlight]!.id)!), title: titles[highlight]!.title, markdown: """
            # Code-block highlighting

            - [x] Tokenizer for comments and strings
            - [x] Keywords per language family
            - [ ] Copy button on hover
            - [ ] Match the editor's colors

            ```python
            def tokens(code, language):
                return scan(code, family(language))
            ```
            """, now: now),
            Board(owner: .tag("reading"), title: "reading", markdown: """
            # Reading queue

            1. FlashAttention — **in progress**
            2. Ring Attention
            3. Mamba

            > Write one question per paper before reading it.
            """, now: now),
        ]
        let boardData = try JSONSerialization.jsonObject(with: JSONEncoder().encode(boards))
        let document: [String: Any] = ["version": 8, "nextTaskNumber": number + 1, "days": days, "boards": boardData]
        return try JSONSerialization.data(withJSONObject: document)
    }

    /// 离屏渲染：窗口从不排到屏幕上，只用来给视图提供外观和布局环境。
    private func render<Content: View>(_ name: String, size: NSSize, dark: Bool, _ content: Content) throws {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        let host = NSHostingView(rootView: LocalizedRoot { content })
        host.appearance = appearance
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.contentView = host
        defer { window.contentView = nil }
        host.frame = NSRect(origin: .zero, size: size)
        for _ in 0..<4 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        }
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        appearance.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: bitmap) }
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: output.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
    }

    func testRenderMainCaptureAndFocus() throws {
        let store = JournalStore(directory: directory)
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "tasksPaneExpanded")
        defaults.set(true, forKey: "tasksPaneExpanded")
        defer { defaults.set(previous, forKey: "tasksPaneExpanded") }
        let focus = FocusSession()
        focus.store = store
        if let task = store.sortedTasks().first(where: { $0.task.title.hasPrefix("Read FlashAttention") }) {
            focus.start(task: task, url: nil, plannedSeconds: 25 * 60, goal: "Read the method, leave two questions",
                        now: Date().addingTimeInterval(-7 * 60))
            focus.tick(now: Date())
        }
        defer { focus.stop(reason: "预览结束") }
        for dark in [true, false] {
            let interaction = WorkspaceInteraction()
            interaction.selectedTaskID = store.sortedTasks().first { $0.task.title.hasPrefix("Ship code-block") }?.id
            try render("main", size: NSSize(width: 1280, height: 1250), dark: dark,
                       ContentView(store: store, loginItem: LoginItem())
                .environmentObject(ReminderScheduler(store: store)).environmentObject(interaction)
                .environmentObject(CommandCenter()).environmentObject(ToastCenter()).environment(\.focusSession, focus))
            let model = QuickCaptureModel()
            model.mode = .log
            try render("capture", size: NSSize(width: 342, height: 170), dark: dark,
                       QuickCaptureView(store: store, model: model, close: {}, resize: { _ in }))
            try render("focus", size: NSSize(width: 340, height: 160), dark: dark, FocusPanelView(session: focus))
            // 玻璃效果放在一张模拟桌面上看。
            var companion = FocusPanelView(session: focus)
            companion.previewCompanion = true
            let picker = FocusSession()
            picker.store = store
            let backdrop = LinearGradient(colors: [Color(red: 0.35, green: 0.45, blue: 0.75), Color(red: 0.85, green: 0.55, blue: 0.45)],
                                          startPoint: .topLeading, endPoint: .bottomTrailing)
            try render("picker", size: NSSize(width: 380, height: 700), dark: dark, ZStack { backdrop; FocusPanelView(session: picker) })
            var picked = FocusPanelView(session: picker)
            picked.previewPicked = true
            try render("picked", size: NSSize(width: 380, height: 300), dark: dark, ZStack { backdrop; picked })
            try render("companion", size: NSSize(width: 340, height: 220), dark: dark, ZStack {
                LinearGradient(colors: [Color(red: 0.35, green: 0.45, blue: 0.75), Color(red: 0.85, green: 0.55, blue: 0.45)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                VStack(spacing: 14) { companion; FocusPanelView(session: focus).scaleEffect(0.82) }
            })
        }
    }

    func testRenderNotesAndJournal() throws {
        let store = JournalStore(directory: directory)
        let task = try XCTUnwrap(store.sortedTasks().first { $0.task.title.hasPrefix("Read FlashAttention") })
        for dark in [true, false] {
            let nav = NotesNavigation()
            nav.open(task: task.id)
            let notes = NotesWorkspaceNavigation()
            try render("notes", size: NSSize(width: 1000, height: 860), dark: dark,
                       UnifiedNotesView(store: store, workspace: notes, nav: nav, close: {}, reveal: { _ in }, openDay: { _ in }))
            let journal = NotesWorkspaceNavigation()
            journal.open(.journal, date: Date())
            try render("journal", size: NSSize(width: 1000, height: 860), dark: dark,
                       UnifiedNotesView(store: store, workspace: journal, nav: NotesNavigation(), close: {}, reveal: { _ in }, openDay: { _ in }))
        }
    }
}

extension DesignPreviewTests {
    func testRenderNotebookOutlineAndBoard() throws {
        let store = JournalStore(directory: directory)
        let calendar = JournalDates.calendar
        let today = calendar.startOfDay(for: Date())
        // 一个没有任何待办、只有直接记录的笔记本，跨越两个月。
        for (offset, texts) in [(-34, ["Flip it: write the conclusion first, then look for evidence"]), (-6, ["A passage from the weekend reading", "Chain cards by theme instead of by date"]),
                                (-2, ["## Sketch\n\n- Home shows three things only\n- Fold secondary info"]), (0, ["Today: the calendar should keep the list order"])] {
            let day = calendar.date(byAdding: .day, value: offset, to: today)!
            for (index, text) in texts.enumerated() {
                _ = try store.quickLogEntry(text, linkDefault: false, tags: ["ideas"], on: day,
                                            now: day.addingTimeInterval(TimeInterval(9 * 3600 + index * 1800)))
            }
        }
        // 有待办的笔记本里也有直接记录：目录在「直接记录」下面挂一串日期。
        for offset in [-40, -9, -1] {
            let day = calendar.date(byAdding: .day, value: offset, to: today)!
            _ = try store.quickLogEntry(["Bookmark: The Annotated Transformer", "Skim the KV-cache survey", "Reread chapter 3 slowly"][[-40, -9, -1].firstIndex(of: offset)!], linkDefault: false, tags: ["reading"], on: day,
                                        now: day.addingTimeInterval(10 * 3600))
        }
        for dark in [true, false] {
            let chapters = NotesNavigation()
            chapters.open(tag: "reading")
            chapters.outlineMode = .chapters
            try render("notebook-chapters", size: NSSize(width: 1180, height: 680), dark: dark,
                       NotesView(store: store, nav: chapters, reveal: { _ in }, openDay: { _ in }))
            let nav = NotesNavigation()
            nav.open(tag: "ideas")
            try render("notebook-outline", size: NSSize(width: 1180, height: 680), dark: dark,
                       NotesView(store: store, nav: nav, reveal: { _ in }, openDay: { _ in }))
            let narrow = NotesNavigation()
            narrow.open(tag: "ideas")
            narrow.chapterView = false
            try render("notebook-narrow", size: NSSize(width: 760, height: 560), dark: dark,
                       NotesView(store: store, nav: narrow, reveal: { _ in }, openDay: { _ in }))
            let defaults = InMemoryDefaults()
            let navigation = BoardNavigation(defaults: defaults)
            if let task = store.sortedTasks().first, let board = store.ensureBoard(for: .task(task.id)) {
                navigation.select(board.id)
                navigation.toggleFavorite(board.id)
            }
            if let tagBoard = store.ensureBoard(for: .tag("reading")) { navigation.toggleFavorite(tagBoard.id) }
            try render("board", size: NSSize(width: 410, height: 300), dark: dark,
                       BoardWorkspaceView(store: store, navigation: navigation))
            try render("board-switcher", size: NSSize(width: 410, height: 420), dark: dark,
                       BoardSwitcher(store: store, navigation: navigation, close: {}).padding(10).background(Palette.background))
        }
    }
}

/// 只读工作板的选区：不排窗口到屏幕上，检查鼠标按下不再被 CodeMirror 接管、复制取原生选区。
@MainActor
final class BoardBrowseSelectionProbe: XCTestCase {
    func testBrowseModeUsesNativeSelectionForDragAndCopy() async throws {
        guard ProcessInfo.processInfo.environment["TIMELINE_DESIGN_PREVIEW"] != nil else { throw XCTSkip("离屏探测，按需运行") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        let board = try XCTUnwrap(store.ensureBoard(for: .tag("Probe")))
        let source = "# 标题\n\n第一段 **加粗** 文字，[链接](https://example.com) 结尾。\n\n```\nlet code = 1\n```\n\n最后一段"
        store.setBoardMarkdown(source, for: board.id)
        let session = BoardLiveEditorSession(store: store, board: try XCTUnwrap(store.board(for: board.owner)))
        let webView = session.makeWebView()
        session.configure(fontSize: 13, dark: true)
        // WebKit 只在窗口排进窗口列表后加载页面：用测试专用的透明窗口（透明度 0、不接收鼠标、不成为键盘窗口）。
        let window = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 480), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.orderBack(nil)
        defer { window.contentView = nil; window.orderOut(nil) }
        try await waitForBoardEditor(webView)
        session.configure(fontSize: 13, dark: true)
        try await Task.sleep(for: .milliseconds(80))
        let result = try await webView.evaluateJavaScript("""
        (()=>{
          const editor=window.boardEditor, view=editor.view();
          const before=view.state.selection.main.head;
          const line=[...document.querySelectorAll('.cm-line')].find(l=>l.textContent.includes('第一段'));
          const r=line.getBoundingClientRect();
          line.dispatchEvent(new MouseEvent('mousedown',{bubbles:true,cancelable:true,clientX:r.left+40,clientY:r.top+5,button:0}));
          const prevented=false;
          document.dispatchEvent(new MouseEvent('mouseup',{bubbles:true,clientX:r.left+40,clientY:r.top+5,button:0}));
          const after=view.state.selection.main.head;
          const range=document.createRange(); const walker=document.createTreeWalker(line,NodeFilter.SHOW_TEXT);
          let node; const nodes=[]; while((node=walker.nextNode())) nodes.push(node);
          range.setStart(nodes[0],0); range.setEnd(nodes[nodes.length-1],nodes[nodes.length-1].length);
          const sel=window.getSelection(); sel.removeAllRanges(); sel.addRange(range);
          let copied=null;
          document.addEventListener('copy',e=>{setTimeout(()=>{},0)},{once:true});
          const event=new ClipboardEvent('copy',{bubbles:true,cancelable:true,clipboardData:new DataTransfer()});
          view.contentDOM.dispatchEvent(event);
          copied=event.clipboardData.getData('text/plain');
          const layer=getComputedStyle(document.querySelector('.cm-selectionLayer')).display;
          return {before,after,copied,visible:sel.toString(),layer};
        })()
        """) as? [String: Any] ?? [:]
        print("BOARD PROBE", result)
        XCTAssertEqual(result["before"] as? Int, result["after"] as? Int, "只读时按下鼠标不由 CodeMirror 重新定位")
        XCTAssertEqual(result["copied"] as? String, result["visible"] as? String, "复制的就是看到的选区")
        XCTAssertEqual(result["layer"] as? String, "none")
        XCTAssertTrue((result["copied"] as? String)?.contains("加粗") == true)
        XCTAssertEqual(store.boards.first?.markdown, source)
    }
}

/// 离屏探测：宿主视图是否会把窗口卡在完整面板的宽度上，导致收起后缩不小。
@MainActor
final class FocusDockProbe: XCTestCase {
    final class Model: ObservableObject { @Published var compact = false }
    struct Probe: View {
        @ObservedObject var model: Model
        var body: some View {
            Group {
                if model.compact { Color.red.frame(width: 213, height: 46) } else { Color.blue.frame(width: 340, height: 158) }
            }
        }
    }

    func testShrinkingTheWindowToTheCompanionSize() async throws {
        guard ProcessInfo.processInfo.environment["TIMELINE_DESIGN_PREVIEW"] != nil else { throw XCTSkip("离屏探测，按需运行") }
        for options in [nil, NSHostingSizingOptions()] as [NSHostingSizingOptions?] {
            let model = Model()
            let host = NSHostingView(rootView: Probe(model: model))
            if let options { host.sizingOptions = options }
            let window = QuietWindow(contentRect: NSRect(x: 600, y: 200, width: 340, height: 158), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderBack(nil)
            model.compact = true
            host.layoutSubtreeIfNeeded()
            window.setFrame(NSRect(x: 900, y: 200, width: 213, height: 46), display: true)
            try await Task.sleep(for: .milliseconds(50))
            print("DOCK PROBE options=\(options == nil ? "default" : "[]") frame=\(window.frame) min=\(window.contentMinSize)")
            window.contentView = nil
            window.orderOut(nil)
        }
    }
}

@MainActor
final class FocusControllerDockProbe: XCTestCase {
    func testCompanionDocksToTheNearestScreenEdge() async throws {
        guard ProcessInfo.processInfo.environment["TIMELINE_DESIGN_PREVIEW"] != nil else { throw XCTSkip("离屏探测，按需运行") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = InMemoryDefaults()
        FocusPanelView.allowCompanionInTests = true
        defer { FocusPanelView.allowCompanionInTests = false }
        let store = JournalStore(directory: directory)
        store.addTodo("探测任务", on: Date())
        let session = FocusSession()
        session.store = store
        let controller = FocusPanelController(session: session, defaults: defaults)
        session.start(task: try XCTUnwrap(store.tasks().first), url: nil, plannedSeconds: 1500)
        controller.refresh()
        try await Task.sleep(for: .seconds(3.5))
        // 只认最小的那一个（别的测试可能留着完整尺寸的面板）。
        let panel = try XCTUnwrap(NSApp.windows.filter { String(describing: type(of: $0)).contains("FocusPanel") && $0.isVisible }
            .min { $0.frame.width < $1.frame.width })
        let screen = (panel.screen ?? NSScreen.main)!.visibleFrame
        print("CONTROLLER DOCK frame=\(panel.frame) screen=\(screen)")
        XCTAssertEqual(panel.frame.maxX, screen.maxX - 6, accuracy: 1, "右半边收起时贴右边")
        XCTAssertLessThan(panel.frame.width, 300)
        // 拖到左半边：松手后贴到左边。
        panel.setFrameOrigin(NSPoint(x: screen.minX + 200, y: panel.frame.minY + 120))
        try await Task.sleep(for: .milliseconds(700))
        print("CONTROLLER DOCK left frame=\(panel.frame)")
        XCTAssertEqual(panel.frame.minX, screen.minX + 6, accuracy: 1, "左半边松手后贴左边")
        XCTAssertGreaterThan(panel.frame.minY, screen.minY + 100, "保留拖到的高度")
        XCTAssertFalse(FocusDock.shared.right, "贴左边后以左下角为锚点")
        // 从左边展开：窗口先变大，左边缘和底边不动。
        let collapsed = panel.frame
        FocusPanelView.allowCompanionInTests = false
        session.objectWillChange.send()
        try await Task.sleep(for: .milliseconds(300))
        print("CONTROLLER DOCK expanded frame=\(panel.frame)")
        XCTAssertEqual(panel.frame.minX, collapsed.minX, accuracy: 1, "从贴着的那条边向内展开")
        XCTAssertEqual(panel.frame.minY, collapsed.minY, accuracy: 1, "底边不动")
        XCTAssertGreaterThan(panel.frame.width, 300)
        session.stop(reason: "探测结束")
        panel.orderOut(nil)
    }
}

/// 离屏渲染变形过程的几帧：小伙伴展开成面板，检查是不是从贴边的角连续长出来。
@MainActor
final class FocusMorphFrames: XCTestCase {
    func testRenderMorphKeyframes() async throws {
        guard let path = ProcessInfo.processInfo.environment["TIMELINE_DESIGN_PREVIEW"] else { throw XCTSkip("离屏渲染，按需运行") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        store.addTodo("读一篇论文，整理方法与问题", on: Date())
        let session = FocusSession()
        session.store = store
        session.start(task: try XCTUnwrap(store.tasks().first), url: nil, plannedSeconds: 1500, goal: "读完方法部分")
        defer { session.stop(reason: "预览结束") }
        FocusPanelView.allowCompanionInTests = true
        defer { FocusPanelView.allowCompanionInTests = false }
        FocusDock.shared.right = true
        let size = NSSize(width: 380, height: 200)
        let host = NSHostingView(rootView: LocalizedRoot {
            ZStack {
                LinearGradient(colors: [Color(red: 0.35, green: 0.45, blue: 0.75), Color(red: 0.85, green: 0.55, blue: 0.45)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                FocusPanelView(session: session).padding(10)
            }
        })
        host.appearance = NSAppearance(named: .darkAqua)
        let window = QuietWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.contentView = nil; window.orderOut(nil) }
        try await Task.sleep(for: .seconds(3.2))
        func snap(_ name: String) throws {
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path).appendingPathComponent("morph-\(name).png"))
        }
        try snap("0-collapsed")
        FocusPanelView.allowCompanionInTests = false
        session.objectWillChange.send()
        for (index, delay) in [60, 120, 200, 450].enumerated() {
            try await Task.sleep(for: .milliseconds(delay - (index == 0 ? 0 : [60, 120, 200, 450][index - 1])))
            try snap("\(index + 1)-\(delay)ms")
        }
    }
}

@MainActor
final class FocusRailWindowProbe: XCTestCase {
    func testRailGrowsTheWindowUpwardKeepingTheBottom() async throws {
        guard ProcessInfo.processInfo.environment["TIMELINE_DESIGN_PREVIEW"] != nil else { throw XCTSkip("离屏探测，按需运行") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = InMemoryDefaults()
        let store = JournalStore(directory: directory)
        for title in ["一", "二", "三", "四"] { store.addTodo("任务" + title, on: Date()) }
        let session = FocusSession()
        session.store = store
        let controller = FocusPanelController(session: session, defaults: defaults)
        controller.toggleWorkspace()
        try await Task.sleep(for: .milliseconds(600))
        let panel = try XCTUnwrap(NSApp.windows.first { String(describing: type(of: $0)).contains("FocusPanel") && $0.isVisible })
        print("RAIL PROBE open frame=\(panel.frame)")
        let visible = (panel.screen ?? NSScreen.main)!.visibleFrame
        XCTAssertEqual(panel.frame.maxX, visible.maxX - 6, accuracy: 1, "默认靠右边")
        XCTAssertEqual(panel.frame.minY, visible.minY + 6, accuracy: 1, "默认靠底边")
        XCTAssertGreaterThan(panel.frame.height, 260, "时间轴展开时窗口包含浮层")
        let bottom = panel.frame.minY
        XCTAssertGreaterThanOrEqual(bottom, (panel.screen ?? NSScreen.main)!.visibleFrame.minY)
        // 收起、再展开时间轴：窗口大小和位置一点都不变（不变就不会跳）。
        let open = panel.frame
        for _ in 0..<2 {
            FocusPanelView.probeTogglePicking.send()
            try await Task.sleep(for: .milliseconds(700))
            print("RAIL PROBE toggled frame=\(panel.frame)")
            XCTAssertEqual(panel.frame, open, "切换时间轴不改窗口")
        }
        panel.orderOut(nil)
    }
}

extension DesignPreviewTests {
    func testRenderSearchPanel() throws {
        let store = JournalStore(directory: directory)
        let board = try XCTUnwrap(store.ensureBoard(for: .tag("reading")))
        store.setBoardMarkdown("# Attention papers\n\n- [ ] Compare FlashAttention with the original attention\n- Note how tiling changes memory", for: board.id)
        let backdrop = LinearGradient(colors: [Color(red: 0.35, green: 0.45, blue: 0.75), Color(red: 0.85, green: 0.55, blue: 0.45)],
                                      startPoint: .topLeading, endPoint: .bottomTrailing)
        for dark in [true, false] {
            for query in ["", "attention"] {
                let model = GlobalSearchModel()
                model.store = store
                model.query = query
                model.recompute()
                model.selection = 1
                let height = query.isEmpty ? GlobalSearchController.compactHeight : GlobalSearchController.expandedHeight
                try render(query.isEmpty ? "search-empty" : "search", size: NSSize(width: 720, height: height + 60), dark: dark, ZStack {
                    backdrop
                    GlobalSearchView(model: model, open: { _ in }, close: {}, resize: { _ in })
                        .frame(width: GlobalSearchController.width, height: height)
                })
            }
        }
    }
}
