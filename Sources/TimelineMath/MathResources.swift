import Foundation

// 本目录是 SwiftMath 1.7.3（https://github.com/mgriebling/SwiftMath，MIT，见 LICENSE-SwiftMath.txt）的副本，只带拉丁现代体
// （GUST 字体许可）。原版用 SwiftPM 生成的 Bundle.module 找字体：Mac 应用里只看 .app 的根目录（放在那里签名会失败），
// 找不到就直接 fatalError。这里改成先找 Contents/Resources（iOS 应用的根目录也就是它），再退回 Bundle.module。
enum MathResources {
    static let fontsURL: URL? = {
        let name = "Timeline_TimelineMath.bundle"
        for base in [Bundle.main.resourceURL, Bundle.main.bundleURL].compactMap({ $0 }) {
            if let bundle = Bundle(url: base.appendingPathComponent(name)),
               let url = bundle.url(forResource: "mathFonts", withExtension: "bundle") { return url }
        }
        return Bundle.module.url(forResource: "mathFonts", withExtension: "bundle")
    }()
}
