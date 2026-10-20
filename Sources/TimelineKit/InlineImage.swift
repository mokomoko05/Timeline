import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 终端里的内联图片。支持 iTerm2 协议（日页内置终端、iTerm2、WezTerm）和 Kitty 协议（Ghostty、Kitty）；
/// 其他终端（包括系统自带的「终端」）退回成只打印文件路径。
public enum ImageProtocol: Equatable {
    case iterm2, kitty, none

    /// `TIMELINE_IMAGES=iterm2|kitty|none` 可以强制指定，兼容旧 SCHED_IMAGES。
    public static func detect(_ env: [String: String]) -> ImageProtocol {
        let override = env["TIMELINE_IMAGES"].flatMap { $0.isEmpty ? nil : $0 } ?? env["SCHED_IMAGES"]
        if let forced = override?.lowercased() {
            switch forced {
            case "iterm2", "iterm": return .iterm2
            case "kitty": return .kitty
            default: return .none
            }
        }
        // tmux / screen 里转义序列默认被吞掉。
        if env["TMUX"] != nil || (env["TERM"] ?? "").hasPrefix("screen") || (env["TERM"] ?? "").hasPrefix("tmux") { return .none }
        switch env["TERM_PROGRAM"] ?? "" {
        case "Timeline", "Scheduler", "iTerm.app", "WezTerm": return .iterm2
        case "ghostty": return .kitty
        default: break
        }
        if env["KITTY_WINDOW_ID"] != nil || (env["TERM"] ?? "").contains("kitty") { return .kitty }
        return .none
    }
}

public enum InlineImage {
    public struct Prepared {
        public let png: Data
        public let pixelWidth: Int
        public let pixelHeight: Int
    }

    /// 读图、缩到长边不超过 `maxPixel`、统一编码成 PNG（Kitty 协议只认 PNG；iTerm2 协议也接受）。
    public static func prepare(_ url: URL, maxPixel: Int = 1100) -> Prepared? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return Prepared(png: output as Data, pixelWidth: image.width, pixelHeight: image.height)
    }

    /// 图片在终端里占几列：按原始大小（视网膜屏 2 倍像素）换算，不放大，最多 `maxColumns` 列，完整显示不裁剪。
    public static func columns(pixelWidth: Int, maxColumns: Int) -> Int {
        let natural = max(8, Int((Double(pixelWidth) / 2.0 / 8.0).rounded(.up)))
        return max(8, min(natural, maxColumns))
    }

    /// 生成在光标处显示图片的转义序列，末尾带换行（图片下方继续输出）。
    public static func sequence(_ prepared: Prepared, name: String, columns: Int, protocol kind: ImageProtocol) -> String? {
        switch kind {
        case .none:
            return nil
        case .iterm2:
            let encodedName = Data(name.utf8).base64EncodedString()
            let payload = prepared.png.base64EncodedString()
            return "\u{1B}]1337;File=name=\(encodedName);size=\(prepared.png.count);width=\(columns);preserveAspectRatio=1;inline=1:\(payload)\u{07}\n"
        case .kitty:
            let payload = prepared.png.base64EncodedString()
            var out = ""
            var index = payload.startIndex
            var first = true
            while index < payload.endIndex {
                let end = payload.index(index, offsetBy: 4096, limitedBy: payload.endIndex) ?? payload.endIndex
                let more = end < payload.endIndex ? 1 : 0
                let control = first ? "a=T,f=100,c=\(columns),m=\(more)" : "m=\(more)"
                out += "\u{1B}_G\(control);\(payload[index..<end])\u{1B}\\"
                first = false
                index = end
            }
            return out + "\n"
        }
    }
}
