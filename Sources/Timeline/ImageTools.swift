import AppKit
import ImageIO
import UniformTypeIdentifiers
import Vision
import TimelineCore

/// 日志图片的处理：从剪贴板或文件取图、缩放压缩、缩略图缓存、本地文字识别。
enum ImageTools {
    static let maxPixel = 2048
    private static let thumbnails = NSCache<NSString, NSImage>()

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

    static func thumbnail(_ url: URL, maxPixel: Int = 240) -> NSImage? {
        let key = "\(url.path)#\(maxPixel)" as NSString
        if let cached = thumbnails.object(forKey: key) { return cached }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let result = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        thumbnails.setObject(result, forKey: key)
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
            for (name, url) in urls {
                let exists = FileManager.default.fileExists(atPath: url.path)
                let text = exists ? ImageTools.recognizeText(at: url) : ""
                await MainActor.run { store.setImageText(text, image: name) }
            }
            await MainActor.run { running = false }
        }
    }
}
