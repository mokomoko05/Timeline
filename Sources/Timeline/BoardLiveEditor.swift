import AppKit
import SwiftUI
import WebKit
import TimelineCore

struct BoardLiveEditor: NSViewRepresentable {
    @ObservedObject var session: BoardLiveEditorSession
    var vim: Bool
    var sourceMode = false
    @Environment(\.typography) private var typography
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> WKWebView { session.makeWebView() }
    func makeCoordinator() -> BoardLiveEditorSession { session }

    func updateNSView(_ view: WKWebView, context: Context) {
        session.configure(vim: vim, fontSize: typography.pt(13), dark: colorScheme == .dark, sourceMode: sourceMode)
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: BoardLiveEditorSession) { coordinator.flush() }
}

@MainActor
final class BoardLiveEditorSession: NSObject, ObservableObject, WKScriptMessageHandler, WKNavigationDelegate {
    static weak var active: BoardLiveEditorSession?
    @Published private(set) var ready = false
    @Published private(set) var error: String?
    @Published private(set) var browsing = false
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
    func beginEditing() { webView?.evaluateJavaScript("window.boardEditor.edit()") }
    func saveAndBrowse() { webView?.evaluateJavaScript("window.boardEditor.escape(); window.boardEditor.browse()") }

    func handleModeKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, ready, settings["vim"] as? Bool == true,
              event.window === webView?.window, hasTextFocus, !composing else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let escape = event.keyCode == 53 && modifiers.isEmpty
        let controlBracket = modifiers == .control && (event.charactersIgnoringModifiers == "["
            || event.characters == "\u{1b}" || event.keyCode == 33)
        guard escape || controlBracket else { return false }
        webView?.evaluateJavaScript("window.boardEditor.escape()")
        return true
    }

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

    func makeWebView() -> WKWebView {
        if let webView { Self.active = self; return webView }
        ready = false
        lastConfiguration = nil
        sourceNeedsSynchronization = true
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(WeakBoardScriptHandler(self), name: "boardEditor")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.setValue(false, forKey: "drawsBackground")
        view.setAccessibilityLabel(AppLocalized("工作板 Markdown 内容"))
        webView = view
        Self.active = self
        let installed = Bundle.main.resourceURL?.appendingPathComponent("Timeline_Timeline.bundle")
        let resources = installed.flatMap(Bundle.init(url:)) ?? Bundle.module
        if let directory = resources.url(forResource: "EditorAssets", withExtension: nil) {
            view.loadFileURL(directory.appendingPathComponent("index.html"), allowingReadAccessTo: directory)
        } else {
            error = AppLocalized("编辑器加载失败，请重新打开工作板。")
        }
        return view
    }

    func configure(vim: Bool, fontSize: CGFloat, dark: Bool, sourceMode: Bool = false) {
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
                      "soft": css(Palette.soft), "line": css(Palette.line), "success": css(Palette.success)]
        for level in 1...6 { colors["heading-\(level)"] = css(Color(nsColor: MarkdownText.headingColor(level))) }
        settings = ["vim": vim, "fontSize": fontSize, "readOnly": store.isReadOnly, "colors": colors, "sourceMode": sourceMode]
        settings["labels"] = ["openLink": AppLocalized("在 Safari 中打开"), "copyCode": AppLocalized("复制代码"),
                              "copied": AppLocalized("已复制"), "copyFailed": AppLocalized("复制失败，请重试"),
                              "browse": AppLocalized("浏览 · 按 i 编辑")]
        let current = store.boards.first { $0.id == boardID }?.markdown ?? storedSource
        if current != storedSource {
            pending?.cancel()
            storedSource = current
            source = current
            sourceNeedsSynchronization = true
        }
        applyConfiguration()
    }

    private func applyConfiguration() {
        guard ready, !settings.isEmpty else { return }
        var configuration = settings
        if sourceNeedsSynchronization {
            configuration["source"] = source
            configuration["browsing"] = browsing
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
        } else if kind == "mode", let value = body["browsing"] as? Bool {
            if browsing != value { browsing = value }
        } else if kind == "write" {
            accept(body)
            flush()
            store.save()
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

private final class WeakBoardScriptHandler: NSObject, WKScriptMessageHandler {
    private weak var session: BoardLiveEditorSession?
    init(_ session: BoardLiveEditorSession) { self.session = session }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        session?.userContentController(userContentController, didReceive: message)
    }
}
