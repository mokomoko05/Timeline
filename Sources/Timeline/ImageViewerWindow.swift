import AppKit
import CryptoKit
import SwiftUI
import TimelineCore

/// 图片查看器里显示的一组图片和当前这张。
@MainActor
final class ImageViewerModel: ObservableObject {
    struct Item: Equatable {
        let name: String
        /// 这张图来自哪里（日期 + 笔记开头）；没有就不显示。
        var caption: String = ""
    }

    @Published private(set) var items: [Item] = []
    @Published var index = 0
    /// 1 means fit to the window; larger images can be inspected without losing navigation.
    @Published private(set) var zoom: CGFloat = 1

    var current: Item? { items.indices.contains(index) ? items[index] : nil }
    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index < items.count - 1 }

    func load(_ items: [Item], index: Int) {
        self.items = items
        self.index = items.isEmpty ? 0 : min(max(index, 0), items.count - 1)
        zoom = 1
    }

    func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        let next = min(max(index + delta, 0), items.count - 1)
        if next != index { index = next; zoom = 1 }
    }

    func setZoom(_ value: CGFloat) { zoom = min(8, max(0.25, value)) }
    func zoomIn() { setZoom(zoom * 1.25) }
    func zoomOut() { setZoom(zoom / 1.25) }
    func fit() { zoom = 1 }
}

private final class ImageViewerWindow: QuietWindow {
    var onKey: ((NSEvent) -> Bool)?
    override func cancelOperation(_ sender: Any?) { close() }
    override func sendEvent(_ event: NSEvent) {
        // Keep gallery shortcuts working when the scroll view owns keyboard focus.
        if event.type == .keyDown,
           event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           onKey?(event) == true { return }
        super.sendEvent(event)
    }
}

/// 独立的图片窗口：可以拖动、调整大小（会记住），← → 或空格切换，Esc 关闭。
/// 再打开别的图片会复用这个窗口，不会越开越多。
@MainActor
final class ImageViewerController: NSObject, NSWindowDelegate {
    static let shared = ImageViewerController()
    static let frameName = "TimelineImageViewer"

    let model = ImageViewerModel()
    private(set) var window: NSWindow?
    private var store: JournalStore?
    private var previewDirectory: URL?

    var isVisible: Bool { window?.isVisible == true }

    /// 显示一组图片，从第 `index` 张开始。
    func show(store: JournalStore, items: [ImageViewerModel.Item], index: Int, previewDirectory: URL? = nil) {
        guard !items.isEmpty else { return }
        if let previous = self.store, previous !== store {
            window?.contentViewController = makeContent(store: store)
        }
        self.store = store
        self.previewDirectory = previewDirectory ?? store.directory.appendingPathComponent("Preview/Draft", isDirectory: true)
        model.load(items, index: index)
        let window = self.window ?? makeWindow(store: store)
        self.window = window
        window.makeKeyAndOrderFront(nil)
        Headless.activateApp()
    }

    /// 同一个任务的所有笔记里的图片，从这条日志的第 `index` 张开始。
    func show(store: JournalStore, around log: DailyLogEntry, index: Int, tag: String? = nil) {
        let gallery = gallery(store: store, around: log, tag: tag)
        let start = gallery.firstIndex { $0.logID == log.id }.map { $0 + index } ?? 0
        show(store: store, items: gallery.map { .init(name: $0.name, caption: $0.caption) }, index: start,
             previewDirectory: previewFolder(for: log, store: store, tag: tag))
    }

    /// 还没发送的草稿图片（没有出处可写）。
    func show(store: JournalStore, names: [String], index: Int) {
        show(store: store, items: names.map { .init(name: $0) }, index: index)
    }

    /// 交给系统「预览」打开整组图片。Preview 自己负责缩放、全屏和前后切换；
    /// 为每个任务 / 标签建立一个轻量的预览目录，避免把不同上下文的图片混在一起。
    func openPreview(store: JournalStore, around log: DailyLogEntry, index: Int, tag: String? = nil) {
        openPreview(urls: previewURLs(store: store, around: log, index: index, tag: tag))
    }

    func openPreview(store: JournalStore, names: [String], index: Int) {
        openPreview(urls: previewURLs(store: store, names: names, index: index,
                                     folder: store.directory.appendingPathComponent("Preview/Draft", isDirectory: true)))
    }

    private func gallery(store: JournalStore, around log: DailyLogEntry, tag: String?) -> [JournalStore.GalleryImage] {
        if log.taskID == nil, let tag = tag ?? (log.tags + log.taskTags).first {
            return JournalStore.gallery(of: store.allLogs(includeFocus: true).filter {
                $0.log.taskID == nil && ($0.log.tags + $0.log.taskTags).contains(tag)
            })
        }
        return store.galleryImages(around: log)
    }

    func previewURLs(store: JournalStore, around log: DailyLogEntry, index: Int, tag: String? = nil) -> [URL] {
        let gallery = gallery(store: store, around: log, tag: tag)
        let start = gallery.firstIndex { $0.logID == log.id }.map { $0 + index } ?? 0
        return previewURLs(store: store, names: gallery.map(\.name), index: start,
                           folder: previewFolder(for: log, store: store, tag: tag))
    }

    func previewURLs(store: JournalStore, names: [String], index: Int, folder: URL) -> [URL] {
        guard !names.isEmpty else { return [] }
        let urls = names.map { previewURL(for: $0, store: store, folder: folder) }
        let existing = urls.enumerated().compactMap { offset, url in
            FileManager.default.fileExists(atPath: url.path) ? (offset, url) : nil
        }
        guard !existing.isEmpty else { return [] }
        let selectedOffset = min(max(index, 0), urls.count - 1)
        let selected = existing.first(where: { $0.0 == selectedOffset })?.1 ?? existing[0].1
        var seen: Set<URL> = [selected]
        return [selected] + existing.map(\.1).filter { seen.insert($0).inserted }
    }

    private func openPreview(urls: [URL]) {
        guard !urls.isEmpty else { return }
        let preview = URL(fileURLWithPath: "/System/Applications/Preview.app", isDirectory: true)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(urls, withApplicationAt: preview, configuration: configuration)
    }

    private func previewFolder(for log: DailyLogEntry, store: JournalStore, tag contextTag: String? = nil) -> URL {
        if let taskID = log.taskID {
            return store.directory.appendingPathComponent("Preview/Tasks/\(taskID.uuidString)", isDirectory: true)
        }
        let tag = (contextTag ?? (log.tags + log.taskTags).first).map(Self.previewComponent) ?? "Unlinked"
        return store.directory.appendingPathComponent("Preview/Tags/\(tag)", isDirectory: true)
    }

    private func previewURL(for name: String, store: JournalStore, folder: URL) -> URL {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(URL(fileURLWithPath: name).lastPathComponent)
        let source = store.imageURL(name)
        if !FileManager.default.fileExists(atPath: target.path), FileManager.default.fileExists(atPath: source.path) {
            try? FileManager.default.createSymbolicLink(at: target, withDestinationURL: source)
        }
        return target
    }

    private static func previewComponent(_ value: String) -> String {
        let cleaned = value.replacingOccurrences(of: "[/\\\\:]", with: "-", options: .regularExpression)
        let digest = SHA256.hash(data: Data(value.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return String(cleaned.prefix(48)) + "-" + digest
    }

    func close() { window?.close() }

    /// 关闭后不再持有原图：长时间运行时大图不会一直留在内存里。
    func windowWillClose(_ notification: Notification) {
        model.load([], index: 0)
    }

    private func makeContent(store: JournalStore) -> NSViewController {
        let content = ImageViewerView(store: store, model: model, openPreview: { [weak self] in
            guard let self, let directory = self.previewDirectory else { return }
            self.openPreview(urls: self.previewURLs(store: store, names: self.model.items.map(\.name),
                                                    index: self.model.index, folder: directory))
        })
        return NSHostingController(rootView: LocalizedRoot { content })
    }

    private func makeWindow(store: JournalStore) -> NSWindow {
        let window = ImageViewerWindow(contentViewController: makeContent(store: store))
        window.title = AppLocalized("图片")
        window.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 360, height: 280)
        window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        // 看图始终用深色：照片和截图在暗底上对比最好；颜色取自主题的深色版本。
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NativePalette.background
        window.delegate = self
        window.onKey = { [weak self] event in self?.handleKey(event) ?? false }
        if !window.setFrameUsingName(Self.frameName) {
            window.setContentSize(NSSize(width: 860, height: 620))
            window.center()
        }
        window.setFrameAutosaveName(Self.frameName)
        return window
    }

    /// ← → 翻页，空格下一张；其他键交给窗口。
    func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 123: model.move(-1); return true
        case 124, 49: model.move(1); return true
        case 24, 69: model.zoomIn(); return true
        case 27, 78: model.zoomOut(); return true
        case 29, 82: model.fit(); return true
        default: return false
        }
    }
}

struct ImageViewerView: View {
    let store: JournalStore
    @ObservedObject var model: ImageViewerModel
    let openPreview: () -> Void
    @ObservedObject private var themes = ThemeStore.shared
    @State private var hovering = false

    var body: some View {
        ZStack {
            Palette.background
            if let item = model.current {
                let url = store.imageURL(item.name)
                ZoomableImage(url: url, model: model)
                    .padding(EdgeInsets(top: 34, leading: 14, bottom: 52, trailing: 14))
                navButton("chevron.left", enabled: model.canGoBack, help: "上一张 · ←") { model.move(-1) }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 10)
                navButton("chevron.right", enabled: model.canGoForward, help: "下一张 · → 或空格") { model.move(1) }
                    .frame(maxWidth: .infinity, alignment: .trailing).padding(.trailing, 10)
                VStack {
                    Spacer()
                    toolbar(item, url: url)
                }
            }
        }
        .onHover { hovering = $0 }
        .frame(minWidth: 360, minHeight: 280)
        .environment(\.colorScheme, .dark)
    }

    private func navButton(_ symbol: String, enabled: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 18, weight: .semibold))
                .frame(width: 40, height: 40)
                .background(Palette.card.opacity(0.9), in: Circle())
                .overlay(Circle().strokeBorder(Palette.line, lineWidth: Metrics.hairline))
                .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
        }
        .buttonStyle(.plain).foregroundStyle(Palette.ink)
        .opacity(enabled ? (hovering ? 1 : 0.55) : 0)
        .disabled(!enabled)
        .help(LocalizedStringKey(help)).accessibilityLabel(LocalizedStringKey(help))
    }

    private func toolbar(_ item: ImageViewerModel.Item, url: URL) -> some View {
        HStack(spacing: 12) {
            Text("\(model.index + 1) / \(model.items.count)").font(.system(size: 12, weight: .medium)).monospacedDigit().foregroundStyle(Palette.ink)
            if !item.caption.isEmpty {
                Text(item.caption).font(.system(size: 12)).foregroundStyle(Palette.muted).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 8)
            Button { model.zoomOut() } label: { Label("缩小", systemImage: "minus.magnifyingglass") }
                .disabled(model.zoom <= 0.25).help("缩小 · −")
            Button { model.fit() } label: {
                Text("\(Int((model.zoom * 100).rounded()))%")
                    .font(.system(size: 11, weight: .medium)).monospacedDigit().frame(minWidth: 42)
            }.help("适应窗口 · 0")
            Button { model.zoomIn() } label: { Label("放大", systemImage: "plus.magnifyingglass") }
                .disabled(model.zoom >= 8).help("放大 · +")
            ImageCopyButton(url: url)
            Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Label("在访达中显示", systemImage: "folder") }
            Button(action: openPreview) { Label("用「预览」打开", systemImage: "arrow.up.forward.app") }
        }
        .buttonStyle(HitAreaButtonStyle(compact: true)).labelStyle(.iconOnly).font(.system(size: 13)).foregroundStyle(Palette.ink)
        .padding(.horizontal, 14).frame(height: 40)
        .background(Palette.card.opacity(0.92))
        .overlay(alignment: .top) { Rectangle().fill(Palette.line).frame(height: Metrics.hairline) }
    }
}
