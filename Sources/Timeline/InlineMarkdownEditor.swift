import AppKit
import Combine
import SwiftUI
import WebKit
import TimelineCore

/// 日志、笔记的就地编辑：进入编辑时，这一条换成和工作板一样的所见即所得编辑器（只有光标所在的元素露出 Markdown 标记），
/// 点别处、Esc 或 ⌘↩ 保存并换回渲染好的正文。
///
/// 整个应用只有一个这样的编辑器（一份 WebKit 网页进程，和工作板那个分开，两个窗口可以同时用）：
/// 哪一条在编辑，编辑器就挪到哪一条里。网页里按条目分别存着撤销历史，回到刚编辑过的一条还能接着撤销。
@MainActor
final class InlineMarkdownEditor: NSObject, ObservableObject, WKScriptMessageHandler, WKNavigationDelegate {
    static let shared = InlineMarkdownEditor()

    struct Target: Equatable {
        let logID: UUID
        let date: Date
        /// 编辑的是这一天的每日总结（`logID` 是 `summaryID(for:)` 算出来的，不是真的日志）。
        var isSummary = false
    }

    /// 停顿多久把正在编辑的内容存一次（网页本身停顿 150 ms 才把文字交过来）。测试里调短。
    var autosaveDelay: TimeInterval = 0.8

    /// 编辑器所在的条目：正在编辑，或者提前排好版（`preparing`）。
    private(set) var target: Target?
    /// 只是提前排好版，还没开始编辑：不拿键盘焦点，正文照常显示。
    private(set) var preparing = false
    /// 编辑器已经画好、量出了高度：开始编辑时就把渲染好的正文换成编辑器，换的时候不闪。
    var height: CGFloat? { slot?.height }
    /// 每一条只订阅自己的状态：编辑器挪到哪一条，只有新旧两条重算。
    private var slots = NSMapTable<NSUUID, InlineEditSlot>.strongToWeakObjects()
    private var slot: InlineEditSlot?
    private var pendingPrepare: (id: UUID, work: DispatchWorkItem)?
    private var lastScroll = -TimeInterval.infinity
    private var shift: CGFloat = 0

    private(set) var webView: InlineEditorWebView?
    private var store: JournalStore?
    /// 数据里应该有的正文（最后一次读到或写入的，已去掉首尾空白）。数据和它不一样，就是别处改过了。
    private var original = ""
    /// 开始编辑时的正文：撤销一步回到这里。
    private var sessionStart = ""
    private var source = ""
    private var editedLog: DailyLogEntry?
    private var pendingAutosave: DispatchWorkItem?
    private var storeWatch: AnyCancellable?
    private var reconcilePending = false
    private var ready = false
    private var configured = false
    /// 编辑器的内容已经画到屏幕上了：这之后才把渲染好的正文换成编辑器（之前的高度消息不算）。
    private var painted = false
    private var settings: [String: Any] = [:]
    private var caret: CGPoint?
    private var selectsWord = false
    private var clickMonitor: Any?
    /// 测试里换成内存里的剪贴板。
    var pasteboard: NSPasteboard = .general

    override init() {
        super.init()
        for name in [Notification.Name.timelineCommitEditing, NSApplication.willTerminateNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(commitEditing), name: name, object: nil)
        }
    }

    func isEditing(_ id: UUID) -> Bool { target?.logID == id && !preparing }

    func slot(for id: UUID) -> InlineEditSlot {
        if let slot = slots.object(forKey: id as NSUUID) { return slot }
        let slot = InlineEditSlot()
        slots.setObject(slot, forKey: id as NSUUID)
        return slot
    }

    /// 延迟预备编辑器：先在这一条上面排好版（看不见、不拿焦点），点击时可直接接管。
    /// 正在编辑别的条目时不动。
    func prepareSoon(_ id: UUID, selected: Bool = false, _ prepare: @escaping () -> Void) {
        guard target == nil || preparing, target?.logID != id, pendingPrepare?.id != id,
              selected || ProcessInfo.processInfo.systemUptime - lastScroll > 0.2, !Headless.active || preparesInTests else { return }
        pendingPrepare?.work.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.pendingPrepare?.id == id else { return }
            self.pendingPrepare = nil
            prepare()
        }
        pendingPrepare = (id, work)
        // 选中先画出来，再预备当前这一条；连续切换或开始滚动时仍可取消。
        DispatchQueue.main.asyncAfter(deadline: .now() + (selected ? 0.04 : 0.12), execute: work)
    }

    func cancelPrepare(_ id: UUID) {
        guard pendingPrepare?.id == id else { return }
        pendingPrepare?.work.cancel()
        pendingPrepare = nil
    }

    func cancelPreparation() {
        pendingPrepare?.work.cancel()
        pendingPrepare = nil
        if preparing { end() }
    }

    func didScroll(in scroll: NSScrollView) {
        lastScroll = ProcessInfo.processInfo.systemUptime
        pendingPrepare?.work.cancel()
        pendingPrepare = nil
        if preparing, webView?.enclosingScrollView === scroll { end() }
    }

    /// 测试里也允许延迟预备（平时测试进程不预备，免得列表测试被打扰）。
    var preparesInTests = false

    /// 在正文上按下鼠标：编辑器已经在这一条上面排好、画好了，就开始编辑，返回编辑器，这一下（和之后的拖动、松开）交给它，
    /// 光标由编辑器自己放，和在工作板里点一样；还没准备好返回 nil，照旧松开后再换。
    func takeOver(_ event: NSEvent) -> NSView? {
        guard preparing, painted, !preparedIsStale, let webView, let window = webView.window, event.window === window, !webView.isHiddenOrHasHiddenAncestor,
              webView.bounds.contains(webView.convert(event.locationInWindow, from: nil)) else { return nil }
        activate(place: nil)
        return webView
    }

    /// 排好版之后这一条的正文又变了（撤销、同步……）：排好的版不能用，否则一打字就把新内容盖掉。
    private var preparedIsStale: Bool {
        guard preparing, let target, let store else { return false }
        return Self.storedText(target, in: store) != original
    }

    /// 数据里现在的正文；日志已经不在了是 nil。
    private static func storedText(_ target: Target, in store: JournalStore) -> String? {
        let entry = store.entry(for: target.date)
        return target.isSummary ? entry.summary : entry.logs.first { $0.id == target.logID }?.text
    }

    private static func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// 每日总结在编辑器和界面里用的编号：同一天总是同一个，按日期算出来。
    static func summaryID(for date: Date) -> UUID {
        let digits = JournalDates.key(date).filter(\.isNumber)
        return UUID(uuidString: "5A4D4D52-59DA-4000-8000-" + String(repeating: "0", count: max(0, 12 - digits.count)) + digits.suffix(12)) ?? UUID()
    }

    /// 开始编辑一条日志；`point` 是点在渲染好的正文上的位置（光标放到那里），nil 时放在末尾。
    /// `fontSize`、`lineSpacing` 和渲染好的正文一样（已乘界面缩放），编辑器按它们排版，每一行落在原来的位置上。
    /// `muted`：正文是用淡色画的（日记里专注期间的笔记、反馈），编辑器也用淡色。
    /// `prepare`：只提前排版，不进入编辑。
    func begin(_ log: DailyLogEntry, on date: Date, store: JournalStore, at point: CGPoint?, fontSize: CGFloat, lineSpacing: CGFloat,
               dark: Bool, muted: Bool = false, prepare: Bool = false) {
        open(Target(logID: log.id, date: date), text: log.text, store: store, at: point, fontSize: fontSize, lineSpacing: lineSpacing, dark: dark, muted: muted, prepare: prepare)
        if target?.logID == log.id { editedLog = log }
    }

    /// 开始编辑这一天的每日总结（可以是空的，从头写）。
    func beginSummary(on date: Date, store: JournalStore, at point: CGPoint?, fontSize: CGFloat, lineSpacing: CGFloat, dark: Bool) {
        open(Target(logID: Self.summaryID(for: date), date: date, isSummary: true), text: store.entry(for: date).summary, store: store,
             at: point, fontSize: fontSize, lineSpacing: lineSpacing, dark: dark, muted: false, prepare: false)
    }

    private func open(_ next: Target, text: String, store: JournalStore, at point: CGPoint?, fontSize: CGFloat, lineSpacing: CGFloat,
                      dark: Bool, muted: Bool, prepare: Bool) {
        guard !store.isReadOnly else { return }
        if prepare, target != nil, !preparing { return }
        if target?.logID == next.logID {
            if !preparing || text == original {
                if preparing, !prepare {
                    caret = point.map(caretPoint)
                    activate(place: placement(caret))
                }
                return
            }
            end()
        }
        cancelPrepare(next.logID)
        finish()
        self.store = store
        target = next
        preparing = prepare
        slot = slot(for: next.logID)
        slot?.height = nil
        slot?.phase = prepare ? .prepared : .editing
        original = text
        sessionStart = text
        source = text
        configured = false
        painted = false
        let metrics = InlineEditorMetrics.css(fontSize: fontSize, lineSpacing: lineSpacing)
        shift = metrics["shift"] ?? 0
        caret = point.map(caretPoint)
        var colors = BoardLiveEditorSession.colors(dark: dark)
        if muted { colors["ink"] = colors["muted"] }
        settings = ["key": "log." + next.logID.uuidString, "source": text, "inline": true, "readOnly": false, "sourceMode": false,
                    "fontSize": fontSize, "colors": colors, "dark": dark,
                    "metrics": metrics.merging(["tail": InlineEditorMetrics.tail(text, fontSize: fontSize, lineSpacing: lineSpacing)]) { $1 },
                    "labels": BoardLiveEditorSession.labels.merging(["copyCode": AppLocalized("复制"), "code": AppLocalized("代码")]) { $1 },
                    "folds": HeadingFolds.editorFolds(in: Self.foldID(next.logID))]
        _ = makeWebView()
        configure()
        if !prepare { watchClicks(); watchStore() }
    }

    /// 点的位置相对正文的文字区；编辑器的文字区左边多 2px 内边距、整篇往上提了 shift。
    private func caretPoint(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x + 2, y: point.y + shift) }

    private func placement(_ caret: CGPoint?) -> String {
        let place = caret.map { "window.boardEditor.placeCaret(\($0.x), \($0.y))" }
            ?? "window.boardEditor.focus(); window.boardEditor.select(window.boardEditor.snapshot().source.length)"
        return place + (selectsWord ? "; window.boardEditor.selectWordAtCaret()" : "")
    }

    /// 双击快于预备完成时，配置后仍保留双击选词语义。
    func selectClickedWord() {
        guard target != nil, !preparing else { return }
        selectsWord = true
        if configured { webView?.evaluateJavaScript("window.boardEditor.selectWordAtCaret()") }
    }

    /// 提前排好版的这一条开始编辑：拿键盘焦点；`place` 是放光标的脚本（nil：按下的鼠标交给网页，由它放）。
    private func activate(place: String?) {
        guard preparing, let webView else { return }
        preparing = false
        slot?.phase = .editing
        webView.window?.makeFirstResponder(webView)
        watchClicks()
        watchStore()
        // 还没配置好：配置时按 `caret` 放光标。
        if configured, let place { webView.evaluateJavaScript(place + "; 0") }
    }

    /// 保存并结束编辑（点了别处、换了窗口内容、应用退出）。
    /// `completion` 在网页交回最后几个字、存好之后调用（退出前要等它）；网页卡住时最多等一秒。
    func finish(completion: (() -> Void)? = nil) {
        guard let target, let store else { completion?(); return }
        if preparing { end(); completion?(); return }
        let webView = webView
        // 已经收到的文字先存下（网页卡住也不丢），收尾和撤销步留到拿到最后几个字时。
        autosave()
        let session = FinishedEdit(target: target, store: store, log: editedLog, start: sessionStart, base: original, fallback: source)
        if ready, configured, let webView {
            // 停顿后才送过来的最后几个字：取一次快照补存。
            var pending = completion
            var settled = false
            let settle: (String) -> Void = { text in
                guard !settled else { return }
                settled = true
                session.settle(text)
                pending?()
                pending = nil
            }
            webView.evaluateJavaScript("window.boardEditor.blur(); window.boardEditor.snapshot()") { result, _ in
                settle(((result as? [String: Any])?["source"] as? String) ?? session.fallback)
            }
            if completion != nil { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { settle(session.fallback) } }
        } else {
            session.settle(session.fallback)
            completion?()
        }
        end()
    }

    /// 结束编辑时的一份记录：网页交回最后的文字时，编辑器可能已经挪到别的条目上了。
    private struct FinishedEdit {
        let target: Target
        let store: JournalStore
        let log: DailyLogEntry?
        let start: String
        let base: String
        let fallback: String

        /// 写入最后的文字；这期间别处也改了就两份都留。
        @MainActor func settle(_ text: String) {
            let mine = InlineMarkdownEditor.trimmed(text)
            guard let stored = InlineMarkdownEditor.storedText(target, in: store) else {
                if let log, mine != InlineMarkdownEditor.trimmed(start) { store.restoreEditedLog(log, text: mine, on: target.date) }
                return
            }
            var final = mine
            if stored != base, mine != stored { final = mine == base ? stored : SyncMerge.keepingBoth(mine: mine, theirs: stored) }
            if target.isSummary { store.finishEditingSummary(from: start, text: final, on: target.date) }
            else { store.finishEditingLog(target.logID, from: start, text: final, on: target.date) }
        }
    }

    /// 编辑途中存一次：不结束编辑，不进撤销栈。正文临时删空时不写。
    private func autosave() {
        pendingAutosave?.cancel()
        pendingAutosave = nil
        guard let target, let store, !preparing else { return }
        // 别处的改动还没处理（通知排在主线程上）：先不写，免得把它盖掉。
        guard Self.storedText(target, in: store) == original else { reconcile(); return }
        let text = Self.trimmed(source)
        guard text != original, target.isSummary || !text.isEmpty else { return }
        original = text
        if target.isSummary { store.setSummary(text, on: target.date) }
        else { store.autosaveLog(target.logID, text: text, on: target.date) }
    }

    private func scheduleAutosave() {
        pendingAutosave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.autosave() }
        pendingAutosave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + autosaveDelay, execute: work)
    }

    /// 同步前调用：把编辑器里最新的文字存进数据（不结束编辑），这次同步才带得上，也才能和别处的改动正确合并。
    func flushForSync(completion: @escaping () -> Void) {
        guard target != nil, !preparing, ready, configured, let webView else { completion(); return }
        var pending: (() -> Void)? = completion
        let complete = { pending?(); pending = nil }
        webView.evaluateJavaScript("window.boardEditor.snapshot()") { [weak self] result, _ in
            defer { complete() }
            guard let self, let snapshot = result as? [String: Any], snapshot["composing"] as? Bool != true,
                  let text = snapshot["source"] as? String, self.target != nil else { return }
            self.source = text
            self.autosave()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: complete)
    }

    /// 编辑期间盯着数据：别处（同步）改了这一条要马上处理，不能等结束编辑时把它盖掉。
    private func watchStore() {
        guard storeWatch == nil, let store else { return }
        storeWatch = store.$days.dropFirst().sink { [weak self] _ in
            // 发布时数据还没换上，排到主线程下一轮再看。
            DispatchQueue.main.async { self?.reconcile() }
        }
    }

    private func reconcile() {
        guard !reconcilePending, let target, let store, !preparing else { return }
        guard Self.storedText(target, in: store) != original else { return }
        reconcilePending = true
        let finished = { [weak self] (text: String?, composing: Bool) in
            guard let self else { return }
            self.reconcilePending = false
            guard self.target == target else { return }
            if composing {
                // 正在用输入法选字：选完再说。
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.reconcile() }
                return
            }
            if let text { self.source = text }
            self.applyExternalChange()
        }
        guard ready, configured, let webView else { finished(nil, false); return }
        webView.evaluateJavaScript("window.boardEditor.snapshot()") { result, _ in
            let snapshot = result as? [String: Any]
            finished(snapshot?["source"] as? String, snapshot?["composing"] as? Bool == true)
        }
    }

    private func applyExternalChange() {
        guard let target, let store else { return }
        let mine = Self.trimmed(source)
        guard let stored = Self.storedText(target, in: store) else {
            // 这一条被别处删了：改过的内容存成新的一条，行本身已经不在了。
            if let editedLog, mine != Self.trimmed(sessionStart) { store.restoreEditedLog(editedLog, text: mine, on: target.date) }
            end()
            return
        }
        guard stored != original else { return }
        if mine == stored {
            original = stored
        } else if mine == original {
            // 这边没有新改动：换成别处的新内容，撤销也不再退到它之前。
            if original == Self.trimmed(sessionStart) { sessionStart = stored }
            original = stored
            source = stored
            pushSource(stored)
        } else {
            // 两边都改了：和同步冲突一样两份都留。
            let merged = SyncMerge.keepingBoth(mine: mine, theirs: stored)
            original = merged
            source = merged
            if target.isSummary { store.setSummary(merged, on: target.date) }
            else { store.autosaveLog(target.logID, text: merged, on: target.date) }
            pushSource(merged)
            NotificationCenter.default.post(name: .timelineEditorConflict, object: nil)
        }
    }

    private func pushSource(_ text: String) {
        guard let webView, ready, configured,
              let data = try? JSONSerialization.data(withJSONObject: [text]), let array = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.boardEditor.setSource(\(array)[0]); 0")
    }

    private func end() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        pendingAutosave?.cancel()
        pendingAutosave = nil
        storeWatch = nil
        reconcilePending = false
        editedLog = nil
        if let webView, let window = webView.window, window.firstResponder === webView || (window.firstResponder as? NSView)?.isDescendant(of: webView) == true {
            window.makeFirstResponder(nil)
        }
        target = nil
        preparing = false
        slot?.phase = .idle
        slot?.height = nil
        slot = nil
        caret = nil
        selectsWord = false
        configured = false
        painted = false
        store = nil
    }

    @objc private func commitEditing() { finish() }

    /// 点在编辑器外面（同一个窗口里的别处，或别的窗口）：保存并结束。点进来的这一下照常交给被点的地方。
    private func watchClicks() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let webView = self.webView, self.target != nil else { return }
                if event.window === webView.window, webView.window != nil {
                    let point = webView.convert(event.locationInWindow, from: nil)
                    if webView.bounds.contains(point) { return }
                }
                self.finish()
            }
            return event
        }
    }

    var hasTextFocus: Bool {
        guard let webView, let responder = webView.window?.firstResponder as? NSView else { return false }
        return responder === webView || responder.isDescendant(of: webView)
    }

    var handlesTextCommands: Bool { target != nil && webView?.window === NSApp.keyWindow && hasTextFocus }
    func undo() { webView?.evaluateJavaScript("window.boardEditor.undo()") }
    func redo() { webView?.evaluateJavaScript("window.boardEditor.redo()") }

    static func foldID(_ id: UUID) -> String { "log.\(id.uuidString)" }

    // MARK: 网页

    func makeWebView() -> InlineEditorWebView {
        if let webView { return webView }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = BoardLiveEditorSession.dataStore
        configuration.userContentController.add(WeakInlineHandler(self), name: "boardEditor")
        let view = InlineEditorWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 40), configuration: configuration)
        view.setValue(false, forKey: "drawsBackground")
        view.setAccessibilityLabel(AppLocalized("编辑 Markdown 内容"))
        view.navigationDelegate = self
        if let directory = BoardLiveEditorSession.editorDirectory {
            view.loadFileURL(directory.appendingPathComponent("index.html"), allowingReadAccessTo: directory)
        }
        webView = view
        return view
    }

    /// 笔记窗口出现后空闲时先把网页加载好，第一次点进编辑不用等。
    func preload() {
        guard webView == nil, !Headless.active else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(800))
            _ = makeWebView()
        }
    }

    /// 内存紧张时释放（没在编辑才放）。
    func release() {
        if preparing { end() }
        guard target == nil, let webView else { return }
        webView.removeFromSuperview()
        self.webView = nil
        ready = false
    }

    private func configure() {
        guard ready, target != nil, !configured, let webView,
              let data = try? JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys]) else { return }
        configured = true
        let json = String(decoding: data, as: UTF8.self)
        // 只是提前排版：不拿焦点、不放光标（光标不在里面时不露任何标记，排版和正文一样）。
        let place = preparing ? "" : placement(caret) + "; "
        if !preparing { webView.window?.makeFirstResponder(webView) }
        let target = self.target
        webView.evaluateJavaScript("window.boardEditor.configure(\(json)); \(place)0", completionHandler: nil)
        // 网页画好了才换：原生正文一直显示到那一刻，中间不会空一帧。
        webView.callAsyncJavaScript("return await window.boardEditor.painted()", arguments: [:], in: nil, in: .page) { [weak self] result in
            guard let self, self.target == target, case .success(let value) = result, let value = value as? Double, value > 0 else { return }
            self.reveal(CGFloat(value))
        }
        // 网页迟迟不画（比如窗口在后台）：最多等半秒，照样换过去。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.target == target, self.configured, !self.painted else { return }
            webView.evaluateJavaScript("window.boardEditor.height()") { result, _ in
                guard self.target == target, !self.painted, let value = result as? Double, value > 0 else { return }
                self.reveal(CGFloat(value))
            }
        }
    }

    private func reveal(_ value: CGFloat) {
        painted = true
        slot?.height = value
    }

    /// 编辑器挪进了这一条的位置（有窗口了）：拿键盘焦点，排好版。
    func attached() {
        guard let webView, webView.window != nil else { return }
        if configured { if !preparing { webView.window?.makeFirstResponder(webView) } } else { configure() }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let kind = body["kind"] as? String else { return }
        switch kind {
        case "ready":
            ready = true
            configure()
        case "change", "commit":
            guard body["key"] as? String == settings["key"] as? String, target != nil, let text = body["source"] as? String else { return }
            source = text
            if !preparing { scheduleAutosave() }
        case "height":
            guard target != nil, configured, painted, let value = body["value"] as? Double, value > 0 else { return }
            slot?.height = CGFloat(value)
        case "done":
            finish()
        case "fold":
            guard let target, let key = body["key"] as? String, let value = body["value"] as? Bool else { return }
            HeadingFolds.set(key, folded: value, in: Self.foldID(target.logID))
        case "open":
            if let value = body["url"] as? String, let url = TaskText.linkURL(value) { SafariLinks.open(url) }
        case "copy":
            guard let value = body["text"] as? String, let request = body["request"] as? Int else { return }
            pasteboard.clearContents()
            let success = pasteboard.setString(value, forType: .string)
            webView?.evaluateJavaScript("window.boardEditor.copyResult(\(request), \(success))")
        default:
            break
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .linkActivated {
            if let url = navigationAction.request.url.flatMap({ TaskText.linkURL($0.absoluteString) }) { SafariLinks.open(url) }
            decisionHandler(.cancel)
        } else { decisionHandler(BoardLiveEditorSession.allowsNavigation(to: navigationAction.request.url) ? .allow : .cancel) }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // 正在编辑时网页进程崩了：已经收到的内容先存下，重新载入后告诉用户一声（不然界面像是自己跳了一下）。
        if target != nil, !preparing { NotificationCenter.default.post(name: .timelineEditorRecovered, object: "inline") }
        autosave()
        // 重新载入后接着编辑最新的正文（开始编辑时记下的那份已经过期），光标放在末尾。
        settings["source"] = source
        caret = nil
        selectsWord = false
        ready = false
        configured = false
        painted = false
        webView.reload()
    }
}

/// 就地编辑器的版面数字：用和 `MarkdownText` 一样的字体、行距排一行量出来，传给网页做 CSS 变量（px）。
/// 这样编辑器里每一行的高度、段距和渲染好的正文一致，点进来编辑时文字不挪位置。
enum InlineEditorMetrics {
    private static var cache: [String: [String: Double]] = [:]

    @MainActor static func css(fontSize size: CGFloat, lineSpacing: CGFloat) -> [String: Double] {
        let key = "\(size)/\(lineSpacing)"
        if let cached = cache[key] { return cached }
        let body = NSFont.systemFont(ofSize: size)
        let (line, baseline) = measure(body, lineSpacing: lineSpacing)
        // 网页把行距上下平分、原生全加在下面：算出两边基线的差，整篇往上提这么多。WebKit 排版时字体的上下伸取整。
        let shift = max(0, cssBaseline(body, line: line) - baseline)
        var result: [String: Double] = ["line": line, "gap": Double(max(2, lineSpacing * 2)), "shift": shift]
        // 代码块的行（语言名那一行最明显：原生的最小行高把字压在行底）基线和正文不同：上面垫一点、行高减同样多，
        // 行的总高不变，基线落到原生的位置。
        func padded(_ name: String, _ font: NSFont, _ measured: (height: Double, baseline: Double)) {
            let pad = max(0, min(measured.height - 1, 2 * (measured.baseline + shift - cssBaseline(font, line: measured.height))))
            // WebKit 的行高取整数：零头放进上面垫的那一点里，总高仍是原生的行高。
            let line = (measured.height - pad).rounded(.down)
            result[name + "-line"] = line
            result[name + "-pad"] = measured.height - line
        }
        for level in 1...6 {
            let heading = size + CGFloat(7 - level) * 1.5
            result["h\(level)"] = Double(heading)
            result["h\(level)-line"] = measure(.systemFont(ofSize: heading, weight: .bold), lineSpacing: lineSpacing).height
        }
        result["code-size"] = Double(size * 0.92)
        let mono = NSFont.monospacedSystemFont(ofSize: size * 0.92, weight: .regular)
        padded("code", mono, measure(mono, lineSpacing: max(1, lineSpacing * 0.6)))
        result["code-label-size"] = Double(size * 0.8)
        let label = NSFont.systemFont(ofSize: size * 0.8, weight: .semibold)
        padded("code-label", label, measure(label, lineSpacing: lineSpacing, minimum: size * 1.7))
        cache[key] = result
        return result
    }

    /// 渲染好的正文最后一个换行后面还有一个空的行片段（原生的高度算上了它）：量出它的高度，编辑器底下留同样的空，
    /// 换成编辑器时下面的内容不往上跳。只和最后一段的样式有关（正文、代码、标题……），只排最后一块，
    /// 长笔记不用为这一个数把全文渲染一遍（选中一条就要算，在主线程上）。
    @MainActor static func tail(_ source: String, fontSize: CGFloat, lineSpacing: CGFloat) -> Double {
        var block = source
        // 折叠块的开头和结尾是分开的块，只排最后一块认不出来：整篇排。
        if !source.localizedCaseInsensitiveContains("</details"),
           let line = Array(MarkdownText.parse(source).children).last?.range?.lowerBound.line, line > 1 {
            block = source.components(separatedBy: "\n").dropFirst(line - 1).joined(separator: "\n")
        }
        let rendered = MarkdownText.render(block, color: .labelColor, fontSize: fontSize, lineSpacing: lineSpacing, scale: 1)
        guard rendered.length > 0 else { return 0 }
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

    /// 网页里这一行的基线到行顶的距离：行高减去字体上下伸（WebKit 取整）后上下平分。
    private static func cssBaseline(_ font: NSFont, line: Double) -> Double {
        let ascent = Double(font.ascender.rounded()), descent = Double((-font.descender).rounded())
        return (line - ascent - descent) / 2 + ascent
    }

    /// 一行字的高度（含行距）和基线到行顶的距离。
    private static func measure(_ font: NSFont, lineSpacing: CGFloat, minimum: CGFloat = 0) -> (height: Double, baseline: Double) {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        style.minimumLineHeight = minimum
        // 两行：最后一行不加行距，量第一行。
        let storage = NSTextStorage(string: "Hg\nHg", attributes: [.font: font, .paragraphStyle: style])
        let manager = NSLayoutManager()
        storage.addLayoutManager(manager)
        let container = NSTextContainer(size: NSSize(width: 1000, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        manager.ensureLayout(for: container)
        let used = manager.lineFragmentUsedRect(forGlyphAt: 0, effectiveRange: nil)
        return (Double(used.height), Double(manager.location(forGlyphAt: 0).y))
    }
}

/// 脚本消息处理器会被网页强引用：用弱引用转给编辑器，不形成循环。
private final class WeakInlineHandler: NSObject, WKScriptMessageHandler {
    weak var editor: InlineMarkdownEditor?
    init(_ editor: InlineMarkdownEditor) { self.editor = editor }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { editor?.userContentController(userContentController, didReceive: message) }
    }
}

/// 就地编辑的网页不自己滚动：上下滚动交给外面的列表，编辑时也能接着滚。
final class InlineEditorWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
            super.scrollWheel(with: event)
        } else if let scroll = superview?.enclosingScrollView {
            scroll.scrollWheel(with: event)
        } else {
            nextResponder?.scrollWheel(with: event)
        }
    }
}

/// 放就地编辑器的容器：哪一条在编辑，编辑器就挪到那一条的容器里。
/// 同一条可能同时出现在两处（笔记窗口里笔记页和日记页一直都在，隐藏的那页也有这一条，比如专注时记的笔记）：
/// 只有显示着的容器才拿编辑器，也不从显示着的容器那里抢，免得编辑器挂进看不见的那页、这边整条空白。
final class InlineEditorContainer: NSView {
    override var isFlipped: Bool { true }

    private var showing: Bool { window != nil && !isHiddenOrHasHiddenAncestor }

    func attach(_ editor: NSView) {
        guard editor.superview !== self else { return }
        editor.removeFromSuperview()
        editor.frame = bounds
        addSubview(editor)
    }

    /// 编辑器不在这里、这里显示着、编辑器现在待的地方看不见（或还没地方）：挪过来，开始排版 / 拿焦点。
    @MainActor func claim() {
        guard showing, let webView = InlineMarkdownEditor.shared.webView, webView.superview !== self else { return }
        if let other = webView.superview as? InlineEditorContainer, other.showing { return }
        attach(webView)
        InlineMarkdownEditor.shared.attached()
    }

    override func layout() {
        super.layout()
        for child in subviews where child.frame != bounds { child.frame = bounds }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        MainActor.assumeIsolated { claim() }
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        MainActor.assumeIsolated { claim() }
    }
}

/// 一条日志 / 笔记和就地编辑器的关系：没有、编辑器在上面排好版等着点、正在编辑。
@MainActor final class InlineEditSlot: ObservableObject {
    enum Phase { case idle, prepared, editing }
    @Published fileprivate(set) var phase = Phase.idle
    /// 编辑器画好后量出的高度。
    @Published fileprivate(set) var height: CGFloat?
}

struct InlineEditorHost: NSViewRepresentable {
    let editor: InlineMarkdownEditor
    @ObservedObject var slot: InlineEditSlot

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: InlineEditorContainer, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.bounds.width, height: proposal.height ?? nsView.bounds.height)
    }

    func makeNSView(context: Context) -> InlineEditorContainer {
        _ = editor.makeWebView()
        // 挂进窗口时（viewDidMoveToWindow）才拿编辑器：那时才知道这一处是不是显示着。
        return InlineEditorContainer()
    }

    func updateNSView(_ container: InlineEditorContainer, context: Context) {
        container.claim()
    }
}

/// 日志 / 笔记的正文：选中后可提前排版，进入编辑时才显示编辑器并拿焦点。
struct EditableLogText<Content: View>: View {
    private let editor = InlineMarkdownEditor.shared
    @ObservedObject private var slot: InlineEditSlot
    @ViewBuilder let content: (_ beginAt: ((CGPoint) -> Void)?) -> Content
    /// 开始编辑（点的位置）；第二个参数为 true 时只提前排版。
    let begin: (_ point: CGPoint?, _ prepare: Bool) -> Void
    let editable: Bool

    init(log: DailyLogEntry, editable: Bool, begin: @escaping (_ point: CGPoint?, _ prepare: Bool) -> Void,
         @ViewBuilder content: @escaping (_ beginAt: ((CGPoint) -> Void)?) -> Content) {
        self.init(id: log.id, editable: editable, begin: begin, content: content)
    }

    init(id: UUID, editable: Bool, begin: @escaping (_ point: CGPoint?, _ prepare: Bool) -> Void,
         @ViewBuilder content: @escaping (_ beginAt: ((CGPoint) -> Void)?) -> Content) {
        self.editable = editable
        self.begin = begin
        self.content = content
        _slot = ObservedObject(wrappedValue: InlineMarkdownEditor.shared.slot(for: id))
    }

    var body: some View {
        let shown = slot.phase == .editing && slot.height != nil
        // 编辑器一直是同一个视图：先在正文上面悄悄排版（几乎透明），画好后正文隐去、编辑器显出来，同一帧换过去。
        // 不换视图层级（换了网页要重新挂到窗口上，会白一下；新旧两个容器同时在时还会把网页抢回旧的那个，整块不见）。
        content(editable && !shown ? { begin($0, false) } : nil)
            .opacity(shown ? 0 : 1)
            .allowsHitTesting(!shown)
            .frame(height: shown ? slot.height : nil, alignment: .top)
            .overlay(alignment: .top) {
                if slot.phase != .idle {
                    InlineEditorHost(editor: editor, slot: slot)
                        .opacity(shown ? 1 : 0.01)
                        .allowsHitTesting(shown)
                }
            }
    }
}
