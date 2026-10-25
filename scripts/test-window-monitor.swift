// 测试时盯着窗口服务器：测试进程（xctest）的窗口只要以大于 0 的透明度出现在屏幕上就打印出来（用户会看到闪一下）。
// 用法：swiftc -O scripts/test-window-monitor.swift -o /tmp/winmon && /tmp/winmon 900 & swift test；ALL=1 连透明的也打印。
import CoreGraphics
import Foundation
setvbuf(stdout, nil, _IOLBF, 0)
var seen = Set<String>()
let deadline = Date().addingTimeInterval(Double(CommandLine.arguments.dropFirst().first ?? "600") ?? 600)
while Date() < deadline {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    for w in list {
        let owner = w[kCGWindowOwnerName as String] as? String ?? ""
        guard owner.contains("xctest") || owner.contains("swiftpm") || owner.contains("Timeline") && owner != "Timeline" else { continue }
        let alpha = w[kCGWindowAlpha as String] as? Double ?? 0
        guard alpha > 0 || ProcessInfo.processInfo.environment["ALL"] != nil else { continue }
        let num = w[kCGWindowNumber as String] as? Int ?? 0
        let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
        let key = "\(owner)#\(num)"
        if seen.insert(key).inserted {
            print("\(Date().timeIntervalSince1970) VISIBLE owner=\(owner) win=\(num) alpha=\(alpha) layer=\(w[kCGWindowLayer as String] ?? "") name=\(w[kCGWindowName as String] ?? "") bounds=\(b)")
        }
    }
    usleep(5000)
}
