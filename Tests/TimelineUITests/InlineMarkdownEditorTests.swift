import AppKit
import SwiftUI
import WebKit
import XCTest
import TimelineCore
@testable import Timeline

/// 日志、笔记点一下就地编辑：换成和工作板一样的所见即所得编辑器，跟着内容长高；Esc / ⌘↩ / 点别处保存并换回正文。
@MainActor
final class InlineMarkdownEditorTests: XCTestCase {
    private func wait(_ timeout: Duration = .seconds(8), _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("等待超时")
    }

    func testClickingALogEditsItInPlaceAndEscapeSaves() async throws {
        let defaults = InMemoryDefaults()
        let previous = HeadingFolds.defaults
        HeadingFolds.defaults = defaults
        defer { HeadingFolds.defaults = previous }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        let date = Date()
        store.setLogDraft("# 标题\n\n第一段 **加粗** 和 $x^2$\n\n- 一项\n- 两项", on: date)
        _ = try store.commitLog(on: date, linkDefault: false)
        let log = try XCTUnwrap(store.entry(for: date).logs.first)
        let editor = InlineMarkdownEditor.shared

        let root = VStack(alignment: .leading, spacing: 0) {
            EditableLogText(log: log, editable: true, begin: { point, _ in
                editor.begin(log, on: date, store: store, at: point, fontSize: 13, lineSpacing: 2, dark: true)
            }) { editAt in
                TaskLinkText(source: log.text, completed: false, color: Palette.ink, fontSize: 13, edit: {}, open: { _ in },
                             maxLines: 0, markdown: true, compactLines: true, editAt: editAt)
            }
            Text("下面的内容")
            Spacer(minLength: 0)
        }
        .frame(width: 380, height: 420, alignment: .top)
        let host = NSHostingView(rootView: root)
        let window = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 420), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { editor.finish(); window.contentView = nil; window.close() }

        host.layoutSubtreeIfNeeded()
        editor.begin(log, on: date, store: store, at: CGPoint(x: 30, y: 60), fontSize: 13, lineSpacing: 2, dark: true)
        XCTAssertTrue(editor.isEditing(log.id))
        try await wait { host.layoutSubtreeIfNeeded(); return editor.height != nil }
        let webView = try XCTUnwrap(editor.webView)
        // 排版稳定下来：原生层的高度和编辑器自己量的一致。
        try await wait {
            host.layoutSubtreeIfNeeded()
            let height = try? await webView.evaluateJavaScript("Math.ceil(window.boardEditor.view().dom.getBoundingClientRect().height)") as? Double
            return abs(CGFloat(height ?? 0) - webView.frame.height) < 2
        }
        XCTAssertTrue(webView.isDescendant(of: host), "编辑器放进了这一条")
        XCTAssertGreaterThan(webView.frame.height, 60, "跟着内容长高")
        let state = try await webView.evaluateJavaScript("""
        ({inline: document.documentElement.classList.contains('inline'),
          height: Math.ceil(window.boardEditor.view().dom.getBoundingClientRect().height),
          caret: window.boardEditor.snapshot().head,
          math: !!document.querySelector('.cm-math, .katex, [class*=math]'),
          debug: innerWidth + 'x' + innerHeight + ' lines:' + document.querySelectorAll('.cm-line').length})
        """) as? [String: Any] ?? [:]
        if let path = ProcessInfo.processInfo.environment["TIMELINE_DESIGN_PREVIEW"], !path.isEmpty {
            let image = try await webView.takeSnapshot(configuration: nil)
            if let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try png.write(to: URL(fileURLWithPath: path).appendingPathComponent("inline-editor.png"))
            }
        }
        XCTAssertEqual(state["inline"] as? Bool, true)
        XCTAssertEqual(CGFloat(state["height"] as? Double ?? 0), webView.frame.height, accuracy: 2, "原生层用的是编辑器量出来的高度")
        XCTAssertLessThan(state["caret"] as? Int ?? 999, log.text.count, "光标放在点的地方，不是末尾")

        // 打字：长高后原生层跟着变高。
        let before = webView.frame.height
        _ = try await webView.evaluateJavaScript("""
        (()=>{const v=window.boardEditor.view();v.dispatch({changes:{from:v.state.doc.length,insert:'\\n\\n新的一段\\n\\n再一段'},userEvent:'input.type'});})()
        """)
        try await wait { host.layoutSubtreeIfNeeded(); return (editor.height ?? 0) > before + 20 }

        // Esc 保存并结束。
        _ = try await webView.evaluateJavaScript("document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true,cancelable:true}))")
        try await wait { !editor.isEditing(log.id) }
        XCTAssertTrue(store.entry(for: date).logs.first?.text.hasSuffix("再一段") == true, "改动存进了日志")
    }

    func testClickOutsideSavesAndReadOnlyDoesNotEdit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        let date = Date()
        store.setLogDraft("原文", on: date)
        _ = try store.commitLog(on: date, linkDefault: false)
        let log = try XCTUnwrap(store.entry(for: date).logs.first)
        let editor = InlineMarkdownEditor.shared
        let root = EditableLogText(log: log, editable: true, begin: { _, _ in }) { _ in Text(log.text) }.frame(width: 300, height: 200, alignment: .top)
        let host = NSHostingView(rootView: root)
        let window = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { editor.finish(); window.contentView = nil; window.close() }
        editor.begin(log, on: date, store: store, at: nil, fontSize: 13, lineSpacing: 2, dark: false)
        try await wait { host.layoutSubtreeIfNeeded(); return editor.height != nil }
        let webView = try XCTUnwrap(editor.webView)
        _ = try await webView.evaluateJavaScript("""
        (()=>{const v=window.boardEditor.view();v.dispatch({changes:{from:v.state.doc.length,insert:'，补充'},userEvent:'input.type'});})()
        """)
        // 点在编辑器外面：保存并换回正文（最后几个字即使还没送过来，也会补存）。
        editor.finish()
        XCTAssertFalse(editor.isEditing(log.id))
        try await wait { store.entry(for: date).logs.first?.text == "原文，补充" }
    }

    private func host(_ log: DailyLogEntry) -> (NSHostingView<AnyView>, QuietWindow) {
        let root = AnyView(EditableLogText(log: log, editable: true, begin: { _, _ in }) { _ in Text(log.text) }.frame(width: 300, height: 200, alignment: .top))
        let host = NSHostingView(rootView: root)
        let window = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        return (host, window)
    }

    private func makeLog(_ text: String, directory: URL) throws -> (JournalStore, Date, DailyLogEntry) {
        let store = JournalStore(directory: directory)
        let date = Date()
        store.setLogDraft(text, on: date)
        _ = try store.commitLog(on: date, linkDefault: false)
        return (store, date, try XCTUnwrap(store.entry(for: date).logs.first))
    }

    private func type(_ text: String, in webView: WKWebView) async throws {
        _ = try await webView.evaluateJavaScript("(()=>{const v=window.boardEditor.view();v.dispatch({changes:{from:v.state.doc.length,insert:'\(text)'},userEvent:'input.type'});})()")
    }

    private func source(of webView: WKWebView) async -> String? {
        (try? await webView.evaluateJavaScript("window.boardEditor.snapshot().source")) as? String
    }

    /// 网页进程崩了：重新载入后接着编辑崩溃前的内容，结束编辑也不会把内容退回开始编辑时的样子。
    func testCrashRecoveryKeepsLatestTextAndFinishDoesNotRollBack() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (store, date, log) = try makeLog("原文", directory: directory)
        let (host, window) = host(log)
        let editor = InlineMarkdownEditor.shared
        defer { editor.finish(); window.contentView = nil; window.close() }
        editor.begin(log, on: date, store: store, at: nil, fontSize: 13, lineSpacing: 2, dark: false)
        try await wait { host.layoutSubtreeIfNeeded(); return editor.height != nil }
        let webView = try XCTUnwrap(editor.webView)
        try await type("，崩溃前", in: webView)
        try await Task.sleep(for: .milliseconds(300))

        _ = try await webView.evaluateJavaScript("window.beforeCrash = true; 0")
        editor.webViewWebContentProcessDidTerminate(webView)
        XCTAssertEqual(store.entry(for: date).logs.first?.text, "原文，崩溃前")
        try await wait {
            host.layoutSubtreeIfNeeded()
            let reloaded = (try? await webView.evaluateJavaScript("window.beforeCrash === undefined")) as? Bool
            let shown = await self.source(of: webView)
            return reloaded == true && shown == "原文，崩溃前"
        }
        try await type("，崩溃后", in: webView)
        var finished = false
        editor.finish { finished = true }
        try await wait { finished }
        XCTAssertEqual(store.entry(for: date).logs.first?.text, "原文，崩溃前，崩溃后")
    }

    /// 排好版之后正文变了（比如撤销）：点进去编辑的是最新正文，打字不会盖掉它。
    func testPreparedEditorPicksUpChangedTextBeforeEditing() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (store, date, log) = try makeLog("原文", directory: directory)
        let (host, window) = host(log)
        let editor = InlineMarkdownEditor.shared
        defer { editor.finish(); window.contentView = nil; window.close() }
        editor.begin(log, on: date, store: store, at: nil, fontSize: 13, lineSpacing: 2, dark: false, prepare: true)
        try await wait { host.layoutSubtreeIfNeeded(); return editor.height != nil }
        store.updateLog(log.id, text: "新内容", on: date)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 10, y: 190), modifierFlags: [], timestamp: 0,
                                                     windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        XCTAssertNil(editor.takeOver(event), "排好的版已经过期，不能直接接管鼠标")

        let fresh = try XCTUnwrap(store.entry(for: date).logs.first)
        editor.begin(fresh, on: date, store: store, at: nil, fontSize: 13, lineSpacing: 2, dark: false)
        XCTAssertTrue(editor.isEditing(log.id))
        let webView = try XCTUnwrap(editor.webView)
        try await wait {
            host.layoutSubtreeIfNeeded()
            let shown = await self.source(of: webView)
            return editor.height != nil && shown == "新内容"
        }
        try await type("x", in: webView)
        var finished = false
        editor.finish { finished = true }
        try await wait { finished }
        XCTAssertEqual(store.entry(for: date).logs.first?.text, "新内容x")
    }

    /// 退出前的 `finish`：刚打的字还没送到原生层（停顿 150 ms 才送），也要等网页交回来存好才算完。
    func testFinishWithCompletionWaitsForTheLastCharacters() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (store, date, log) = try makeLog("原文", directory: directory)
        let (host, window) = host(log)
        let editor = InlineMarkdownEditor.shared
        defer { window.contentView = nil; window.close() }
        editor.begin(log, on: date, store: store, at: nil, fontSize: 13, lineSpacing: 2, dark: false)
        try await wait { host.layoutSubtreeIfNeeded(); return editor.height != nil }
        try await type("，最后几个字", in: try XCTUnwrap(editor.webView))
        var finished = false
        editor.finish { finished = true }
        XCTAssertFalse(finished, "要等网页回话")
        try await wait { finished }
        XCTAssertEqual(store.entry(for: date).logs.first?.text, "原文，最后几个字", "回调时已经存好")
    }

    /// 打字停顿后就存进数据（应用崩溃不丢），不用等结束编辑；中途不进撤销栈，整段编辑撤销一步回到开始时。
    func testTypingAutosavesAndUndoReturnsToStart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (store, date, log) = try makeLog("原文", directory: directory)
        let (host, window) = host(log)
        let editor = InlineMarkdownEditor.shared
        editor.autosaveDelay = 0.05
        defer { editor.autosaveDelay = 0.8; editor.finish(); window.contentView = nil; window.close() }
        editor.begin(log, on: date, store: store, at: nil, fontSize: 13, lineSpacing: 2, dark: false)
        try await wait { host.layoutSubtreeIfNeeded(); return editor.height != nil }
        let webView = try XCTUnwrap(editor.webView)
        try await type("，第一段", in: webView)
        try await wait { store.entry(for: date).logs.first?.text == "原文，第一段" }
        XCTAssertTrue(editor.isEditing(log.id), "存盘不结束编辑")
        try await type("，第二段", in: webView)
        try await wait { store.entry(for: date).logs.first?.text == "原文，第一段，第二段" }
        // 临时删空：不能把日志删了。
        _ = try await webView.evaluateJavaScript("(()=>{const v=window.boardEditor.view();v.dispatch({changes:{from:0,to:v.state.doc.length,insert:''},userEvent:'delete'});})()")
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(store.entry(for: date).logs.first?.text, "原文，第一段，第二段")
        _ = try await webView.evaluateJavaScript("(()=>{const v=window.boardEditor.view();v.dispatch({changes:{from:0,insert:'原文，第一段，第二段'},userEvent:'input.type'});})()")
        var finished = false
        editor.finish { finished = true }
        try await wait { finished }
        store.undo()
        XCTAssertEqual(store.entry(for: date).logs.first?.text, "原文", "撤销一步回到开始编辑时")
    }

    /// 编辑时别处改了同一条：这边没有新改动就换成新内容；两边都改了两份都留，结束编辑也不会盖掉。
    func testExternalChangesAreAdoptedOrKeptBoth() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (store, date, log) = try makeLog("原文", directory: directory)
        let (host, window) = host(log)
        let editor = InlineMarkdownEditor.shared
        defer { editor.finish(); window.contentView = nil; window.close() }
        editor.begin(log, on: date, store: store, at: nil, fontSize: 13, lineSpacing: 2, dark: false)
        try await wait { host.layoutSubtreeIfNeeded(); return editor.height != nil }
        let webView = try XCTUnwrap(editor.webView)

        store.updateLog(log.id, text: "远端新内容", on: date)
        try await wait { await self.source(of: webView) == "远端新内容" }
        XCTAssertEqual(store.entry(for: date).logs.first?.text, "远端新内容")

        try await type("+本机", in: webView)
        store.updateLog(log.id, text: "远端第二次", on: date)
        try await wait { (await self.source(of: webView))?.contains("远端第二次") == true }
        let merged = await source(of: webView)
        XCTAssertTrue(merged?.hasPrefix("远端新内容+本机") == true, merged ?? "")
        XCTAssertTrue(merged?.contains("同步冲突") == true, merged ?? "")

        var finished = false
        editor.finish { finished = true }
        try await wait { finished }
        XCTAssertEqual(store.entry(for: date).logs.first?.text, merged)
    }

    /// 同步来的改动刚好排在结束编辑之前（通知还没处理）：同样两份都留。
    func testFinishKeepsBothWhenChangeArrivesAtTheLastMoment() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (store, date, log) = try makeLog("原文", directory: directory)
        let (host, window) = host(log)
        let editor = InlineMarkdownEditor.shared
        defer { window.contentView = nil; window.close() }
        editor.begin(log, on: date, store: store, at: nil, fontSize: 13, lineSpacing: 2, dark: false)
        try await wait { host.layoutSubtreeIfNeeded(); return editor.height != nil }
        try await type("+本机", in: try XCTUnwrap(editor.webView))
        try await Task.sleep(for: .milliseconds(250))
        store.updateLog(log.id, text: "原文+远端", on: date)
        var finished = false
        editor.finish { finished = true }
        try await wait { finished }
        let text = try XCTUnwrap(store.entry(for: date).logs.first?.text)
        XCTAssertTrue(text.contains("原文+本机") && text.contains("原文+远端"), text)
    }

    /// 正在编辑的日志被别处删了：改过的内容存成新的一条。
    func testEditedLogDeletedElsewhereIsKeptAsNewEntry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (store, date, log) = try makeLog("原文", directory: directory)
        let (host, window) = host(log)
        let editor = InlineMarkdownEditor.shared
        defer { editor.finish(); window.contentView = nil; window.close() }
        editor.begin(log, on: date, store: store, at: nil, fontSize: 13, lineSpacing: 2, dark: false)
        try await wait { host.layoutSubtreeIfNeeded(); return editor.height != nil }
        try await type("+本机", in: try XCTUnwrap(editor.webView))
        try await Task.sleep(for: .milliseconds(250))
        store.deleteLog(log.id, on: date)
        try await wait { store.entry(for: date).logs.first?.text == "原文+本机" }
        XCTAssertNotEqual(store.entry(for: date).logs.first?.id, log.id)
        XCTAssertFalse(editor.isEditing(log.id))
    }

    /// 同步前把编辑器里最新的文字交给数据，不结束编辑。
    func testFlushForSyncSavesWithoutEndingEditing() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (store, date, log) = try makeLog("原文", directory: directory)
        let (host, window) = host(log)
        let editor = InlineMarkdownEditor.shared
        defer { editor.finish(); window.contentView = nil; window.close() }
        editor.begin(log, on: date, store: store, at: nil, fontSize: 13, lineSpacing: 2, dark: false)
        try await wait { host.layoutSubtreeIfNeeded(); return editor.height != nil }
        try await type("+未停顿", in: try XCTUnwrap(editor.webView))
        var flushed = false
        editor.flushForSync { flushed = true }
        try await wait { flushed }
        XCTAssertEqual(store.entry(for: date).logs.first?.text, "原文+未停顿")
        XCTAssertTrue(editor.isEditing(log.id))
    }

    /// 文件拖到编辑器上会触发导航：编辑器目录以外的地方不能去，不然编辑器就没了。
    func testEditorCannotNavigateAwayFromItsDirectory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let outside = directory.appendingPathComponent("dropped.html")
        try "<html><body>dropped</body></html>".write(to: outside, atomically: true, encoding: .utf8)
        XCTAssertFalse(BoardLiveEditorSession.allowsNavigation(to: outside))
        XCTAssertFalse(BoardLiveEditorSession.allowsNavigation(to: nil))
        let index = try XCTUnwrap(BoardLiveEditorSession.editorDirectory).appendingPathComponent("index.html")
        XCTAssertTrue(BoardLiveEditorSession.allowsNavigation(to: index))
        let (store, date, log) = try makeLog("原文", directory: directory)
        let (host, window) = host(log)
        let editor = InlineMarkdownEditor.shared
        defer { editor.finish(); window.contentView = nil; window.close() }
        editor.begin(log, on: date, store: store, at: nil, fontSize: 13, lineSpacing: 2, dark: false)
        try await wait { host.layoutSubtreeIfNeeded(); return editor.height != nil }
        let webView = try XCTUnwrap(editor.webView)
        webView.load(URLRequest(url: outside))
        try await Task.sleep(for: .milliseconds(300))
        let shown = await source(of: webView)
        XCTAssertEqual(shown, "原文", "还在编辑器页面上")
    }

    /// 空的每日总结可以从头写，点别处保存，再打开接着改；撤销一步回到开始时。
    func testSummaryCardCreatesAndEditsSummary() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        let date = Date()
        let root = DaySummaryCard(store: store, date: date).frame(width: 500, height: 300, alignment: .top)
        let host = NSHostingView(rootView: root)
        let window = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        let editor = InlineMarkdownEditor.shared
        defer { editor.finish(); window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        let id = InlineMarkdownEditor.summaryID(for: date)
        XCTAssertEqual(id, InlineMarkdownEditor.summaryID(for: date), "同一天编号不变")

        editor.beginSummary(on: date, store: store, at: nil, fontSize: 13, lineSpacing: 2, dark: false)
        XCTAssertTrue(editor.isEditing(id))
        try await wait { host.layoutSubtreeIfNeeded(); return editor.height != nil }
        try await type("今天不错", in: try XCTUnwrap(editor.webView))
        var finished = false
        editor.finish { finished = true }
        try await wait { finished }
        XCTAssertEqual(store.entry(for: date).summary, "今天不错")
        XCTAssertTrue(JournalStore(directory: directory).days.isEmpty == false || store.hasPendingSave, "写了就会存盘")

        editor.beginSummary(on: date, store: store, at: nil, fontSize: 13, lineSpacing: 2, dark: false)
        try await wait { host.layoutSubtreeIfNeeded(); return editor.height != nil }
        try await type("，继续", in: try XCTUnwrap(editor.webView))
        finished = false
        editor.finish { finished = true }
        try await wait { finished }
        XCTAssertEqual(store.entry(for: date).summary, "今天不错，继续")
        store.undo()
        XCTAssertEqual(store.entry(for: date).summary, "今天不错")
    }

    private func beginEditing(_ text: String, directory: URL) async throws -> (JournalStore, Date, DailyLogEntry, QuietWindow, WKWebView) {
        let (store, date, log) = try makeLog(text, directory: directory)
        let (host, window) = host(log)
        InlineMarkdownEditor.shared.begin(log, on: date, store: store, at: nil, fontSize: 13, lineSpacing: 2, dark: false)
        try await wait { host.layoutSubtreeIfNeeded(); return InlineMarkdownEditor.shared.height != nil }
        return (store, date, log, window, try XCTUnwrap(InlineMarkdownEditor.shared.webView))
    }

    /// 收起标题时光标在里面：挪到标题行末尾，接着打字不会改到看不见的内容。
    func testFoldingMovesCaretOutOfHiddenContent() async throws {
        let defaults = InMemoryDefaults(), previous = HeadingFolds.defaults
        HeadingFolds.defaults = defaults
        defer { HeadingFolds.defaults = previous }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (_, _, _, window, webView) = try await beginEditing("# 甲\n\n正文\n\n# 乙\n\n别的", directory: directory)
        defer { InlineMarkdownEditor.shared.finish(); window.contentView = nil; window.close() }
        _ = try await webView.evaluateJavaScript("(()=>{const e=window.boardEditor;e.focus();e.select(6);})()")
        try await Task.sleep(for: .milliseconds(100))
        _ = try await webView.evaluateJavaScript("document.querySelector('.board-heading-fold').click();0")
        try await Task.sleep(for: .milliseconds(100))
        let head = try await webView.evaluateJavaScript("window.boardEditor.view().state.selection.main.head") as? Int
        XCTAssertEqual(head, 3, "标题行末尾")
        _ = try await webView.evaluateJavaScript("window.boardEditor.view().dispatch(window.boardEditor.view().state.replaceSelection('字'));0")
        let shown = await source(of: webView)
        XCTAssertEqual(shown, "# 甲字\n\n正文\n\n# 乙\n\n别的")
    }

    /// 就地编辑的无障碍标签说的是正在编辑的内容，不是「工作板」。
    func testInlineEditorAccessibilityLabel() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (_, _, _, window, webView) = try await beginEditing("原文", directory: directory)
        defer { InlineMarkdownEditor.shared.finish(); window.contentView = nil; window.close() }
        let label = try await webView.evaluateJavaScript("document.querySelector('.cm-content').getAttribute('aria-label')") as? String
        XCTAssertEqual(label, AppLocalized("编辑 Markdown 内容"))
    }

    /// 提前排好版后字号、深浅色变了：不能拿旧排版开始编辑。
    func testPreparedEditorFollowsLayoutChanges() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (store, date, log) = try makeLog("原文", directory: directory)
        let (host, window) = host(log)
        let editor = InlineMarkdownEditor.shared
        defer { editor.finish(); window.contentView = nil; window.close() }
        editor.begin(log, on: date, store: store, at: nil, fontSize: 13, lineSpacing: 2, dark: false, prepare: true)
        try await wait { host.layoutSubtreeIfNeeded(); return editor.height != nil }
        editor.begin(log, on: date, store: store, at: nil, fontSize: 16, lineSpacing: 2, dark: false, prepare: true)
        XCTAssertEqual(editor.settings["fontSize"] as? CGFloat, 16)
        try await wait { host.layoutSubtreeIfNeeded(); return editor.height != nil }
        editor.begin(log, on: date, store: store, at: nil, fontSize: 16, lineSpacing: 2, dark: true)
        XCTAssertEqual(editor.settings["dark"] as? Bool, true)
        XCTAssertTrue(editor.isEditing(log.id))
        editor.finish()

        // 窗口换了深浅色：鼠标按下时不接管旧排版。
        window.appearance = NSAppearance(named: .aqua)
        editor.begin(log, on: date, store: store, at: nil, fontSize: 13, lineSpacing: 2, dark: false, prepare: true)
        try await wait { host.layoutSubtreeIfNeeded(); return editor.height != nil }
        window.appearance = NSAppearance(named: .darkAqua)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 10, y: 190), modifierFlags: [], timestamp: 0,
                                                     windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        XCTAssertNil(editor.takeOver(event))
    }

    private static let pixel = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
    private func imageEvent(_ script: String) -> String {
        """
        (()=>{const bytes=Uint8Array.from(atob('\(Self.pixel)'),c=>c.charCodeAt(0));const dt=new DataTransfer();
        dt.items.add(new File([bytes],'a.png',{type:'image/png'}));
        const target=window.boardEditor.view().contentDOM;\(script);return 0})()
        """
    }

    /// 就地编辑时粘贴、拖入图片：加到这一条上，正文不变；文件拖上去网页不会跳走。
    func testPastingAndDroppingImagesAddsThemToTheLog() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (store, date, _, window, webView) = try await beginEditing("原文", directory: directory)
        defer { InlineMarkdownEditor.shared.finish(); window.contentView = nil; window.close() }
        _ = try await webView.evaluateJavaScript(imageEvent("target.dispatchEvent(new ClipboardEvent('paste',{clipboardData:dt,bubbles:true,cancelable:true}))"))
        try await wait { store.entry(for: date).logs.first?.images.count == 1 }
        _ = try await webView.evaluateJavaScript(imageEvent("target.dispatchEvent(new DragEvent('drop',{dataTransfer:dt,bubbles:true,cancelable:true}))"))
        try await wait { store.entry(for: date).logs.first?.images.count == 2 }
        let shown = await source(of: webView)
        XCTAssertEqual(shown, "原文")
        XCTAssertTrue(InlineMarkdownEditor.shared.isEditing(try XCTUnwrap(store.entry(for: date).logs.first?.id)))
    }

    /// 每日总结没有图片：不接管粘贴。
    func testSummaryDoesNotTakeImages() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        let date = Date()
        let id = InlineMarkdownEditor.summaryID(for: date)
        let (host, window) = host(DailyLogEntry(id: id, createdAt: date, kind: .note, text: ""))
        let editor = InlineMarkdownEditor.shared
        defer { editor.finish(); window.contentView = nil; window.close() }
        editor.beginSummary(on: date, store: store, at: nil, fontSize: 13, lineSpacing: 2, dark: false)
        try await wait { host.layoutSubtreeIfNeeded(); return editor.height != nil }
        XCTAssertEqual(editor.settings["acceptsImages"] as? Bool, false)
    }

    /// 只排最后一块量出来的尾部空白，和把全文排一遍一样。
    func testTailFromLastBlockMatchesFullRender() {
        func full(_ source: String) -> Double {
            let rendered = MarkdownText.render(source, color: .labelColor, fontSize: 13, lineSpacing: 2, scale: 1)
            let string = rendered.string as NSString
            let last = rendered.attributedSubstring(from: string.paragraphRange(for: NSRange(location: string.length - 1, length: 0)))
            let storage = NSTextStorage(attributedString: last)
            let manager = NSLayoutManager()
            storage.addLayoutManager(manager)
            let container = NSTextContainer(size: NSSize(width: 1000, height: CGFloat.greatestFiniteMagnitude))
            container.lineFragmentPadding = 0
            manager.addTextContainer(container)
            manager.ensureLayout(for: container)
            return Double(manager.extraLineFragmentUsedRect.height)
        }
        let intro = "# 标题\n\n第一段\n\n"
        for source in ["只有一段", intro + "结尾一段", intro + "## 结尾标题", intro + "- 一项\n- 两项", intro + "1. 一\n   - 嵌套",
                       intro + "> 引用\n> 第二行", intro + "```swift\nlet a = 1\n\nlet b = 2\n```", intro + "| 甲 | 乙 |\n| --- | --- |\n| 1 | 2 |",
                       intro + "---", intro + "$$\nx^2\n$$", intro + "<details>\n<summary>标题</summary>\n\n内容\n\n</details>"] {
            XCTAssertEqual(InlineEditorMetrics.tail(source, fontSize: 13, lineSpacing: 2), full(source), accuracy: 0.01, source)
        }
    }
}
