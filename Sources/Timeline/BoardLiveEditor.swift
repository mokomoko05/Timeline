import AppKit
import SwiftUI
import WebKit
import TimelineCore

/// 放共用编辑器的容器：每次显示一块工作板都是新的容器，编辑器视图从上一个容器里挪过来，
/// 两块工作板的界面交替时不会争同一个视图的父视图。
final class BoardEditorContainer: NSView {
    func attach(_ editor: NSView) {
        guard editor.superview !== self else { return }
        editor.removeFromSuperview()
        editor.frame = bounds
        editor.autoresizingMask = [.width, .height]
        addSubview(editor)
    }
}

struct BoardLiveEditor: NSViewRepresentable {
    @ObservedObject var session: BoardLiveEditorSession
    /// 正在编辑（否则是只读浏览）。
    var editing = false
    /// 编辑时显示完整源码；否则所见即所得，只有光标所在的那一行露出 Markdown 标记。
    var raw = false
    @Environment(\.typography) private var typography
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> BoardEditorContainer {
        let container = BoardEditorContainer()
        container.attach(session.makeWebView())
        return container
    }
    func makeCoordinator() -> BoardLiveEditorSession { session }

    func updateNSView(_ container: BoardEditorContainer, context: Context) {
        // 只有这块工作板还拥有编辑器时才放回来（编辑器被重建过）；不从别的工作板手里抢。
        if let webView = session.webView, webView.superview !== container { container.attach(webView) }
        session.configure(fontSize: typography.pt(13), dark: colorScheme == .dark,
                          sourceMode: editing && raw, previewOnly: !editing)
    }

    static func dismantleNSView(_ view: BoardEditorContainer, coordinator: BoardLiveEditorSession) { coordinator.flush() }
}

@MainActor
final class BoardLiveEditorSession: NSObject, ObservableObject, WKScriptMessageHandler, WKNavigationDelegate {
    static weak var active: BoardLiveEditorSession?
    @Published private(set) var ready = false
    @Published private(set) var error: String?
    /// 编辑器里按了 ⌘Enter：内容已经提交，回到只读浏览。
    var onPreview: (() -> Void)?
    private(set) var webView: WKWebView?
    private let store: JournalStore
    private let boardID: UUID
    private let pasteboard: NSPasteboard
    private let defaults: UserDefaults
    /// 搜索结果要跳到的行（编辑器还没加载好时先记下）。
    private var pendingReveal: (line: Int, query: String)?
    private var storedSource: String
    private(set) var source: String
    private var composing = false
    private var pending: Task<Void, Never>?
    private var settings: [String: Any] = [:]
    private var lastConfiguration: Data?
    private var sourceNeedsSynchronization = true
    private var loadWatch: Task<Void, Never>?
    /// 编辑器网页多久还没就绪就重建（测试里改短）。
    static var loadTimeout: Duration = .seconds(6)
    /// 网页多久还没走到导航决策就算卡住。本地文件正常几十毫秒就到；卡住时 WebKit 收到了加载请求，
    /// 却一直不来问导航策略（多见于刚编译 / 刚拷贝的程序第一次启动），重建后就好。
    static var navigationTimeout: Duration = .milliseconds(1500)
    /// 连续因为导航卡住重建了几次：WebKit 一直起不来时退回 `loadTimeout`，不反复重建。
    private static var quickRebuilds = 0

    var handlesTextCommands: Bool {
        webView?.window === NSApp.keyWindow && hasTextFocus
    }

    /// 编辑器自己的撤销历史（打字、勾待办、插入模板）还有几步。浏览时也算：工作板在前面时 ⌘Z 先撤销它。
    private(set) var undoDepth = 0
    private(set) var redoDepth = 0

    /// 工作板是当前窗口，且光标在编辑器里或编辑器有可撤销 / 重做的修改。
    var handlesUndo: Bool { webView?.window === NSApp.keyWindow && (hasTextFocus || undoDepth > 0) }
    var handlesRedo: Bool { webView?.window === NSApp.keyWindow && (hasTextFocus || redoDepth > 0) }

    private var hasTextFocus: Bool {
        guard let webView, let responder = webView.window?.firstResponder as? NSView else { return false }
        return responder === webView || responder.isDescendant(of: webView)
    }

    func undo() { webView?.evaluateJavaScript("window.boardEditor.undo()") }
    func redo() { webView?.evaluateJavaScript("window.boardEditor.redo()") }

    init(store: JournalStore, board: Board, pasteboard: NSPasteboard = .general, defaults: UserDefaults = .standard) {
        self.store = store
        self.pasteboard = pasteboard
        self.defaults = defaults
        boardID = board.id
        storedSource = board.markdown
        source = board.markdown
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(commitEditing),
                                               name: .timelineCommitEditing, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(foldsChanged(_:)),
                                               name: .boardFoldsChanged, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    static func foldsKey(_ id: UUID) -> String { BoardFolds.key(id) }
    private var recordingOwnFold = false

    /// 折叠记忆（哪些标题收起了、哪些折叠块展开了）在别处改了（比如笔记里的看板内容）：编辑器跟着变。
    @objc private func foldsChanged(_ notification: Notification) {
        guard notification.userInfo?["board"] as? UUID == boardID, !settings.isEmpty else { return }
        let folds = BoardFolds.load(boardID, defaults: defaults)
        guard settings["folds"] as? [String: Bool] != folds else { return }
        settings["folds"] = folds
        // 编辑器自己刚折叠的：它已经是这个状态。回传反而会在连续快点时把更新的一次点击盖回旧状态。
        guard !recordingOwnFold else { return }
        applyConfiguration()
    }

    /// 跳到第 `line` 行（从 1 开始）：展开包住它的标题和折叠块，滚到中间并高亮命中的文字。
    func reveal(line: Int, query: String) {
        pendingReveal = (line, query)
        performPendingReveal()
    }

    private func performPendingReveal() {
        guard ready, lastConfiguration != nil, let target = pendingReveal, let webView,
              let data = try? JSONSerialization.data(withJSONObject: [target.query]) else { return }
        pendingReveal = nil
        let query = String(decoding: data, as: UTF8.self).dropFirst().dropLast()
        webView.evaluateJavaScript("window.boardEditor.reveal(\(target.line), \(query))")
    }

    /// 所有编辑器共用一份不落盘的数据存储（编辑器不联网，也不需要互相隔离）。
    private static let dataStore = WKWebsiteDataStore.nonPersistent()

    /// 拿到共用的编辑器：所有工作板只有一个编辑器（一份 WebKit 网页进程）。上一个使用它的工作板先保存内容、交出来；
    /// 网页里按工作板分别存着正文、光标、撤销历史和滚动位置，换回来时原样恢复。
    func makeWebView() -> WKWebView {
        Self.active = self
        if let webView, Self.owner === self { return webView }
        if let previous = Self.owner, previous !== self { previous.detach() }
        guard let host = Self.sharedHost() else {
            error = AppLocalized("编辑器加载失败，请重新打开工作板。")
            let view = WKWebView(frame: .zero)
            webView = view
            return view
        }
        host.handler.session = self
        host.view.navigationDelegate = self
        Self.owner = self
        webView = host.view
        ready = host.handler.pageReady
        lastConfiguration = nil
        sourceNeedsSynchronization = true
        applyConfiguration()
        if !ready { watchLoading() }
        return host.view
    }

    /// 编辑器网页迟迟没有就绪（网页进程没起来或卡住了，这时收不到进程退出的通知）：丢掉重建一个，
    /// 不然这块和之后打开的工作板都是空白。界面跟着 `objectWillChange` 把新的编辑器放进来。
    private func watchLoading() {
        loadWatch?.cancel()
        let timeout = Self.loadTimeout, quick = min(Self.navigationTimeout, timeout)
        loadWatch = Task { @MainActor [weak self] in
            try? await Task.sleep(for: quick)
            guard !Task.isCancelled, let self, Self.owner === self, !self.ready else { return }
            if Self.quickRebuilds < 3, Self.shared?.handler.navigationStarted == false {
                Self.quickRebuilds += 1
            } else {
                try? await Task.sleep(for: timeout - quick)
                guard !Task.isCancelled, Self.owner === self, !self.ready else { return }
            }
            Self.shared?.handler.session = nil
            Self.shared?.view.removeFromSuperview()
            Self.shared = nil
            Self.owner = nil
            self.webView = nil
            self.objectWillChange.send()
            _ = self.makeWebView()
        }
    }

    /// 交出编辑器：内容先保存，之后这块工作板不再向网页发任何指令，直到再次拿到编辑器。
    private func detach() {
        loadWatch?.cancel()
        flush()
        webView = nil
        ready = false
        lastConfiguration = nil
        if Self.owner === self { Self.owner = nil }
    }

    /// 这块工作板不再保留（换出最近使用的范围）：网页里存着的状态也丢掉。
    func forget() {
        if Self.owner === self { detach() } else { flush() }
        Self.shared?.view.evaluateJavaScript("window.boardEditor.forget('\(boardID.uuidString)')")
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

    // MARK: 共用编辑器

    private static var shared: (view: WKWebView, handler: WeakBoardScriptHandler)?
    private static weak var owner: BoardLiveEditorSession?
    private static let idleWatcher = SharedEditorWatcher()
    private static var preloadTask: Task<Void, Never>?

    private static func sharedHost() -> (view: WKWebView, handler: WeakBoardScriptHandler)? {
        if let shared { return shared }
        preloadTask?.cancel()
        preloadTask = nil
        let handler = WeakBoardScriptHandler()
        guard let view = makeEditorView(handler: handler) else { return nil }
        shared = (view, handler)
        return shared
    }

    /// 工作板窗口刚出现、还没用到编辑器时，空闲时先把编辑器网页加载好（约 100ms），第一次打开工作板不用等。
    static func preloadEditor(after delay: Duration = .milliseconds(600)) {
        guard shared == nil, preloadTask == nil else { return }
        preloadTask = Task { @MainActor in
            try? await Task.sleep(for: delay)
            preloadTask = nil
            guard shared == nil, let host = sharedHost() else { return }
            host.view.navigationDelegate = idleWatcher
        }
    }

    /// 释放共用编辑器（网页进程随之退出）：工作板窗口长时间隐藏或系统内存紧张时调用。内容先保存；
    /// 下次打开工作板时重新加载，光标和撤销历史不再保留。
    static func releaseSharedEditor() {
        preloadTask?.cancel()
        preloadTask = nil
        owner?.detach()
        shared?.view.removeFromSuperview()
        shared = nil
    }

    static var hasSharedEditor: Bool { shared != nil }

    fileprivate static func editorBecameReady() { quickRebuilds = 0 }

    fileprivate static func navigationStarted(in view: WKWebView) {
        if shared?.view === view { shared?.handler.navigationStarted = true }
    }

    fileprivate static func discardShared(_ view: WKWebView) {
        if shared?.view === view, owner == nil { shared = nil }
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
                    "sourceMode": sourceMode, "previewOnly": previewOnly, "folds": BoardFolds.load(boardID, defaults: defaults), "key": boardID.uuidString]
        settings["labels"] = ["openLink": AppLocalized("在 Safari 中打开"), "copyCode": AppLocalized("复制代码"),
                              "copied": AppLocalized("已复制"), "copyFailed": AppLocalized("复制失败，请重试"),
                              "expand": AppLocalized("展开标题下的内容"), "collapse": AppLocalized("收起标题下的内容")]
        let current = store.boards.first { $0.id == boardID }?.markdown ?? storedSource
        if current != storedSource {
            pending?.cancel()
            storedSource = current
            source = current
            sourceNeedsSynchronization = true
        }
        applyConfiguration()
    }

    /// 浏览 / 编辑切换。进入编辑时键盘焦点交给编辑器，光标落在浏览时点下的位置。
    func setMode(editing: Bool, raw: Bool) {
        settings["sourceMode"] = editing && raw
        settings["previewOnly"] = !editing
        applyConfiguration()
        if editing, let webView, webView.window?.firstResponder !== webView { webView.window?.makeFirstResponder(webView) }
    }

    /// 编辑完整源码（true）或回到浏览（false）。
    func setSourceMode(_ enabled: Bool) { setMode(editing: enabled, raw: true) }

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
            self?.performPendingReveal()
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let kind = body["kind"] as? String,
              message.webView == nil || message.webView === webView else { return }
        if kind == "ready" {
            loadWatch?.cancel()
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
        } else if kind == "fold", let key = body["key"] as? String, let value = body["value"] as? Bool {
            // 存进共用的折叠记忆；通知回到 foldsChanged 更新配置（编辑器里已经是这个状态，不会重画）。
            recordingOwnFold = true
            BoardFolds.set(key, value, board: boardID, defaults: defaults)
            recordingOwnFold = false
        } else if kind == "history" {
            undoDepth = body["undo"] as? Int ?? 0
            redoDepth = body["redo"] as? Int ?? 0
        } else if kind == "preview" {
            flush()
            onPreview?()
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
        Self.navigationStarted(in: webView)
        if navigationAction.navigationType == .linkActivated {
            if let url = navigationAction.request.url.flatMap({ TaskText.linkURL($0.absoluteString) }) { SafariLinks.open(url) }
            decisionHandler(.cancel)
        } else { decisionHandler(navigationAction.request.url?.isFileURL == true ? .allow : .cancel) }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        flush()
        Self.shared.map { $0.handler.pageReady = false; $0.handler.navigationStarted = false }
        ready = false
        lastConfiguration = nil
        sourceNeedsSynchronization = true
        webView.reload()
        watchLoading()
    }
}

/// 脚本消息转给编辑器会话；预加载的编辑器还没有主人时，只记下它已经就绪。
final class WeakBoardScriptHandler: NSObject, WKScriptMessageHandler {
    weak var session: BoardLiveEditorSession?
    /// 网页已经加载好（之后换工作板不用再等）。网页进程重启后重新加载，再次就绪前为 false。
    var pageReady = false
    /// WebKit 已经来问过导航策略（加载真的开始了）。
    var navigationStarted = false
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if (message.body as? [String: Any])?["kind"] as? String == "ready" {
            pageReady = true
            BoardLiveEditorSession.editorBecameReady()
        }
        session?.userContentController(userContentController, didReceive: message)
    }
}

/// 预加载、还没有工作板使用的编辑器，网页进程退出了就丢掉，下次重新建。
private final class SharedEditorWatcher: NSObject, WKNavigationDelegate {
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        MainActor.assumeIsolated { BoardLiveEditorSession.discardShared(webView) }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        MainActor.assumeIsolated { BoardLiveEditorSession.navigationStarted(in: webView) }
        decisionHandler(navigationAction.request.url?.isFileURL == true ? .allow : .cancel)
    }
}
