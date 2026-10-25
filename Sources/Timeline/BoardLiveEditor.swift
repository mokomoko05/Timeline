import AppKit
import SwiftUI
import WebKit
import TimelineCore

struct BoardLiveEditor: NSViewRepresentable {
    @ObservedObject var session: BoardLiveEditorSession
    var sourceMode = false
    @Environment(\.typography) private var typography
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> WKWebView { session.makeWebView() }
    func makeCoordinator() -> BoardLiveEditorSession { session }

    func updateNSView(_ view: WKWebView, context: Context) {
        session.configure(fontSize: typography.pt(13), dark: colorScheme == .dark,
                          sourceMode: sourceMode, previewOnly: !sourceMode)
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: BoardLiveEditorSession) { coordinator.flush() }
}

@MainActor
final class BoardLiveEditorSession: NSObject, ObservableObject, WKScriptMessageHandler, WKNavigationDelegate {
    static weak var active: BoardLiveEditorSession?
    @Published private(set) var ready = false
    @Published private(set) var error: String?
    private(set) var webView: WKWebView?
    private let store: JournalStore
    private let boardID: UUID
    private let pasteboard: NSPasteboard
    private var storedSource: String
    private(set) var source: String
    private var composing = false
    private var pending: Task<Void, Never>?
    private var settings: [String: Any] = [:]
    private var lastConfiguration: Data?
    private var sourceNeedsSynchronization = true

    var handlesTextCommands: Bool {
        webView?.window === NSApp.keyWindow && hasTextFocus
    }

    private var hasTextFocus: Bool {
        guard let webView, let responder = webView.window?.firstResponder as? NSView else { return false }
        return responder === webView || responder.isDescendant(of: webView)
    }

    func undo() { webView?.evaluateJavaScript("window.boardEditor.undo()") }
    func redo() { webView?.evaluateJavaScript("window.boardEditor.redo()") }

    init(store: JournalStore, board: Board, pasteboard: NSPasteboard = .general) {
        self.store = store
        self.pasteboard = pasteboard
        boardID = board.id
        storedSource = board.markdown
        source = board.markdown
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(commitEditing),
                                               name: .timelineCommitEditing, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// 所有编辑器共用一份不落盘的数据存储（编辑器不联网，也不需要互相隔离）。
    private static let dataStore = WKWebsiteDataStore.nonPersistent()

    func makeWebView() -> WKWebView {
        if let webView { Self.active = self; return webView }
        ready = false
        lastConfiguration = nil
        sourceNeedsSynchronization = true
        Self.active = self
        // 切到一个没有缓存编辑器的工作板时，接手预先加载好的空编辑器：省掉网页加载（约 100ms 的空白）。
        if let spare = Self.takeSpare() {
            spare.handler.session = self
            spare.view.navigationDelegate = self
            webView = spare.view
            if spare.handler.pendingReady { ready = true }
            return spare.view
        }
        let handler = WeakBoardScriptHandler()
        handler.session = self
        guard let view = Self.makeEditorView(handler: handler) else {
            error = AppLocalized("编辑器加载失败，请重新打开工作板。")
            let view = WKWebView(frame: .zero)
            webView = view
            return view
        }
        view.navigationDelegate = self
        webView = view
        return view
    }

    private static func makeEditorView(handler: WeakBoardScriptHandler) -> WKWebView? {
        let installed = Bundle.main.resourceURL?.appendingPathComponent("Timeline_Timeline.bundle")
        let resources = installed.flatMap(Bundle.init(url:)) ?? Bundle.module
        guard let directory = resources.url(forResource: "EditorAssets", withExtension: nil) else { return nil }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.userContentController.add(handler, name: "boardEditor")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.setValue(false, forKey: "drawsBackground")
        view.setAccessibilityLabel(AppLocalized("工作板 Markdown 内容"))
        view.loadFileURL(directory.appendingPathComponent("index.html"), allowingReadAccessTo: directory)
        return view
    }

    // MARK: 预加载

    private static var spare: (view: WKWebView, handler: WeakBoardScriptHandler)?
    private static let spareWatcher = SpareEditorWatcher()
    private static var spareTask: Task<Void, Never>?

    /// 空闲时预先加载一个编辑器，留给下一次切换到新工作板时用。已有一个就不再建。
    static func prepareSpare(after delay: Duration = .milliseconds(600)) {
        guard spare == nil, spareTask == nil else { return }
        spareTask = Task { @MainActor in
            try? await Task.sleep(for: delay)
            spareTask = nil
            let handler = WeakBoardScriptHandler()
            guard spare == nil, let view = makeEditorView(handler: handler) else { return }
            view.navigationDelegate = spareWatcher
            spare = (view, handler)
        }
    }

    private static func takeSpare() -> (view: WKWebView, handler: WeakBoardScriptHandler)? {
        guard let taken = spare else { return nil }
        spare = nil
        prepareSpare()
        return taken
    }

    fileprivate static func discardSpare(_ view: WKWebView) {
        if spare?.view === view { spare = nil }
    }

    func configure(fontSize: CGFloat, dark: Bool, sourceMode: Bool = false, previewOnly: Bool = false) {
        func css(_ color: Color) -> String {
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
            var result = ""
            appearance.performAsCurrentDrawingAppearance {
                let color = NSColor(color).usingColorSpace(.sRGB) ?? .labelColor
                result = String(format: "#%02x%02x%02x", Int(color.redComponent * 255),
                                Int(color.greenComponent * 255), Int(color.blueComponent * 255))
            }
            return result
        }
        var colors = ["background": css(Palette.background), "ink": css(Palette.ink),
                      "muted": css(Palette.muted), "accent": css(Palette.accent),
                      "soft": css(Palette.soft), "line": css(Palette.line), "success": css(Palette.success),
                      "selection": css(Color(nsColor: .selectedTextBackgroundColor)),
                      "selection-ink": css(Color(nsColor: .selectedTextColor))]
        for level in 1...6 { colors["heading-\(level)"] = css(Color(nsColor: MarkdownText.headingColor(level))) }
        settings = ["fontSize": fontSize, "readOnly": store.isReadOnly, "colors": colors,
                    "sourceMode": sourceMode, "previewOnly": previewOnly]
        settings["labels"] = ["openLink": AppLocalized("在 Safari 中打开"), "copyCode": AppLocalized("复制代码"),
                              "copied": AppLocalized("已复制"), "copyFailed": AppLocalized("复制失败，请重试")]
        let current = store.boards.first { $0.id == boardID }?.markdown ?? storedSource
        if current != storedSource {
            pending?.cancel()
            storedSource = current
            source = current
            sourceNeedsSynchronization = true
        }
        applyConfiguration()
    }

    func setSourceMode(_ enabled: Bool) {
        settings["sourceMode"] = enabled
        settings["previewOnly"] = !enabled
        applyConfiguration()
    }

    private func applyConfiguration() {
        guard ready, !settings.isEmpty else { return }
        var configuration = settings
        if sourceNeedsSynchronization {
            configuration["source"] = source
        }
        guard let data = try? JSONSerialization.data(withJSONObject: configuration, options: [.sortedKeys]),
              data != lastConfiguration else { return }
        lastConfiguration = data
        sourceNeedsSynchronization = false
        let json = String(decoding: data, as: UTF8.self)
        webView?.evaluateJavaScript("window.boardEditor.configure(\(json))") { [weak self] _, error in
            if error != nil { self?.error = AppLocalized("编辑器加载失败，请重新打开工作板。") }
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let kind = body["kind"] as? String else { return }
        if kind == "ready" {
            ready = true
            applyConfiguration()
        } else if kind == "change" || kind == "commit" {
            accept(body)
            if kind == "commit" { flush() }
            else {
                pending?.cancel()
                guard !composing else { return }
                pending = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
                    self?.flush()
                }
            }
        } else if kind == "open", let value = body["url"] as? String, let url = TaskText.linkURL(value) {
            SafariLinks.open(url)
        } else if kind == "copy", let value = body["text"] as? String, let request = body["request"] as? Int {
            pasteboard.clearContents()
            let success = pasteboard.setString(value, forType: .string)
            webView?.evaluateJavaScript("window.boardEditor.copyResult(\(request), \(success))")
        }
    }

    private func accept(_ snapshot: [String: Any]) {
        guard let source = snapshot["source"] as? String else { return }
        self.source = source
        composing = snapshot["composing"] as? Bool ?? false
    }

    func flush() {
        pending?.cancel()
        pending = nil
        guard !composing, source != storedSource else { return }
        storedSource = source
        store.setBoardMarkdown(source, for: boardID)
    }

    func commit(completion: @escaping () -> Void) {
        guard ready, let webView else { flush(); completion(); return }
        webView.evaluateJavaScript("document.activeElement?.blur(); window.boardEditor.snapshot()") { [weak self] result, _ in
            if let snapshot = result as? [String: Any] { self?.accept(snapshot) }
            self?.composing = false
            self?.flush()
            completion()
        }
    }

    func insertTemplate(_ template: BoardMarkdownTemplate) {
        let kind: String
        switch template {
        case .disclosure: kind = "disclosure"
        case .paper: kind = "paper"
        case .meeting: kind = "meeting"
        }
        let labels = ["title": AppLocalized("折叠标题"), "body": AppLocalized("在这里填写内容，支持 Markdown、链接和待办。"),
                      "paper": AppLocalized("论文阅读"), "notes": AppLocalized("阅读笔记"), "meeting": AppLocalized("会议议程"),
                      "progress": AppLocalized("进展同步"), "discussion": AppLocalized("讨论事项"), "actions": AppLocalized("结论与后续行动")]
        guard ready, let data = try? JSONSerialization.data(withJSONObject: labels) else { return }
        webView?.evaluateJavaScript("window.boardEditor.insertTemplate('\(kind)', \(String(decoding: data, as: UTF8.self)))")
    }

    @objc private func commitEditing() { flush() }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .linkActivated {
            if let url = navigationAction.request.url.flatMap({ TaskText.linkURL($0.absoluteString) }) { SafariLinks.open(url) }
            decisionHandler(.cancel)
        } else { decisionHandler(navigationAction.request.url?.isFileURL == true ? .allow : .cancel) }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        flush()
        ready = false
        lastConfiguration = nil
        sourceNeedsSynchronization = true
        webView.reload()
    }
}

/// 脚本消息转给编辑器会话；预加载的编辑器还没有主人时，只记下它已经就绪。
final class WeakBoardScriptHandler: NSObject, WKScriptMessageHandler {
    weak var session: BoardLiveEditorSession?
    private(set) var pendingReady = false
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if let session {
            session.userContentController(userContentController, didReceive: message)
        } else if (message.body as? [String: Any])?["kind"] as? String == "ready" {
            pendingReady = true
        }
    }
}

/// 预加载编辑器的网页进程退出了，就丢掉它，下次重新建。
private final class SpareEditorWatcher: NSObject, WKNavigationDelegate {
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        MainActor.assumeIsolated { BoardLiveEditorSession.discardSpare(webView) }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.request.url?.isFileURL == true ? .allow : .cancel)
    }
}
