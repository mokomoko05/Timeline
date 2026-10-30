import AppKit
import SwiftUI
import TimelineCore

enum ImageClipboard {
    @discardableResult
    static func copy(_ url: URL, to pasteboard: NSPasteboard = .general) -> Bool {
        guard let image = NSImage(contentsOf: url) else { return false }
        pasteboard.clearContents()
        return pasteboard.writeObjects([image])
    }
}

struct ImageCopyButton: View {
    let url: URL
    @State private var copied = false

    var body: some View {
        Button { copied = ImageClipboard.copy(url) } label: {
            Label(copied ? "已复制图片" : "复制图片", systemImage: copied ? "checkmark.circle.fill" : "doc.on.doc")
        }
        .foregroundStyle(copied ? Palette.success : Palette.muted)
        .help(copied ? "已复制图片" : "复制图片")
        .onChange(of: url) { _ in copied = false }
    }
}

/// Each image exposes its actions directly, without opening a menu or another window first.
struct NoteImageCard: View {
    let store: JournalStore
    let log: DailyLogEntry
    let index: Int
    var tag: String? = nil
    var maxWidth: CGFloat = 440
    var maxHeight: CGFloat = 280

    private var url: URL { store.imageURL(log.images[index]) }
    private func browse() { ImageViewerController.shared.show(store: store, around: log, index: index, tag: tag) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button(action: browse) { ImageFit(url: url, maxWidth: maxWidth, maxHeight: maxHeight) }
                .buttonStyle(.plain).help("在应用内浏览图片")
                .accessibilityLabel("在应用内浏览图片")
            HStack(spacing: 4) {
                Button(action: browse) { Label("在应用内浏览", systemImage: "photo.on.rectangle") }
                    .help("在应用内浏览 · 支持缩放和前后切换")
                Button { ImageViewerController.shared.openPreview(store: store, around: log, index: index, tag: tag) } label: {
                    Label("用「预览」打开", systemImage: "arrow.up.forward.app")
                }.help("用「预览」打开")
                Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                    Label("在访达中显示", systemImage: "folder")
                }.help("在访达中显示")
                ImageCopyButton(url: url)
                if !store.isReadOnly {
                    Button { store.removeImage(log.images[index], fromLog: log.id) } label: { Label("删除这张图片", systemImage: "trash") }
                        .help("删除这张图片 · ⌘Z 撤销")
                }
            }
            .buttonStyle(HitAreaButtonStyle(compact: true)).labelStyle(.iconOnly)
            .font(.system(size: 12)).foregroundStyle(Palette.muted)
        }
    }
}
