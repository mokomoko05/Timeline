import AppKit
import ImageIO
import UniformTypeIdentifiers
import Vision
import TimelineCore

/// 日志图片的处理：从剪贴板或文件取图、缩放压缩、缩略图缓存、本地文字识别。
enum ImageTools {
    static let maxPixel = 2048
    /// 解码好的缩略图。按显示尺寸 × 屏幕倍率解码，一张常见的日志配图约 1MB；24MB 够来回翻几天的日记。
    private static let thumbnails: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 96
        cache.totalCostLimit = 24 * 1024 * 1024
        return cache
    }()

    /// 缩略图按这个倍率解码：屏幕的实际像素密度（视网膜屏 2 倍），更高也看不出区别。
    @MainActor static var displayScale: CGFloat {
        min(2, max(1, NSScreen.screens.map(\.backingScaleFactor).max() ?? 2))
    }

    /// 清空缩略图缓存（系统内存紧张、窗口内容释放时）。
    static func purgeThumbnails() { thumbnails.removeAllObjects() }

    /// 把任意图片数据缩放到长边不超过 `maxPixel`，并编码成 PNG（小图）或 JPEG。
    static func process(_ data: Data) -> (data: Data, fileExtension: String)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let hasAlpha = ![CGImageAlphaInfo.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        let usePNG = hasAlpha || image.width * image.height <= 1_500_000
        let type = usePNG ? UTType.png : UTType.jpeg
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else { return nil }
        let properties: [CFString: Any] = usePNG ? [:] : [kCGImageDestinationLossyCompressionQuality: 0.88]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (output as Data, usePNG ? "png" : "jpg")
    }

    /// 剪贴板里要作为图片处理的内容：Finder 复制的图片文件，或没有文字的图片数据（截图、网页复制的图片）。
    /// 同时带文字的内容（例如从表格复制）仍按文字粘贴。
    static func images(from pasteboard: NSPasteboard) -> [Data] {
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let fromFiles = urls.compactMap { isImageFile($0) ? try? Data(contentsOf: $0) : nil }
        if !fromFiles.isEmpty { return fromFiles }
        guard pasteboard.string(forType: .string) == nil else { return [] }
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pasteboard.data(forType: type) { return [data] }
        }
        return []
    }

    /// 与 `images(from:)` 的规则一致，但只看类型，不读取图片数据，可用于菜单校验。
    static func hasImage(_ pasteboard: NSPasteboard) -> Bool {
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if urls.contains(where: isImageFile) { return true }
        guard let types = pasteboard.types, !types.contains(.string) else { return false }
        return types.contains(.png) || types.contains(.tiff)
    }

    static func isImageFile(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image)
    }

    /// 处理并保存一批图片数据，返回保存后的文件名。
    @MainActor
    static func save(_ datas: [Data], in store: JournalStore) -> [String] {
        datas.compactMap { data in
            guard let processed = process(data) else { return nil }
            return try? store.storeImage(processed.data, fileExtension: processed.fileExtension)
        }
    }

    /// 按原始比例缩小到刚好放进 `maxWidth × maxHeight`，不裁剪；比 1x 显示尺寸更小的图不放大。`scale` 为屏幕缩放（视网膜屏按 2 倍像素算）。
    static func fittedSize(pixels: CGSize, maxWidth: CGFloat, maxHeight: CGFloat, scale: CGFloat = 2) -> CGSize {
        guard pixels.width > 0, pixels.height > 0 else { return CGSize(width: maxHeight, height: maxHeight) }
        let natural = CGSize(width: pixels.width / scale, height: pixels.height / scale)
        let ratio = min(1, maxWidth / natural.width, maxHeight / natural.height)
        return CGSize(width: (natural.width * ratio).rounded(), height: (natural.height * ratio).rounded())
    }

    /// 已经解码过的缩略图（不读盘）。
    static func cachedThumbnail(_ url: URL, maxPixel: Int) -> NSImage? {
        thumbnails.object(forKey: "\(url.path)#\(maxPixel)" as NSString)
    }

    /// 只读文件头得到像素尺寸，不解码；占位用它保持最终大小，加载完成时版面不跳动。
    nonisolated static func pixelSize(_ url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat else { return nil }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        return orientation >= 5 ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }

    private static let decodeQueue = DispatchQueue(label: "Timeline.Thumbnails", qos: .userInitiated, attributes: .concurrent)

    /// 在后台解码，完成后回到主线程。滚动长列表时不在主线程读盘解码。
    @MainActor static func loadThumbnail(_ url: URL, maxPixel: Int, completion: @escaping @MainActor (NSImage?) -> Void) {
        if let cached = cachedThumbnail(url, maxPixel: maxPixel) { completion(cached); return }
        decodeQueue.async {
            let image = thumbnail(url, maxPixel: maxPixel)
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(image) } }
        }
    }

    /// 实际解码过多少次缩略图（缓存没命中）；测量缓存大小是否合适用。
    nonisolated(unsafe) static var decodeCount = 0

    nonisolated static func thumbnail(_ url: URL, maxPixel: Int = 240) -> NSImage? {
        let key = "\(url.path)#\(maxPixel)" as NSString
        if let cached = thumbnails.object(forKey: key) { return cached }
        decodeCount += 1
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let result = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        thumbnails.setObject(result, forKey: key, cost: image.bytesPerRow * image.height)
        return result
    }

    /// 本地识别图片里的中英文文字，不联网。
    nonisolated static func recognizeText(at url: URL) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        let handler = VNImageRequestHandler(url: url, options: [:])
        do { try handler.perform([request]) } catch { return "" }
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
    }
}

/// 在后台给还没识别过的图片补上文字，使截图里的字也能被搜索到。
@MainActor
enum ImageIndexer {
    private static var running = false

    static func run(store: JournalStore) {
        guard !running, !store.isReadOnly else { return }
        let pending = store.imagesMissingText()
        guard !pending.isEmpty else { return }
        running = true
        let urls = pending.map { ($0, store.imageURL($0)) }
        Task.detached(priority: .utility) {
            // 结果攒一批再写回：每 8 张或每 2 秒一次，大量图片也只触发少量界面刷新和保存。
            var batch: [String: String] = [:]
            var lastFlush = Date()
            for (name, url) in urls {
                let exists = FileManager.default.fileExists(atPath: url.path)
                batch[name] = exists ? autoreleasepool { ImageTools.recognizeText(at: url) } : ""
                if batch.count >= 8 || Date().timeIntervalSince(lastFlush) >= 2 {
                    let results = batch
                    batch = [:]
                    lastFlush = Date()
                    await MainActor.run { store.setImageTexts(results) }
                }
            }
            let results = batch
            await MainActor.run {
                store.setImageTexts(results)
                running = false
            }
        }
    }
}
