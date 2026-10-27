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
    /// 编辑器的内容已经画到屏幕上了：这之后才把渲染好的正文换成编辑器（之前的高度消息不算）。
    private var painted = false
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
    /// `fontSize`、`lineSpacing` 和渲染好的正文一样（已乘界面缩放），编辑器按它们排版，每一行落在原来的位置上。
    /// `muted`：正文是用淡色画的（日记里专注期间的笔记、反馈），编辑器也用淡色。
    func begin(_ log: DailyLogEntry, on date: Date, store: JournalStore, at point: CGPoint?, fontSize: CGFloat, lineSpacing: CGFloat,
               dark: Bool, muted: Bool = false) {
        guard !store.isReadOnly else { return }
        if target?.logID == log.id { return }
        finish()
        self.store = store
        target = Target(logID: log.id, date: date)
        height = nil
        original = log.text
        source = log.text
        configured = false
        painted = false
        let folds = HeadingFolds.folded(in: Self.foldID(log.id))
        let metrics = InlineEditorMetrics.css(fontSize: fontSize, lineSpacing: lineSpacing)
        // 点的位置相对正文的文字区；编辑器的文字区左边多 2px 内边距、整篇往上提了 shift。
        caret = point.map { CGPoint(x: $0.x + 2, y: $0.y + (metrics["shift"] ?? 0)) }
        var colors = BoardLiveEditorSession.colors(dark: dark)
        if muted { colors["ink"] = colors["muted"] }
        settings = ["key": "log." + log.id.uuidString, "source": log.text, "inline": true, "readOnly": false, "sourceMode": false,
                    "fontSize": fontSize, "colors": colors, "dark": dark,
                    "metrics": metrics.merging(["tail": InlineEditorMetrics.tail(log.text, fontSize: fontSize, lineSpacing: lineSpacing)]) { $1 },
                    "labels": BoardLiveEditorSession.labels.merging(["copyCode": AppLocalized("复制"), "code": AppLocalized("代码")]) { $1 },
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
        let target = self.target
        webView.evaluateJavaScript("window.boardEditor.configure(\(json)); \(place); 0", completionHandler: nil)
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
        height = value
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
            guard target != nil, configured, painted, let value = body["value"] as? Double, value > 0 else { return }
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
    /// 换成编辑器时下面的内容不往上跳。只和最后一段的样式有关（正文、代码、标题……），只排最后一段。
    @MainActor static func tail(_ source: String, fontSize: CGFloat, lineSpacing: CGFloat) -> Double {
        let rendered = MarkdownText.render(source, color: .labelColor, fontSize: fontSize, lineSpacing: lineSpacing, scale: 1)
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
        let shown = editing && editor.height != nil
        // 编辑器一直是同一个视图：先在正文上面悄悄排版（几乎透明），量出高度后正文隐去、编辑器显出来，同一帧换过去。
        // 不换视图层级（换了网页要重新挂到窗口上，会白一下；新旧两个容器同时在时还会把网页抢回旧的那个，整块不见）。
        content(editable && !shown ? { begin($0) } : nil)
            .opacity(shown ? 0 : 1)
            .allowsHitTesting(!shown)
            .frame(height: shown ? editor.height : nil, alignment: .top)
            .overlay(alignment: .top) {
                if editing {
                    InlineEditorHost(editor: editor)
                        .opacity(shown ? 1 : 0.01)
                        .allowsHitTesting(shown)
                }
            }
    }
}
