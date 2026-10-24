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
    }

    override func tearDown() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        super.tearDown()
    }

    /// 与 scripts/screenshots.py 相同的示例数据。
    private static func sampleJournal() throws -> Data {
        let today = JournalDates.calendar.startOfDay(for: Date())
        func stamp(_ day: Int = 0, hour: Int = 0, minute: Int = 0) -> Double {
            today.addingTimeInterval(Double(day * 86400 + hour * 3600 + minute * 60)).timeIntervalSinceReferenceDate
        }
        func task(_ number: Int, _ title: String, _ priority: String, day: Int = 0, completed: Bool = false, tags: [String], minutes: Int = 0) -> [String: Any] {
            ["id": UUID().uuidString, "number": number, "title": title, "priority": priority, "completed": completed,
             "dueDate": stamp(day), "dueHasTime": false, "tags": tags, "focusSeconds": minutes * 60]
        }
        func undated(_ number: Int, _ title: String, dropped: Bool = false, tags: [String]) -> [String: Any] {
            var value = task(number, title, "normal", completed: dropped, tags: tags)
            value.removeValue(forKey: "dueDate")
            if dropped { value["dropped"] = true }
            return value
        }
        func timed(_ number: Int, _ title: String, hour: Int, tags: [String]) -> [String: Any] {
            var value = task(number, title, "normal", tags: tags)
            value["dueDate"] = stamp(hour: hour); value["dueHasTime"] = true
            return value
        }
        let tasks = [
            timed(6, "组会同步进度", hour: 1, tags: ["研究"]),
            timed(7, "给合作者回邮件", hour: 23, tags: []),
            task(1, "读一篇论文，整理方法与问题", "high", tags: ["阅读"], minutes: 50),
            task(2, "收集相关资料", "normal", completed: true, tags: ["阅读"], minutes: 25),
            task(3, "试着复现一个小实验", "normal", tags: ["研究"], minutes: 35),
            task(4, "整理这一周的阅读笔记", "lower", day: 1, tags: ["阅读"]),
            task(5, "给下一个项目画张草图", "low", day: 3, tags: ["想法"]),
            undated(8, "整理书单", tags: ["阅读"]),
            undated(9, "试用新的笔记模板", dropped: true, tags: ["想法"]),
            undated(10, "学一门新语言", tags: []),
            undated(11, "重写旧博客", dropped: true, tags: []),
        ]
        let first = tasks[2]["id"] as! String
        func log(_ hour: Int, _ minute: Int, _ text: String, kind: String = "note", _ extra: [String: Any] = [:]) -> [String: Any] {
            ["id": UUID().uuidString, "createdAt": stamp(hour: hour, minute: minute), "kind": kind, "text": text,
             "taskID": first, "taskNumber": 1, "taskTitle": "读一篇论文，整理方法与问题", "taskTags": ["阅读"]].merging(extra) { $1 }
        }
        let logs = [
            log(9, 0, "▶ 开始专注 · 计划 25 min", ["focus": true, "focusEvent": "start", "focusGoal": "看懂方法部分，留下两个问题", "focusPlannedSeconds": 1500]),
            log(9, 12, "## 一个值得继续看的思路\n\n先用小规模实验验证假设，再考虑完整实现。\n\n- 记录对比条件\n- 解释结果的差异", ["focusEvent": "note"]),
            log(9, 25, "方法部分读完了。下一轮先验证边界条件。", ["focus": true, "focusEvent": "review"]),
            log(9, 25, "■ 结束专注 · 用时 25 min · 累计 1 h 15 min · 阶段结束", ["focus": true, "focusEvent": "end", "focusElapsedSeconds": 1500, "focusEndReason": "阶段结束"]),
            log(10, 5, "整理好参考资料，下午开始实验。", kind: "done"),
        ]
        let document: [String: Any] = ["version": 6, "nextTaskNumber": 12, "days": [
            JournalDates.key(today): ["todos": tasks, "logs": logs, "summary": "", "deadlineDraft": "", "logDraft": ""],
        ]]
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
        if let task = store.sortedTasks().first(where: { !$0.task.completed }) {
            focus.start(task: task, url: nil, plannedSeconds: 25 * 60, goal: "读完方法部分，记下两个问题",
                        now: Date().addingTimeInterval(-7 * 60))
            focus.tick(now: Date())
        }
        defer { focus.stop(reason: "预览结束") }
        for dark in [true, false] {
            try render("main", size: NSSize(width: 1280, height: 1250), dark: dark,
                       ContentView(store: store, loginItem: LoginItem())
                .environmentObject(ReminderScheduler(store: store)).environmentObject(WorkspaceInteraction())
                .environmentObject(CommandCenter()).environmentObject(ToastCenter()).environment(\.focusSession, focus))
            let model = QuickCaptureModel()
            model.mode = .log
            try render("capture", size: NSSize(width: 342, height: 170), dark: dark,
                       QuickCaptureView(store: store, model: model, close: {}, resize: { _ in }))
            try render("focus", size: NSSize(width: 340, height: 160), dark: dark, FocusPanelView(session: focus))
        }
    }

    func testRenderNotesAndJournal() throws {
        let store = JournalStore(directory: directory)
        let task = try XCTUnwrap(store.sortedTasks().first)
        for dark in [true, false] {
            let nav = NotesNavigation()
            nav.open(task: task.id)
            let notes = NotesWorkspaceNavigation()
            try render("notes", size: NSSize(width: 1000, height: 680), dark: dark,
                       UnifiedNotesView(store: store, workspace: notes, nav: nav, close: {}, reveal: { _ in }, openDay: { _ in }))
            let journal = NotesWorkspaceNavigation()
            journal.open(.journal, date: Date())
            try render("journal", size: NSSize(width: 1000, height: 680), dark: dark,
                       UnifiedNotesView(store: store, workspace: journal, nav: NotesNavigation(), close: {}, reveal: { _ in }, openDay: { _ in }))
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
        session.configure(fontSize: 13, dark: true, previewOnly: true)
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
