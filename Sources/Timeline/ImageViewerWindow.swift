import AppKit
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

    var current: Item? { items.indices.contains(index) ? items[index] : nil }
    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index < items.count - 1 }

    func load(_ items: [Item], index: Int) {
        self.items = items
        self.index = items.isEmpty ? 0 : min(max(index, 0), items.count - 1)
    }

    func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        index = min(max(index + delta, 0), items.count - 1)
    }
}

private final class ImageViewerWindow: QuietWindow {
    var onKey: ((NSEvent) -> Bool)?
    override func cancelOperation(_ sender: Any?) { close() }
    override func keyDown(with event: NSEvent) {
        if onKey?(event) == true { return }
        super.keyDown(with: event)
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

    var isVisible: Bool { window?.isVisible == true }

    /// 显示一组图片，从第 `index` 张开始。
    func show(store: JournalStore, items: [ImageViewerModel.Item], index: Int) {
        guard !items.isEmpty else { return }
        self.store = store
        model.load(items, index: index)
        let window = self.window ?? makeWindow(store: store)
        self.window = window
        window.makeKeyAndOrderFront(nil)
        Headless.activateApp()
    }

    /// 同一个任务的所有笔记里的图片，从这条日志的第 `index` 张开始。
    func show(store: JournalStore, around log: DailyLogEntry, index: Int) {
        let gallery = store.galleryImages(around: log)
        let start = gallery.firstIndex { $0.logID == log.id }.map { $0 + index } ?? 0
        show(store: store, items: gallery.map { .init(name: $0.name, caption: $0.caption) }, index: start)
    }

    /// 还没发送的草稿图片（没有出处可写）。
    func show(store: JournalStore, names: [String], index: Int) {
        show(store: store, items: names.map { .init(name: $0) }, index: index)
    }

    func close() { window?.close() }

    private func makeWindow(store: JournalStore) -> NSWindow {
        let content = ImageViewerView(store: store, model: model, close: { [weak self] in self?.close() })
        let host = NSHostingController(rootView: LocalizedRoot { content })
        let window = ImageViewerWindow(contentViewController: host)
        window.title = "图片"
        window.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 360, height: 280)
        window.collectionBehavior = [.fullScreenAuxiliary]
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
        default: return false
        }
    }
}

struct ImageViewerView: View {
    let store: JournalStore
    @ObservedObject var model: ImageViewerModel
    let close: () -> Void
    @ObservedObject private var themes = ThemeStore.shared
    @State private var hovering = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.92)
            if let item = model.current {
                let url = store.imageURL(item.name)
                if let image = NSImage(contentsOf: url) {
                    Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                        .padding(EdgeInsets(top: 34, leading: 14, bottom: 52, trailing: 14))
                        .id(item.name)
                        .transition(.opacity)
                } else {
                    Label("找不到这张图片的文件", systemImage: "photo.badge.exclamationmark").foregroundStyle(.secondary)
                }
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
        .animation(Motion.quick, value: model.index)
        .onHover { hovering = $0 }
        .frame(minWidth: 360, minHeight: 280)
        .environment(\.colorScheme, .dark)
    }

    private func navButton(_ symbol: String, enabled: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 18, weight: .semibold))
                .frame(width: 40, height: 40)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.75))
                .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
        }
        .buttonStyle(.plain).foregroundStyle(.white)
        .opacity(enabled ? (hovering ? 1 : 0.55) : 0)
        .disabled(!enabled)
        .help(help).accessibilityLabel(help)
    }

    private func toolbar(_ item: ImageViewerModel.Item, url: URL) -> some View {
        HStack(spacing: 12) {
            Text("\(model.index + 1) / \(model.items.count)").font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(.white.opacity(0.85))
            if !item.caption.isEmpty {
                Text(item.caption).font(.system(size: 12)).foregroundStyle(.white.opacity(0.7)).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 8)
            Button {
                if let image = NSImage(contentsOf: url) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([image])
                }
            } label: { Label("复制", systemImage: "doc.on.doc") }
            Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Label("在访达中显示", systemImage: "folder") }
            Button { NSWorkspace.shared.open(url) } label: { Label("用「预览」打开", systemImage: "arrow.up.forward.app") }
        }
        .buttonStyle(HitAreaButtonStyle(compact: true)).labelStyle(.iconOnly).font(.system(size: 13)).foregroundStyle(.white)
        .padding(.horizontal, 14).frame(height: 40)
        .background(.ultraThinMaterial)
    }
}
