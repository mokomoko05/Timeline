import AppKit
import SwiftUI
import TimelineCore
import UniformTypeIdentifiers

/// 缩略图：缓存里有就直接显示，否则后台解码，期间显示同样大小的占位。
@MainActor
final class ThumbnailLoader: ObservableObject {
    enum State: Equatable { case loading, loaded(NSImage), missing }
    @Published private(set) var state: State = .loading
    private var key: String?
    private var requested: (URL, Int)?
    private var imageObserver: NSObjectProtocol?

    init() {
        imageObserver = NotificationCenter.default.addObserver(forName: JournalStore.imageAvailable, object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, let (url, pixels) = self.requested, notification.object as? URL == url else { return }
                self.key = nil
                self.load(url, maxPixel: pixels)
            }
        }
    }
    deinit { if let imageObserver { NotificationCenter.default.removeObserver(imageObserver) } }

    func load(_ url: URL, maxPixel: Int) {
        requested = (url, maxPixel)
        let key = "\(url.path)#\(maxPixel)"
        guard key != self.key else { return }
        self.key = key
        if let cached = ImageTools.cachedThumbnail(url, maxPixel: maxPixel) { state = .loaded(cached); return }
        state = .loading
        ImageTools.loadThumbnail(url, maxPixel: maxPixel) { [weak self] image in
            guard let self, self.key == key else { return }
            self.state = image.map(State.loaded) ?? .missing
        }
    }
}

/// 缩略图方块；文件缺失时显示占位。
struct ImageThumb: View {
    let url: URL
    var size: CGFloat = 56
    @StateObject private var loader = ThumbnailLoader()

    var body: some View {
        Group {
            switch loader.state {
            case .loaded(let image): Image(nsImage: image).resizable().scaledToFit()
            case .loading: Color.clear
            case .missing:
                Image(systemName: "photo.badge.exclamationmark").font(.system(size: size * 0.35)).foregroundStyle(Palette.muted)
            }
        }
        .frame(width: size, height: size)
        .background(Palette.line.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.line))
        .onAppear { loader.load(url, maxPixel: Int(size * ImageTools.displayScale)) }
        .onChange(of: url) { loader.load($0, maxPixel: Int(size * ImageTools.displayScale)) }
    }
}

/// 完整显示一张图：按原始比例缩小到放得进框里，不裁剪。截取的论文插图通常不大，缩小后可以整张看清。
struct ImageFit: View {
    let url: URL
    var maxWidth: CGFloat = 320
    var maxHeight: CGFloat = 170
    @StateObject private var loader = ThumbnailLoader()
    @State private var placeholder: CGSize?

    private var maxPixel: Int { Int(max(maxWidth, maxHeight) * ImageTools.displayScale) }

    var body: some View {
        Group {
            switch loader.state {
            case .loaded(let image):
                let size = ImageTools.fittedSize(pixels: image.size, maxWidth: maxWidth, maxHeight: maxHeight)
                Image(nsImage: image).resizable().interpolation(.high)
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Palette.line))
            case .loading:
                let size = placeholder ?? CGSize(width: 56, height: 56)
                RoundedRectangle(cornerRadius: 4).fill(Palette.line.opacity(0.25))
                    .frame(width: size.width, height: size.height)
            case .missing:
                ImageThumb(url: url, size: 56)
            }
        }
        .onAppear { start(url) }
        .onChange(of: url) { start($0) }
    }

    private func start(_ url: URL) {
        if ImageTools.cachedThumbnail(url, maxPixel: maxPixel) == nil, let pixels = ImageTools.pixelSize(url) {
            // 缩略图的长边不超过 maxPixel，按同样比例估算显示尺寸。
            let scale = min(1, CGFloat(maxPixel) / max(pixels.width, pixels.height))
            placeholder = ImageTools.fittedSize(pixels: CGSize(width: pixels.width * scale, height: pixels.height * scale),
                                                maxWidth: maxWidth, maxHeight: maxHeight)
        }
        loader.load(url, maxPixel: maxPixel)
    }
}

/// 输入框上方：已粘贴、还没提交的图片。
struct PendingImagesStrip: View {
    @Environment(\.typography) private var typography
    let store: JournalStore
    let names: [String]
    let remove: (String) -> Void
    let preview: (Int) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(names.enumerated()), id: \.element) { index, name in
                    Button { preview(index) } label: { ImageThumb(url: store.imageURL(name)) }
                        .buttonStyle(.plain)
                        .overlay(alignment: .topTrailing) {
                            Button { remove(name) } label: {
                                Image(systemName: "xmark.circle.fill").font(.system(size: 14))
                                    .foregroundStyle(Color.white, Color.black.opacity(0.7))
                            }
                            .buttonStyle(.plain).offset(x: 5, y: -5)
                            .help("移除这张图片").accessibilityLabel("移除图片")
                        }
                        .help("点击查看大图")
                        .accessibilityLabel("待发送图片 \(index + 1)")
                }
                Text("\(names.count) 张图片，回车随日志一起保存")
                    .font(.system(size: typography.pt(11))).foregroundStyle(Palette.muted)
            }
            .padding(.vertical, 6).padding(.horizontal, 4)
        }
    }
}

/// 从访达拖进来的文件：按拖入的先后读出图片，不是图片的跳过。
enum ImageFileDrop {
    @MainActor static func load(_ providers: [NSItemProvider]) async -> [Data] {
        var result: [Data] = []
        for provider in providers {
            let data: Data? = await withCheckedContinuation { continuation in
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    continuation.resume(returning: url.flatMap { ImageTools.isImageFile($0) ? try? Data(contentsOf: $0) : nil })
                }
            }
            if let data { result.append(data) }
        }
        return result
    }
}

private struct ImageFileDropModifier: ViewModifier {
    let enabled: Bool
    let add: ([Data]) -> Void
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if targeted {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.accent, style: StrokeStyle(lineWidth: 2, dash: [6]))
                        .background(Palette.accent.opacity(0.08)).allowsHitTesting(false)
                        .overlay(Text("松开以添加图片").foregroundStyle(Palette.accent))
                }
            }
            .onDrop(of: [UTType.fileURL], isTargeted: $targeted) { providers in
                guard enabled else { return false }
                Task { @MainActor in
                    let datas = await ImageFileDrop.load(providers)
                    if !datas.isEmpty { add(datas) }
                }
                return true
            }
    }
}

extension View {
    /// 接受从访达拖来的图片文件。
    func imageFileDrop(enabled: Bool, add: @escaping ([Data]) -> Void) -> some View {
        modifier(ImageFileDropModifier(enabled: enabled, add: add))
    }
}
