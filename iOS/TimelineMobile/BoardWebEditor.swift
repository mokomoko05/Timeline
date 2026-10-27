import ObjectiveC
import SwiftUI
import TimelineCore
import UIKit
import WebKit

/// 工作板编辑器（和 Mac 同一个 CodeMirror 编辑器）：平时是渲染好的 Markdown，光标移到哪个元素上才露出它的标记。
///
/// 所有工作板共用一个网页编辑器（一份 WebKit 进程），打开工作板列表时先在后台加载好，进到工作板不用等。
/// 打字只在网页里：停顿一下才把全文交给原生层，再停一会儿才写进数据（写数据会让好几个页面重算）；
/// 收起键盘、离开这一页、应用退到后台时立即写回。
struct BoardWebEditor: UIViewRepresentable {
    @ObservedObject var session: BoardWebSession
    var sourceMode = false
    @Environment(\.colorScheme) private var colorScheme

    func makeUIView(context: Context) -> BoardEditorContainer {
        let container = BoardEditorContainer()
        container.attach(session.attach())
        return container
    }

    func updateUIView(_ container: BoardEditorContainer, context: Context) {
        if let view = session.webView, view.superview !== container { container.attach(view) }
        session.configure(dark: colorScheme == .dark, sourceMode: sourceMode)
    }

    static func dismantleUIView(_ container: BoardEditorContainer, coordinator: ()) {}
}

/// 放共用编辑器的容器：每次显示一块工作板都是新的容器，编辑器从上一个容器里挪过来。
final class BoardEditorContainer: UIView {
    func attach(_ editor: UIView) {
        guard editor.superview !== self else { return }
        editor.removeFromSuperview()
        editor.frame = bounds
        editor.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(editor)
    }
}

/// 共用的网页编辑器。键盘上方是格式按钮条（替换掉网页默认的上一项 / 下一项 / 完成）。
final class BoardWebView: WKWebView {
    var accessory: UIView? {
        didSet { installAccessory() }
    }

    /// 网页里真正接收输入的是 WKContentView：给它换一个只多了 `inputAccessoryView` 的子类。
    private func installAccessory() {
        guard let content = scrollView.subviews.first(where: { NSStringFromClass(type(of: $0)).hasPrefix("WKContent") }) else { return }
        let base: AnyClass = type(of: content)
        let name = NSStringFromClass(base) + "_TimelineBoard"
        if NSStringFromClass(base) == name { return }
        var subclass: AnyClass? = NSClassFromString(name)
        if subclass == nil, let created = objc_allocateClassPair(base, name, 0) {
            let accessory: @convention(block) (AnyObject) -> UIView? = { object in
                var view = (object as? UIView)?.superview
                while let current = view, !(current is BoardWebView) { view = current.superview }
                return (view as? BoardWebView)?.accessory
            }
            class_addMethod(created, #selector(getter: UIResponder.inputAccessoryView), imp_implementationWithBlock(accessory), "@@:")
            objc_registerClassPair(created)
            subclass = created
        }
        if let subclass { object_setClass(content, subclass) }
    }
}

@MainActor
final class BoardWebSession: NSObject, ObservableObject {
    /// 编辑的是什么：一块工作板，或者一条日志 / 笔记（点正文就地编辑，和工作板一样所见即所得）。
    enum Document {
        case board(UUID)
        case log(id: UUID, date: Date)
    }

    /// 工作板和日志各用一个网页编辑器：编辑日志时不用把工作板那一页的编辑器抢走。
    enum Pool { case board, log }

    /// 光标在不在编辑器里（键盘出没出来）。
    @Published private(set) var editing = false
    @Published private(set) var ready = false
    /// 日志编辑器量出来的内容高度：输入卡按它长高（太长就在里面滚动）。
    @Published private(set) var contentHeight: CGFloat?
    private(set) var canUndo = false
    private(set) var canRedo = false
    private(set) var webView: BoardWebView?
    let store: JournalStore
    let document: Document
    private var pool: Pool { if case .board = document { return .board } else { return .log } }
    /// 网页里按这个分别存光标、撤销历史；消息也按它转回来。
    var key: String {
        switch document {
        case .board(let id): return id.uuidString
        case .log(let id, _): return "log." + id.uuidString
        }
    }
    /// 「取消」：这次的修改不写回。
    private var discarded = false
    private var storedSource: String
    private var source: String
    private var composing = false
    private var settings: [String: Any] = [:]
    private var lastConfiguration: Data?
    private var sourceNeedsSynchronization = true
    private var pendingWrite: DispatchWorkItem?
    private var focusWhenReady = false
    /// 搜索结果打开时要跳到的行（从 1 开始）和要高亮的词：编辑器配置好以后再跳。
    private var pendingReveal: (line: Int, query: String)?
    /// 停顿多久才把文字写进数据。
    private static let writeDelay: TimeInterval = 0.8

    convenience init(store: JournalStore, boardID: UUID) {
        self.init(store: store, document: .board(boardID))
    }

    init(store: JournalStore, document: Document) {
        self.store = store
        self.document = document
        storedSource = ""
        source = ""
        super.init()
        let markdown = currentSource() ?? ""
        storedSource = markdown
        source = markdown
        Self.sessions.setObject(self, forKey: key as NSString)
    }

    /// 数据里现在的正文。
    private func currentSource() -> String? {
        switch document {
        case .board(let id): return store.boards.first { $0.id == id }?.markdown
        case .log(let id, let date): return store.entry(for: date).logs.first { $0.id == id }?.text
        }
    }

    // MARK: 共用编辑器

    private static let sessions = NSMapTable<NSString, BoardWebSession>.strongToWeakObjects()
    private static var hosts: [Pool: BoardWebHost] = [:]
    private static var owners: [Pool: Weak] = [:]
    private struct Weak { weak var session: BoardWebSession? }
    private static func owner(_ pool: Pool) -> BoardWebSession? { owners[pool]?.session }

    /// 进到工作板列表时先把编辑器网页加载好（约一两百毫秒），第一次打开工作板不用等。
    static func preload(_ pool: Pool = .board) {
        guard hosts[pool] == nil else { return }
        hosts[pool] = BoardWebHost(pool: pool)
    }

    fileprivate static func route(_ body: [String: Any], pool: Pool) {
        if let key = body["key"] as? String, let session = sessions.object(forKey: key as NSString) {
            session.receive(body)
        } else {
            owner(pool)?.receive(body)
        }
    }

    fileprivate static func pageReady(_ pool: Pool) {
        owner(pool)?.becameReady()
    }

    /// 拿到共用编辑器：上一块工作板先把内容写回、交出来。网页里按工作板存着光标、撤销历史和滚动位置。
    func attach() -> BoardWebView {
        Self.preload(pool)
        let host = Self.hosts[pool]!
        if let previous = Self.owner(pool), previous !== self { previous.detach() }
        Self.owners[pool] = Weak(session: self)
        webView = host.view
        host.view.accessory = toolbar
        ready = host.ready
        lastConfiguration = nil
        sourceNeedsSynchronization = true
        applyConfiguration()
        return host.view
    }

    private func detach() {
        flush()
        webView = nil
        ready = false
        lastConfiguration = nil
        if Self.owner(pool) === self { Self.owners[pool] = nil }
    }

    private func becameReady() {
        ready = true
        applyConfiguration()
    }

    private lazy var toolbar = MarkdownToolbar(target: self)

    // MARK: 配置

    func configure(dark: Bool, sourceMode: Bool) {
        let traits = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
        func css(_ color: Color) -> String {
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            UIColor(color).resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            return String(format: "#%02x%02x%02x", Int(red * 255), Int(green * 255), Int(blue * 255))
        }
        var colors = ["background": css(Palette.background), "ink": css(Palette.ink), "muted": css(Palette.muted),
                      "accent": css(Palette.accent), "soft": css(Palette.soft), "line": css(Palette.line),
                      "success": css(Palette.success), "selection": css(Palette.accent.opacity(dark ? 0.45 : 0.25)),
                      "selection-ink": css(Palette.ink)]
        for level in 1...6 { colors["heading-\(level)"] = css(Palette.heading(level)) }
        settings = ["fontSize": UIFontMetrics(forTextStyle: .body).scaledValue(for: 16), "readOnly": store.isReadOnly, "colors": colors,
                    "sourceMode": sourceMode, "folds": folds, "key": key, "measure": pool == .log,
                    "labels": ["openLink": L("在 Safari 中打开"), "copyCode": L("复制代码"), "copied": L("已复制"),
                               "copyFailed": L("复制失败，请重试"), "expand": L("展开标题下的内容"), "collapse": L("收起标题下的内容")]]
        // 别处（另一台设备同步过来）改了正文，而这边没有没写回的修改：换成新的。
        let current = currentSource() ?? storedSource
        if current != storedSource, pendingWrite == nil, source == storedSource {
            storedSource = current
            source = current
            sourceNeedsSynchronization = true
        }
        applyConfiguration()
    }

    private func applyConfiguration() {
        guard ready, Self.owner(pool) === self, !settings.isEmpty, let webView else { return }
        var configuration = settings
        if sourceNeedsSynchronization { configuration["source"] = source }
        guard let data = try? JSONSerialization.data(withJSONObject: configuration, options: [.sortedKeys]),
              data != lastConfiguration else { return }
        lastConfiguration = data
        sourceNeedsSynchronization = false
        webView.evaluateJavaScript("window.boardEditor.configure(\(String(decoding: data, as: UTF8.self))); 0") { [weak self] _, _ in
            guard let self else { return }
            self.performPendingReveal()
            guard self.focusWhenReady else { return }
            self.focusWhenReady = false
            self.beginEditing()
        }
    }

    /// 跳到第 `line` 行：展开包住它的标题和折叠块，滚到中间并高亮命中的文字（和 Mac 的搜索结果一样）。
    func reveal(line: Int, query: String) {
        pendingReveal = (line, query)
        performPendingReveal()
    }

    private func performPendingReveal() {
        guard ready, Self.owner(pool) === self, lastConfiguration != nil, let target = pendingReveal, let webView,
              let data = try? JSONSerialization.data(withJSONObject: [target.query]) else { return }
        pendingReveal = nil
        let query = String(decoding: data, as: UTF8.self).dropFirst().dropLast()
        // 等这一轮排版完、网页知道自己多高再滚。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            webView.evaluateJavaScript("window.boardEditor.reveal(\(target.line), \(query)); 0")
        }
    }

    private var foldsKey: String {
        switch document {
        case .board(let id): return "board.folds.\(id.uuidString)"
        // 和渲染好的正文（`MarkdownView`）共用折叠记忆：存的是收起的标题。
        case .log(let id, _): return "markdownFolds.log.\(id.uuidString)"
        }
    }
    private var folds: [String: Bool] {
        if case .log = document {
            return Dictionary(uniqueKeysWithValues: (UserDefaults.standard.stringArray(forKey: foldsKey) ?? []).map { ($0, true) })
        }
        return UserDefaults.standard.dictionary(forKey: foldsKey) as? [String: Bool] ?? [:]
    }

    // MARK: 网页发来的消息

    fileprivate func receive(_ body: [String: Any]) {
        guard let kind = body["kind"] as? String else { return }
        switch kind {
        case "change":
            accept(body)
            // 日志在收起输入卡时才写回：每停顿一下就写会给撤销记一大串，正文临时删空还会把日志删掉。
            if pool == .board { scheduleWrite() }
        case "commit":
            accept(body)
            flush()
        case "focus":
            editing = body["value"] as? Bool ?? false
            if !editing { flush() }
        case "history":
            canUndo = (body["undo"] as? Int ?? 0) > 0
            canRedo = (body["redo"] as? Int ?? 0) > 0
            toolbar.refreshUndo()
        case "fold":
            guard let key = body["key"] as? String, let value = body["value"] as? Bool else { return }
            var folds = folds
            folds[key] = value
            if key.hasPrefix("h"), !value { folds.removeValue(forKey: key) }
            if case .log = document {
                UserDefaults.standard.set(folds.filter(\.value).map(\.key).sorted(), forKey: foldsKey)
            } else {
                UserDefaults.standard.set(folds, forKey: foldsKey)
            }
            settings["folds"] = folds
        case "height":
            if let value = body["value"] as? Double, value > 0 { contentHeight = CGFloat(value) }
        case "open":
            if let value = body["url"] as? String, let url = TaskText.linkURL(value) { UIApplication.shared.open(url) }
        case "copy":
            guard let text = body["text"] as? String, let request = body["request"] as? Int else { return }
            UIPasteboard.general.string = text
            webView?.evaluateJavaScript("window.boardEditor.copyResult(\(request), true); 0")
        default:
            break
        }
    }

    private func accept(_ snapshot: [String: Any]) {
        guard let source = snapshot["source"] as? String else { return }
        self.source = source
        composing = snapshot["composing"] as? Bool ?? false
    }

    private func scheduleWrite() {
        pendingWrite?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flush() }
        pendingWrite = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.writeDelay, execute: work)
    }

    /// 离开这一页、退到后台：编辑器停顿一下才送改动，先直接从编辑器取一次最新的全文，再写回。
    func commit() {
        guard ready, Self.owner(pool) === self, let webView else { flush(); return }
        let key = self.key
        webView.evaluateJavaScript("window.boardEditor.snapshot()") { [weak self] result, _ in
            guard let self else { return }
            if let snapshot = result as? [String: Any], snapshot["key"] as? String == key { self.accept(snapshot) }
            self.flush()
        }
    }

    /// 把编辑器里的文字写进数据并存盘（没变就什么也不做）。
    func flush() {
        pendingWrite?.cancel()
        pendingWrite = nil
        guard !discarded, !composing, source != storedSource else { return }
        switch document {
        case .board(let id):
            storedSource = source
            store.setBoardMarkdown(source, for: id)
        case .log(let id, let date):
            // 正文删空、又没有图片：不写（不能因为编辑到一半把日志删了）。
            let images = store.entry(for: date).logs.first { $0.id == id }?.images ?? []
            guard source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false || !images.isEmpty else { return }
            storedSource = source
            store.updateLog(id, text: source, on: date)
        }
        store.save()
    }

    /// 「取消」：放弃这次的修改。
    func discard() {
        discarded = true
        pendingWrite?.cancel()
        pendingWrite = nil
    }

    // MARK: 页面上的操作

    func beginEditing() {
        guard ready, let webView else { focusWhenReady = true; return }
        webView.evaluateJavaScript("window.boardEditor.edit(); 0")
    }

    func endEditing() {
        webView?.evaluateJavaScript("window.boardEditor.blur(); 0")
        webView?.endEditing(true)
    }

    /// 打字测试（`-perfTyping board`）：进入编辑（弹出键盘），每 0.1 秒输入一个字，报每个字从输入到网页画出下一帧的时间。
    func runTypingTest(_ text: String) {
        beginEditing()
        let json = (try? JSONSerialization.data(withJSONObject: [text])).map { String(decoding: $0, as: UTF8.self) } ?? "[\"\"]"
        // 程序里送不进 WebKit 的键盘输入：直接交给编辑器作为一次输入（和按键走同一套编辑器更新、重画）。
        let script = """
        (() => { const view = window.boardEditor.view(); const text = Array.from(\(json)[0]); const out = window.typingLatencies = []; let i = 0;
          const timer = setInterval(() => {
            if (i >= text.length) { clearInterval(timer); return; }
            const started = performance.now();
            view.dispatch({...view.state.replaceSelection(text[i++]), userEvent: "input.type", scrollIntoView: true});
            requestAnimationFrame(() => out.push(performance.now() - started));
          }, 100); })(); 0
        """
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.webView?.evaluateJavaScript(script) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2 + Double(text.count) * 0.1) { [weak self] in self?.reportLatencies() }
    }

    private func reportLatencies() {
        webView?.evaluateJavaScript("window.typingLatencies || []") { result, _ in
            let values = ((result as? [Double]) ?? (result as? [NSNumber])?.map(\.doubleValue) ?? []).sorted()
            guard let slowest = values.last else { print("[perf] 编辑器里没有测到输入"); return }
            print(String(format: "[perf] 编辑器输入 %d 个字：平均 %.1f ms · 中位 %.1f ms · 最慢 %.1f ms",
                         values.count, values.reduce(0, +) / Double(values.count), values[values.count / 2], slowest))
        }
    }
}

extension BoardWebSession: MarkdownToolbarTarget {
    func undo() { webView?.evaluateJavaScript("window.boardEditor.undo(); 0") }
    func redo() { webView?.evaluateJavaScript("window.boardEditor.redo(); 0") }
    func dismissKeyboard() { endEditing() }

    /// 按现在的全文和选区算出替换，交给网页作为一次输入应用。
    func format(_ edit: @escaping (String, NSRange) -> MarkdownEdit) {
        webView?.evaluateJavaScript("window.boardEditor.snapshot()") { [weak self] result, _ in
            guard let self, let snapshot = result as? [String: Any], let text = snapshot["source"] as? String,
                  let anchor = snapshot["anchor"] as? Int, let head = snapshot["head"] as? Int else { return }
            let selection = NSRange(location: min(anchor, head), length: abs(head - anchor))
            let change = edit(text, selection)
            let insert = (try? JSONSerialization.data(withJSONObject: [change.replacement])).map { String(decoding: $0, as: UTF8.self).dropFirst().dropLast() } ?? "\"\""
            let end = change.selection.location + change.selection.length
            self.webView?.evaluateJavaScript("window.boardEditor.applyEdit(\(change.range.location), \(change.range.location + change.range.length), \(insert), \(change.selection.location), \(end)); 0")
        }
    }
}

/// 共用网页编辑器本身和它的消息入口（消息按工作板的 key 转给对应的会话）。
@MainActor
private final class BoardWebHost: NSObject, WKScriptMessageHandler {
    let view: BoardWebView
    let pool: BoardWebSession.Pool
    private(set) var ready = false
    private let inputDelegate = InputDelegate()

    private final class InputDelegate: NSObject {
        @objc(_webView:focusShouldStartInputSession:) func webView(_ webView: WKWebView, focusShouldStartInputSession info: AnyObject) -> Bool { true }
    }

    init(pool: BoardWebSession.Pool) {
        self.pool = pool
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        view = BoardWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 600), configuration: configuration)
        super.init()
        configuration.userContentController.add(WeakHandler(self), name: "boardEditor")
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        // 滚动在编辑器自己的滚动区里；外层网页不滚、不缩放。
        view.scrollView.isScrollEnabled = false
        view.scrollView.contentInsetAdjustmentBehavior = .never
        view.scrollView.pinchGestureRecognizer?.isEnabled = false
        view.accessibilityLabel = L("工作板 Markdown 内容")
        // 允许原生层（菜单里的「编辑」、测试）让编辑器获得焦点时也弹出键盘；默认只有手指点进网页才弹。
        if view.responds(to: Selector(("_setInputDelegate:"))) { view.perform(Selector(("_setInputDelegate:")), with: inputDelegate) }
        if let directory = Bundle.main.url(forResource: "EditorAssets", withExtension: nil) {
            view.loadFileURL(directory.appendingPathComponent("index.html"), allowingReadAccessTo: directory)
        }
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        if body["kind"] as? String == "ready" {
            ready = true
            BoardWebSession.pageReady(pool)
        } else {
            BoardWebSession.route(body, pool: pool)
        }
    }

    /// 消息入口不直接持有编辑器（WebKit 会强引用它）。
    private final class WeakHandler: NSObject, WKScriptMessageHandler {
        weak var target: BoardWebHost?
        init(_ target: BoardWebHost) { self.target = target }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            MainActor.assumeIsolated { target?.userContentController(controller, didReceive: message) }
        }
    }
}

