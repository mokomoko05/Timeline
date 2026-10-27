import AppKit
import SwiftUI
import WebKit
import TimelineCore

/// 日志、笔记的就地编辑：点一下正文，这一条就换成和工作板一样的所见即所得编辑器（只有光标所在的元素露出 Markdown 标记），
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
    }

    /// 正在编辑的条目。
    @Published private(set) var target: Target?
    /// 编辑器已经排好版、量出了高度：这时才把渲染好的正文换成编辑器，换的时候不闪。
    @Published private(set) var height: CGFloat?

    private(set) var webView: InlineEditorWebView?
    private var store: JournalStore?
    private var original = ""
    private var source = ""
    private var composing = false
    private var ready = false
    private var configured = false
    private var settings: [String: Any] = [:]
    private var caret: CGPoint?
    private var clickMonitor: Any?
    /// 测试里换成内存里的剪贴板。
    var pasteboard: NSPasteboard = .general

    override init() {
        super.init()
        for name in [Notification.Name.timelineCommitEditing, NSApplication.willTerminateNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(commitEditing), name: name, object: nil)
        }
    }

    func isEditing(_ id: UUID) -> Bool { target?.logID == id }

    /// 开始编辑一条日志；`point` 是点在渲染好的正文上的位置（光标放到那里），nil 时放在末尾。
    func begin(_ log: DailyLogEntry, on date: Date, store: JournalStore, at point: CGPoint?, fontSize: CGFloat, dark: Bool) {
        guard !store.isReadOnly else { return }
        if target?.logID == log.id { return }
        finish()
        self.store = store
        target = Target(logID: log.id, date: date)
        height = nil
        original = log.text
        source = log.text
        caret = point
        configured = false
        let folds = HeadingFolds.folded(in: Self.foldID(log.id))
        settings = ["key": "log." + log.id.uuidString, "source": log.text, "inline": true, "readOnly": false, "sourceMode": false,
                    "fontSize": fontSize, "colors": BoardLiveEditorSession.colors(dark: dark), "labels": BoardLiveEditorSession.labels,
                    "folds": Dictionary(uniqueKeysWithValues: folds.map { ($0, true) })]
        _ = makeWebView()
        configure()
        watchClicks()
    }

    /// 保存并结束编辑（点了别处、换了窗口内容、应用退出）。
    func finish() {
        guard target != nil else { return }
        let webView = webView
        save()
        if ready, configured, let webView {
            // 停顿后才送过来的最后几个字：取一次快照补存。
            let target = target, store = store, original = original
            webView.evaluateJavaScript("window.boardEditor.blur(); window.boardEditor.snapshot()") { result, _ in
                guard let snapshot = result as? [String: Any], let text = snapshot["source"] as? String,
                      let target, let store, text != original else { return }
                if store.entry(for: target.date).logs.first(where: { $0.id == target.logID })?.text != text.trimmingCharacters(in: .whitespacesAndNewlines) {
                    store.updateLog(target.logID, text: text, on: target.date)
                }
            }
        }
        end()
    }

    private func save() {
        guard let target, let store, source != original else { return }
        original = source
        store.updateLog(target.logID, text: source, on: target.date)
    }

    private func end() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        if let webView, let window = webView.window, window.firstResponder === webView || (window.firstResponder as? NSView)?.isDescendant(of: webView) == true {
            window.makeFirstResponder(nil)
        }
        target = nil
        height = nil
        caret = nil
        configured = false
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
        let caret = self.caret
        webView.window?.makeFirstResponder(webView)
        let place = caret.map { "window.boardEditor.placeCaret(\($0.x), \($0.y))" }
            ?? "window.boardEditor.focus(); window.boardEditor.select(window.boardEditor.snapshot().source.length)"
        webView.evaluateJavaScript("window.boardEditor.configure(\(json)); \(place); window.boardEditor.height()") { [weak self] result, _ in
            guard let self, let value = result as? Double, value > 0, self.target != nil else { return }
            self.height = CGFloat(value)
        }
    }

    /// 编辑器挪进了这一条的位置（有窗口了）：拿键盘焦点，排好版。
    func attached() {
        guard let webView, webView.window != nil else { return }
        if configured { webView.window?.makeFirstResponder(webView) } else { configure() }
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
            composing = body["composing"] as? Bool ?? false
        case "height":
            guard target != nil, configured, let value = body["value"] as? Double, value > 0 else { return }
            height = CGFloat(value)
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
        } else { decisionHandler(navigationAction.request.url?.isFileURL == true ? .allow : .cancel) }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        save()
        ready = false
        configured = false
        webView.reload()
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
final class InlineEditorContainer: NSView {
    override var isFlipped: Bool { true }

    func attach(_ editor: NSView) {
        guard editor.superview !== self else { return }
        editor.removeFromSuperview()
        editor.frame = bounds
        addSubview(editor)
    }

    override func layout() {
        super.layout()
        for child in subviews where child.frame != bounds { child.frame = bounds }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { MainActor.assumeIsolated { InlineMarkdownEditor.shared.attached() } }
    }
}

struct InlineEditorHost: NSViewRepresentable {
    @ObservedObject var editor: InlineMarkdownEditor

    func makeNSView(context: Context) -> InlineEditorContainer {
        let container = InlineEditorContainer()
        container.attach(editor.makeWebView())
        return container
    }

    func updateNSView(_ container: InlineEditorContainer, context: Context) {
        if let webView = editor.webView, webView.superview !== container {
            container.attach(webView)
            editor.attached()
        }
    }
}

/// 日志 / 笔记的正文：平时是渲染好的 Markdown，点一下就地变成编辑器。
struct EditableLogText<Content: View>: View {
    @ObservedObject private var editor = InlineMarkdownEditor.shared
    let log: DailyLogEntry
    @ViewBuilder let content: (_ beginAt: ((CGPoint) -> Void)?) -> Content
    let begin: (CGPoint?) -> Void
    let editable: Bool

    init(log: DailyLogEntry, editable: Bool, begin: @escaping (CGPoint?) -> Void,
         @ViewBuilder content: @escaping (_ beginAt: ((CGPoint) -> Void)?) -> Content) {
        self.log = log
        self.editable = editable
        self.begin = begin
        self.content = content
    }

    var body: some View {
        let editing = editor.isEditing(log.id)
        if editing, let height = editor.height {
            InlineEditorHost(editor: editor)
                .frame(maxWidth: .infinity)
                .frame(height: height)
        } else {
            // 编辑器还没排好：先在正文下面悄悄排版，量出高度再换过来。
            content(editable ? { begin($0) } : nil)
                .overlay {
                    if editing { InlineEditorHost(editor: editor).opacity(0.01).allowsHitTesting(false) }
                }
        }
    }
}
