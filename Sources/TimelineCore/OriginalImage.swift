import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageExportError: LocalizedError {
    case unavailable
    public var errorDescription: String? { "部分原图尚未下载，备份未完成。请联网等待图片下载后重试。" }
}

/// 原文件只做类型检查，不缩放、不重新编码；内容摘要让多端重复导入落到同一个文件。
public enum OriginalImage {
    public static func fileExtension(for data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let type = CGImageSourceGetType(source), let ext = UTType(type as String)?.preferredFilenameExtension else { return nil }
        return ext == "jpeg" ? "jpg" : ext
    }

    static func store(_ data: Data, extension ext: String, directory: URL) throws -> String {
        guard !ext.isEmpty, ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { throw CocoaError(.fileWriteInvalidFileName) }
        let normalized = ext.lowercased() == "jpeg" ? "jpg" : ext.lowercased()
        let name = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() + "." + normalized
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) { try data.write(to: url, options: .atomic) }
        return name
    }
}
